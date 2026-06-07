"""
    z3_evaluator.jl

`Z3GradedEvaluator` — the novel fitness function whose evaluation *is* a formal
verification. For each spec constraint it issues an independent Z3 query
(`generate_constraint_check_query`):

  - `:unsat` ⇒ the candidate satisfies that constraint for **all** inputs.
  - `:sat`   ⇒ it violates it; the witness input is stashed for targeted mutation.

Fitness = number of constraints violated (lower better; `0` ⇒ formally correct,
so no outer CEGIS counterexample-accumulation loop is needed). Arborist adds a
small `bloat_penalty * complexity` term on top for parsimony.

Per-genome diagnostics (violation count + first witness) are written to a shared
`blackboard` keyed by the serialized program; the targeted-mutation operator reads
the same blackboard. A `cache` (same key) skips re-verifying duplicate/elite
genomes, which dominate later generations.
"""

"""
    GenomeDiagnostics

What the evaluator learned about one genome from Z3.

- `num_violated`       — number of spec constraints violated universally.
- `first_violated_idx` — index of the first violated constraint (`0` if none).
- `witness`            — counterexample input `Dict{Symbol,Any}` for that
                         constraint (empty if the genome is fully correct).
"""
struct GenomeDiagnostics
    num_violated::Int
    first_violated_idx::Int
    witness::Dict{Symbol,Any}
end

"""
    Z3GradedEvaluator(spec, grammar, start_symbol, max_depth)

Construct from a parsed `CEXGeneration.Spec` and the grammar candidates are drawn
from. Assumes a single synthesis function (the common SyGuS case).
"""
mutable struct Z3GradedEvaluator <: Arborist.AbstractEvaluator
    spec::Any                # CEXGeneration.Spec
    grammar::AbstractGrammar
    start_symbol::Symbol
    max_depth::Int
    func_name::String
    n_constraints::Int
    blackboard::Dict{String,GenomeDiagnostics}
    cache::Dict{String,Float64}
end

function Z3GradedEvaluator(spec, grammar::AbstractGrammar, start_symbol::Symbol, max_depth::Int)
    isempty(spec.synth_funs) && error("Z3GradedEvaluator: spec has no synth-fun")
    return Z3GradedEvaluator(
        spec, grammar, start_symbol, max_depth,
        spec.synth_funs[1].name, length(spec.constraints),
        Dict{String,GenomeDiagnostics}(), Dict{String,Float64}(),
    )
end

# --- signatures (mostly for API completeness; used to build the GenState carrier) ---

_sort_to_type(sort::String)::DataType = sort == "Bool" ? Bool : Int

function Arborist.input_signature(e::Z3GradedEvaluator)::Dict{Symbol,DataType}
    sf = e.spec.synth_funs[1]
    return Dict{Symbol,DataType}(Symbol(p) => _sort_to_type(s) for (p, s) in sf.params)
end

function Arborist.output_signature(e::Z3GradedEvaluator)::Dict{Symbol,DataType}
    sf = e.spec.synth_funs[1]
    return Dict{Symbol,DataType}(:out => _sort_to_type(sf.sort))
end

"""Map a Z3 model (free-var names → values) to a synth-fun-param-keyed input."""
function _model_to_input(e::Z3GradedEvaluator, model::Dict{String,Any})::Dict{Symbol,Any}
    sf = e.spec.synth_funs[1]
    pnames = [p for (p, _) in sf.params]
    fvs = e.spec.free_vars
    input = Dict{Symbol,Any}()
    for i in 1:min(length(pnames), length(fvs))
        input[Symbol(pnames[i])] = get(model, fvs[i].name, 0)
    end
    return input
end

"""
    evaluate_genome(g::RuleNodeGenome, e::Z3GradedEvaluator) -> Float64

Override of Arborist's genome-level evaluation hook (the default would compile a
numeric function — useless for SMT). Returns the violated-constraint count and
records diagnostics on the shared blackboard.
"""
function Arborist.evaluate_genome(g::RuleNodeGenome, e::Z3GradedEvaluator)::Float64
    key = Arborist.serialize(g)
    haskey(e.cache, key) && return e.cache[key]

    # RuleNode → SMT-LIB2 (reuse the project's type-correct converter).
    smt = try
        CEXGeneration.rulenode_to_smt2(g.tree, e.grammar)
    catch
        e.blackboard[key] = GenomeDiagnostics(e.n_constraints, 1, Dict{Symbol,Any}())
        e.cache[key] = Inf
        return Inf
    end

    cands = Dict(e.func_name => smt)
    nviol = 0
    first_idx = 0
    witness = Dict{Symbol,Any}()

    for i in 1:e.n_constraints
        q = CEXGeneration.generate_constraint_check_query(e.spec, cands, i)
        r = try
            CEXGeneration.verify_query(q)
        catch
            CEXGeneration.Z3Result(:unknown, Dict{String,Any}(), String[])
        end

        if r.status == :sat
            nviol += 1
            if first_idx == 0
                first_idx = i
                witness = _model_to_input(e, r.model)
            end
        elseif r.status == :unknown
            # Conservatively treat unknown (often an ill-typed candidate) as a violation.
            nviol += 1
            first_idx == 0 && (first_idx = i)
        end
    end

    e.blackboard[key] = GenomeDiagnostics(nviol, first_idx, witness)
    fit = Float64(nviol)
    e.cache[key] = fit
    return fit
end
