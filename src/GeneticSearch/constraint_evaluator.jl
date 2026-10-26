"""
    constraint_evaluator.jl

`CDGPConstraintEvaluator` — constraint-graded fitness for the `run_cdgp` loop,
computed entirely on the warm in-process `ConstraintSatSolver` (Z3.jl):

  - Fitness = number of spec constraints the candidate violates for **some**
    input (each constraint checked with its own `check-sat-assuming` on the
    persistent solver — the constraint ASTs are built once at construction).
  - `0` violations ⇒ the candidate satisfies every constraint universally, so
    it is formally verified — `solved` is set and no separate counterexample
    query is needed.
  - `evaluate_cases` exposes the same verdicts as a per-constraint loss vector
    (`0.0` holds ∀ inputs, `1.0` violated, `Inf` undetermined/ill-typed), which
    turns `Arborist.LexicaseSelection` into **constraint-based lexicase**: each
    spec constraint acts as one selection case.

Unlike `CDGPEvaluator` there is no accumulated test set: constraint verdicts
are intrinsic to the candidate, so the per-genome `status_cache` never goes
stale and both the scalar and the case vector are served from one Z3 session
per distinct genome. `evaluate_cases` may set `solved` (harmless here — the
case-vector length is fixed at `n_constraints`, so no ragged-matrix concern).

The evaluator mutates shared state (cache, counters), so the GA must run with
`parallel=false` — same constraint as `CDGPEvaluator`.
"""

"""
    CDGPConstraintEvaluator(spec, grammar, start_symbol, max_depth; z3_timeout_ms=100)

Construct from a parsed `CEXGeneration.Spec` and the grammar candidates are
drawn from. Builds the persistent `ConstraintSatSolver`; throws when the spec
is outside the in-process scope (non-canonical synth-fun application) — use
`fitness=:tests` for such specs.

`z3_timeout_ms` bounds every per-constraint check (typical checks are ~2 ms;
the default is 50× headroom). Without it a single nonlinear candidate (the
grammar admits `*`) can stall a check for minutes, and since *every* genome is
Z3-checked in this mode, that would wedge whole GA rounds. Timed-out checks
report `:unknown` and count as violations — extra selection pressure away from
nonlinear bloat.
"""
mutable struct CDGPConstraintEvaluator <: Arborist.AbstractEvaluator
    spec::Any                # CEXGeneration.Spec
    grammar::AbstractGrammar
    start_symbol::Symbol
    max_depth::Int
    func_name::String
    css::CEXGeneration.ConstraintSatSolver
    n_constraints::Int
    # serialized genome → per-constraint Z3 verdicts (:unsat/:sat/:unknown);
    # `nothing` ⇒ the genome could not be converted to SMT.
    status_cache::Dict{String,Union{Vector{Symbol},Nothing}}
    solved::Union{RuleNodeGenome,Nothing}
    z3_checks::Int           # check-sat-assuming calls issued (n_constraints per new genome)
end

function CDGPConstraintEvaluator(spec, grammar::AbstractGrammar, start_symbol::Symbol,
                                 max_depth::Int; z3_timeout_ms::Integer=100)
    isempty(spec.synth_funs) && error("CDGPConstraintEvaluator: spec has no synth-fun")
    isempty(spec.constraints) && error("CDGPConstraintEvaluator: spec has no constraints")
    return CDGPConstraintEvaluator(
        spec, grammar, start_symbol, max_depth,
        spec.synth_funs[1].name,
        # nl_arith=false: every genome is Z3-checked in this mode, and Z3
        # 4.16's nlsat can abort the whole process on nonlinear candidates.
        CEXGeneration.ConstraintSatSolver(spec; timeout_ms=z3_timeout_ms, nl_arith=false),
        length(spec.constraints),
        Dict{String,Union{Vector{Symbol},Nothing}}(), nothing, 0,
    )
end

function Arborist.input_signature(e::CDGPConstraintEvaluator)::Dict{Symbol,DataType}
    sf = e.spec.synth_funs[1]
    return Dict{Symbol,DataType}(Symbol(p) => _sort_to_type(s) for (p, s) in sf.params)
end

function Arborist.output_signature(e::CDGPConstraintEvaluator)::Dict{Symbol,DataType}
    sf = e.spec.synth_funs[1]
    return Dict{Symbol,DataType}(:out => _sort_to_type(sf.sort))
end

"""
    _constraint_statuses!(e, g) -> Union{Vector{Symbol},Nothing}

Per-constraint Z3 verdicts for the genome, served from the cache when the
genome was seen before. A fully-`:unsat` verdict vector means the candidate is
formally verified — records it in `solved`.
"""
function _constraint_statuses!(e::CDGPConstraintEvaluator,
                               g::RuleNodeGenome)::Union{Vector{Symbol},Nothing}
    key = Arborist.serialize(g)
    haskey(e.status_cache, key) && return e.status_cache[key]

    smt = try
        CEXGeneration.rulenode_to_smt2(g.tree, e.grammar;
                                    context_type=_synth_context_type(e.spec))
    catch
        return (e.status_cache[key] = nothing)
    end

    r = CEXGeneration.check_constraint_satisfaction(e.css, e.func_name, smt)
    e.z3_checks += e.n_constraints

    if e.solved === nothing && all(==(:unsat), r.status)
        e.solved = g
    end
    return (e.status_cache[key] = r.status)
end

"""
    evaluate_genome(g::RuleNodeGenome, e::CDGPConstraintEvaluator) -> Float64

Fitness = constraints not proven to hold universally (`:sat` and `:unknown`
both count; lower better, `0` ⇒ formally verified). Genomes that cannot be
converted to SMT get `Inf`.
"""
function Arborist.evaluate_genome(g::RuleNodeGenome, e::CDGPConstraintEvaluator)::Float64
    st = _constraint_statuses!(e, g)
    st === nothing && return Inf
    return Float64(count(!=(:unsat), st))
end

"""
    evaluate_cases(g::RuleNodeGenome, e::CDGPConstraintEvaluator) -> Vector{Float64}

Per-constraint loss vector for lexicase selection: one entry per spec
constraint, in spec order — `0.0` the candidate satisfies it for all inputs,
`1.0` some input violates it, `Inf` undetermined (`:unknown`) or the genome
could not be converted to SMT.
"""
function Arborist.evaluate_cases(g::RuleNodeGenome, e::CDGPConstraintEvaluator)::Vector{Float64}
    st = _constraint_statuses!(e, g)
    st === nothing && return fill(Inf, e.n_constraints)
    return Float64[s === :unsat ? 0.0 : s === :sat ? 1.0 : Inf for s in st]
end
