"""
    cdgp_evaluator.jl

`CDGPEvaluator` — the classic CDGP fitness (Błądek & Krawiec, *Counterexample-
Driven Genetic Programming*). The complement of `Z3GradedEvaluator`:

  - Fitness = number of **failed test cases**, cheap interpretation only.
  - The test set starts empty and grows from Z3 counterexamples: a candidate
    that passes *all* current tests is formally verified with a single full
    counterexample query — on the warm in-process `CexSolver` (Z3.jl) when the
    spec is in scope, else via a z3 subprocess (`generate_cex_query`):
      - `:unsat`   ⇒ formally correct — recorded in `solved`, search can stop.
      - `:sat`     ⇒ the model yields a new test at the violating input. It is
                     a **complete** `(input, expected_output)` test when the
                     spec accepts only one output there (fresh constant
                     `out_<f>` → that output), and an **incomplete** test —
                     the input alone, passed when the candidate satisfies the
                     constraints there — when several outputs are valid
                     (`incomplete_tests.jl`).
      - `:unknown` ⇒ ill-typed/unsupported candidate — fitness `Inf`.

So Z3 is only consulted for test-perfect candidates, instead of on every
fitness evaluation as in the graded approach.

**Counterexample mode** (`cex_mode`). `:single` (default) is the classic loop
above: one counterexample query per verification, at most one new test.
`:per_constraint` verifies with one universal check *per constraint* on the warm
`ConstraintSatSolver` and turns the violation witness of **every** violated
constraint into a test (complete when its output is unique, incomplete
otherwise) — up to `m` tests from one verification. The reference CDGP runs the
same per-constraint checks in its constraint-graded mode and discards their
counterexamples (`EvaluatorSpecialTests.scala:56`); this harvests them into the
fast test-based fitness. `CexHarvest` counts what the path actually did.

Deliberately bypasses `Z3Oracle.extract_counterexample`, which collapses
`:unsat` and `:unknown` into `nothing`: with an initially empty test set every
genome is "test-perfect", and an ill-typed one returning `:unknown` would be
declared solved.

The `cache` (keyed by serialized program) is only valid for the current test
set and is cleared whenever a counterexample grows it. Note the evaluator
mutates shared state (`test_cases`, `cache`, counters), so the GA must run
with `parallel=false`.
"""

"""
    CDGPEvaluator(spec, grammar, start_symbol, max_depth; mod=Main, incomplete_tests=true)

Construct from a parsed `CEXGeneration.Spec` and the grammar candidates are
drawn from. Assumes a single synthesis function (the common SyGuS case).
`grammar`/`start_symbol`/`max_depth` are also read by Arborist's
`_initialize_population` for `RuleNodeGenome`. `incomplete_tests=false` turns
every counterexample into a complete test with the solver's output, the
behaviour before incomplete tests existed (ablation only).

`cex_mode=:per_constraint` harvests one test per violated constraint (see the
file header), at most `max_new_tests` per verification. It needs both
in-process solvers; for a spec outside their scope it falls back to `:single`
and records the fallback in `harvest`.
"""
mutable struct CDGPEvaluator <: Arborist.AbstractEvaluator
    spec::Any                # CEXGeneration.Spec
    grammar::AbstractGrammar
    start_symbol::Symbol
    max_depth::Int
    func_name::String
    symboltable::Any
    test_cases::Vector{IOExample}
    counterexamples::Vector{Counterexample}
    seen_inputs::Set{Any}    # dedupe key set for counterexample inputs (matters at q<1)
    cache::Dict{String,Float64}
    solved::Union{RuleNodeGenome,Nothing}
    verifications::Int       # number of Z3 counterexample queries issued
    # Warm in-process Z3 verifier; `nothing` ⇒ spec is outside the in-process
    # scope (non-canonical/preamble), fall back to the z3 subprocess per query.
    cex_solver::Union{CEXGeneration.CexSolver,Nothing}
    parsimony::Bool          # append a program-size lexicase case
    tests_ratio::Float64     # verify a genome once it passes ≥ this ratio of tests (q)
    incomplete::Vector{Dict{String,Any}}  # incomplete tests: free-var bindings, judged pointwise
    completion::TestCompletion            # complete-vs-incomplete policy and its counters
    cex_mode::Symbol                      # :single | :per_constraint (effective, after fallback)
    css::Union{CEXGeneration.ConstraintSatSolver,Nothing}  # per-constraint checks (:per_constraint only)
    max_new_tests::Int                    # cap on tests added by one verification
    harvest::Any                          # CexHarvest — what the counterexample path did
end

"""
What the counterexample path did over a run — the evidence that a mode is
actually exercised. One *event* is a verification that found the candidate
wrong. In `:single` mode every event returns one witness; in `:per_constraint`
mode one per violated constraint.
"""
mutable struct CexHarvest
    requested::Symbol    # the mode asked for
    mode::Symbol         # the mode in effect (:single when :per_constraint was unavailable)
    events::Int          # verifications that found at least one violation
    witnesses::Int       # violation inputs those verifications returned
    added::Int           # tests added from them (complete + incomplete)
    dup::Int             # input already a test, or repeated within one event
    no_output::Int       # output completion failed; kept as an incomplete test when possible
    capped::Int          # skipped by `max_new_tests`
    multi_events::Int    # events that added two or more tests
    max_per_event::Int   # most tests added by one event
end

CexHarvest(requested::Symbol, mode::Symbol) = CexHarvest(requested, mode, 0, 0, 0, 0, 0, 0, 0, 0)

"""Snapshot of a `CexHarvest` (for results, traces and the benchmark harness)."""
harvest_stats(h::CexHarvest) =
    (requested = h.requested, mode = h.mode, fallback = h.requested !== h.mode,
     events = h.events, witnesses = h.witnesses, added = h.added, dup = h.dup,
     no_output = h.no_output, capped = h.capped, multi_events = h.multi_events,
     max_per_event = h.max_per_event)

function _harvest_event!(h::CexHarvest, nwit::Int, added::Int)
    h.events += 1
    h.witnesses += nwit
    h.added += added
    added >= 2 && (h.multi_events += 1)
    h.max_per_event = max(h.max_per_event, added)
    return nothing
end

function CDGPEvaluator(spec, grammar::AbstractGrammar, start_symbol::Symbol,
                       max_depth::Int; mod::Module=Main, z3_timeout_ms::Integer=5_000,
                       parsimony::Bool=true, tests_ratio::Float64=1.0,
                       incomplete_tests::Bool=true, cex_mode::Symbol=:single,
                       max_new_tests::Int=typemax(Int))
    isempty(spec.synth_funs) && error("CDGPEvaluator: spec has no synth-fun")
    cex_mode in (:single, :per_constraint) ||
        throw(ArgumentError("cex_mode must be :single or :per_constraint, got :$cex_mode"))
    max_new_tests >= 1 || throw(ArgumentError("max_new_tests must be ≥ 1, got $max_new_tests"))
    cex_solver = try
        # nl_arith=false: Z3 4.16's nlsat can abort the whole process on the
        # nonlinear candidates the GA breeds; nonlinear-dependent verification
        # reports :unknown instead (candidate treated as unverifiable).
        CEXGeneration.CexSolver(spec; timeout_ms=z3_timeout_ms, nl_arith=false)
    catch err
        @debug "CDGPEvaluator: in-process CexSolver unavailable; using z3 subprocess" err
        nothing
    end
    # Per-constraint checks run on their own solver (own Z3 context), built only
    # when asked for, so `:single` runs are untouched. Output completion needs
    # the CexSolver as well; without either, fall back to `:single`.
    css = (cex_mode === :per_constraint && cex_solver !== nothing) ? (try
        CEXGeneration.ConstraintSatSolver(spec; timeout_ms=z3_timeout_ms, nl_arith=false)
    catch err
        @debug "CDGPEvaluator: per-constraint checks unavailable; using :single" err
        nothing
    end) : nothing
    mode = (cex_mode === :per_constraint && css === nothing) ? :single : cex_mode
    return CDGPEvaluator(
        spec, grammar, start_symbol, max_depth,
        spec.synth_funs[1].name, grammar2symboltable(grammar, mod),
        IOExample[], Counterexample[], Set{Any}(),
        Dict{String,Float64}(), nothing, 0, cex_solver, parsimony, tests_ratio,
        Dict{String,Any}[], TestCompletion(spec, cex_solver; enabled=incomplete_tests),
        mode, css, max_new_tests, CexHarvest(cex_mode, mode),
    )
end

function Arborist.input_signature(e::CDGPEvaluator)::Dict{Symbol,DataType}
    sf = e.spec.synth_funs[1]
    return Dict{Symbol,DataType}(Symbol(p) => _sort_to_type(s) for (p, s) in sf.params)
end

function Arborist.output_signature(e::CDGPEvaluator)::Dict{Symbol,DataType}
    sf = e.spec.synth_funs[1]
    return Dict{Symbol,DataType}(:out => _sort_to_type(sf.sort))
end

"""
    _cdgp_verify!(e, g) -> (status::Symbol, Union{Counterexample,Nothing}, binding)

Formally verify a test-perfect genome with one full counterexample query —
in-process on the warm `CexSolver` when available, else via a z3 subprocess
(`generate_cex_query` + `verify_query`; both produce the same `Z3Result`).
On `:sat` the returned `Counterexample` carries the model's free-var values as
input and the fresh constant `out_<f>` (a spec-valid output at that input) as
expected output; `binding` is the same input keyed by free-var name, as the
uniqueness query and the pointwise evaluator take it.
"""
function _cdgp_verify!(e::CDGPEvaluator, g::RuleNodeGenome)
    smt = try
        CEXGeneration.rulenode_to_smt2(g.tree, e.grammar;
                                    context_type=_synth_context_type(e.spec))
    catch
        return (:unknown, nothing, nothing)
    end

    e.verifications += 1
    r = try
        if e.cex_solver !== nothing
            CEXGeneration.find_counterexample(e.cex_solver, Dict(e.func_name => smt))
        else
            query = CEXGeneration.generate_cex_query(e.spec, Dict(e.func_name => smt))
            CEXGeneration.verify_query(query)
        end
    catch
        CEXGeneration.Z3Result(:unknown, Dict{String,Any}(), String[])
    end

    r.status == :unsat && return (:unsat, nothing, nothing)
    r.status == :sat || return (:unknown, nothing, nothing)

    input = _model_to_input(e.spec, r.model)
    expected = get(r.model, "out_$(e.func_name)", 0)
    return (:sat, Counterexample(input, expected, nothing), _cex_binding(e.spec, r.model))
end

"""Order-independent hashable key for a counterexample input (fixed param set)."""
_cdgp_input_key(input)::Tuple = Tuple(input[k] for k in sort!(collect(keys(input)); by=string))

"""
    _cdgp_verify_per_constraint!(e, g) -> (status, witnesses)

Verify with one universal check per constraint (`check_constraint_satisfaction_witnesses`
on the warm `ConstraintSatSolver`). `:unsat` when every constraint is proven;
`:sat` with the `(constraint index, binding)` of every violated constraint
whose model could be read; `:unknown` otherwise (ill-typed candidate, or
timeouts and no violation found).
"""
function _cdgp_verify_per_constraint!(e::CDGPEvaluator, g::RuleNodeGenome)
    smt = try
        CEXGeneration.rulenode_to_smt2(g.tree, e.grammar;
                                    context_type=_synth_context_type(e.spec))
    catch
        return (:unknown, Tuple{Int,Dict{String,Any}}[])
    end
    e.verifications += 1
    r, ws = try
        CEXGeneration.check_constraint_satisfaction_witnesses(e.css, e.func_name, smt)
    catch
        return (:unknown, Tuple{Int,Dict{String,Any}}[])
    end
    all(==(:unsat), r.status) && return (:unsat, Tuple{Int,Dict{String,Any}}[])
    viol = Tuple{Int,Dict{String,Any}}[(k, Dict{String,Any}(ws[k])) for k in eachindex(r.status)
                                       if r.status[k] === :sat && ws[k] !== nothing && !isempty(ws[k])]
    return (isempty(viol) ? :unknown : :sat, viol)
end

"""
Add one counterexample at a new input as a complete or incomplete test
(`incomplete_tests.jl` decides), recording it in discovery order.
"""
function _cdgp_add_test!(e::CDGPEvaluator, ikey, input, expected, binding)
    push!(e.seen_inputs, ikey)
    if _completion_kind!(e.completion, e.cex_solver, binding, expected) === :complete
        push!(e.counterexamples, Counterexample(input, expected, nothing))
        push!(e.test_cases, IOExample(input, expected))
    else
        # Several outputs are valid here: keep the input only.
        push!(e.counterexamples, Counterexample(input, nothing, nothing))
        push!(e.incomplete, binding)
    end
    return nothing
end

"""
    _cdgp_seed_tests!(e, points) -> Int

Add starting tests before generation 0 (E3; `run_cdgp(...; seed_tests)`): each point (free-variable name →
value) becomes a test by the same policy as a counterexample, with its output from the solver's output oracle.
Where no output can be completed the point is kept as an incomplete test when the constraints are pointwise-
evaluable. Duplicate inputs are skipped. Returns the number added; also counted in `completion.seeded`.
"""
function _cdgp_seed_tests!(e::CDGPEvaluator, points)::Int
    added = 0
    for w in points
        input = _model_to_input(e.spec, w)
        ikey = _cdgp_input_key(input)
        ikey in e.seen_inputs && continue
        binding = _cex_binding(e.spec, w)
        y = e.cex_solver === nothing ? nothing : CEXGeneration.complete_output(e.cex_solver, w)
        if y === nothing
            e.completion.pointwise || continue
            push!(e.seen_inputs, ikey)
            e.completion.incomplete += 1
            push!(e.counterexamples, Counterexample(input, nothing, nothing))
            push!(e.incomplete, binding)
        else
            _cdgp_add_test!(e, ikey, input, y, binding)
        end
        added += 1
    end
    e.completion.seeded += added
    return added
end

"""
Turn the witnesses of one per-constraint verification into tests; returns how
many were added. Every added test fails the verified genome by construction
(it violates that witness's constraint there), so the caller adds the count
to its failed-test total.
"""
function _cdgp_harvest_witnesses!(e::CDGPEvaluator, viol)::Int
    h = e.harvest
    added = 0
    for (_, w) in viol
        if added >= e.max_new_tests
            h.capped += 1
            continue
        end
        input = _model_to_input(e.spec, w)
        ikey = _cdgp_input_key(input)
        if ikey in e.seen_inputs
            h.dup += 1          # a second constraint violated at the same input
            continue
        end
        binding = _cex_binding(e.spec, w)
        y = CEXGeneration.complete_output(e.cex_solver, w)
        if y === nothing
            # No output could be completed. An incomplete test needs none, and
            # without one the genome would keep fitness 0 despite a known
            # violation.
            h.no_output += 1
            e.completion.pointwise || continue
            push!(e.seen_inputs, ikey)
            e.completion.incomplete += 1
            push!(e.counterexamples, Counterexample(input, nothing, nothing))
            push!(e.incomplete, binding)
        else
            _cdgp_add_test!(e, ikey, input, y, binding)
        end
        added += 1
    end
    _harvest_event!(h, length(viol), added)
    return added
end

"""
    evaluate_genome(g::RuleNodeGenome, e::CDGPEvaluator) -> Float64

Fitness = failed tests on the accumulated counterexample set, complete and
incomplete alike (lower better, `0` ⇒ passes everything *and* — once verified —
is formally correct). Genomes that crash the interpreter or Z3 conversion get
`Inf`.
"""
function Arborist.evaluate_genome(g::RuleNodeGenome, e::CDGPEvaluator)::Float64
    key = Arborist.serialize(g)
    haskey(e.cache, key) && return e.cache[key]

    expr = rulenode2expr(g.tree, e.grammar)
    n = length(e.test_cases) + length(e.incomplete)
    failed = 0
    for io in e.test_cases
        out = try
            execute_on_input(e.symboltable, expr, io.in)
        catch
            return (e.cache[key] = Inf)
        end
        out == io.out || (failed += 1)
    end
    for b in e.incomplete
        loss = _incomplete_loss(e.completion, e.symboltable, expr, b)
        isfinite(loss) || return (e.cache[key] = Inf)
        failed += Int(loss)
    end

    # Verify once the pass ratio clears the fitness threshold q (`tests_ratio`).
    # q=1.0 is the conservative variant (only test-perfect candidates); the paper
    # (Błądek et al., EC 2018, §5.6) finds q≈0.75 synthesises more reliably, by
    # eliciting counterexamples earlier instead of stalling until a genome passes
    # every accumulated test at once.
    should_verify = e.solved === nothing &&
        (n == 0 || (n - failed) >= e.tests_ratio * n)
    if should_verify && e.cex_mode === :per_constraint
        status, viol = _cdgp_verify_per_constraint!(e, g)
        if status == :unsat
            failed == 0 && (e.solved = g)   # same acceptance guard as below
        elseif status == :sat
            added = _cdgp_harvest_witnesses!(e, viol)
            if added > 0
                empty!(e.cache)
                failed += added
            end
        elseif failed == 0
            return (e.cache[key] = Inf)
        end
    elseif should_verify
        status, cx, binding = _cdgp_verify!(e, g)
        if status == :unsat
            # A formally correct program passes every sound complete test and
            # every incomplete test, so accept only when test-perfect — mirrors
            # the reference's `evalTests.sum == 0` guard against an unsound
            # test/solver verdict. (A complete test built from a non-unique
            # output is NOT sound, which is why those become incomplete tests.)
            failed == 0 && (e.solved = g)
        elseif status == :sat
            # Dedupe: at q<1 the solver can return an input already in the set
            # (which the genome already fails and `failed` already counts). Only
            # a genuinely new counterexample grows the set. At q=1.0 a test-perfect
            # genome can never fail an existing test, so this never fires.
            ikey = _cdgp_input_key(cx.input)
            if !(ikey in e.seen_inputs)
                _cdgp_add_test!(e, ikey, cx.input, cx.expected_output, binding)
                # All cached fitnesses are stale on the grown test set.
                empty!(e.cache)
                # The new test was derived from this genome's own violation, so it
                # fails it by construction (complete or incomplete alike).
                failed += 1
                _harvest_event!(e.harvest, 1, 1)
            else
                e.harvest.dup += 1
                _harvest_event!(e.harvest, 1, 0)
            end
        elseif failed == 0
            # Test-perfect but unverifiable (:unknown) ⇒ ill-typed / nonlinear
            # candidate — discard. A partial candidate Z3 merely could not refute
            # this time keeps its failed-test fitness.
            return (e.cache[key] = Inf)
        end
    end

    return (e.cache[key] = Float64(failed))
end

"""
    evaluate_cases(g::RuleNodeGenome, e::CDGPEvaluator) -> Vector{Float64}

Per-test loss vector against the current test set, for lexicase selection
(`Arborist.LexicaseSelection`). One entry per accumulated test — complete tests
first, then incomplete tests — `0.0` pass, `1.0` fail, `Inf` if the interpreter
throws on that input.

With `parsimony` (default), one extra case carrying program size is appended.
Lexicase selects specialists on exact per-case wins, and a bloated specialist
wins its cases exactly as well as a compact one — so without a size case nothing
culls bloat at all. Measured on the official SyGuS `max4` (10 seeds, 60 s): this
evaluator without a size case produced 119-node solutions and a 10% success
rate, against 31–36 nodes and 100% for the hybrid evaluator, which had one. As
one case among many in a shuffled order it acts as a tie-break among survivors
rather than a hard size filter.

Side-effect-free by contract: unlike [`evaluate_genome`](@ref) it never issues a
Z3 query, grows the test set, or sets `solved`. The solve loop materializes this
matrix (`_compute_case_fitnesses`) independently of the scalar pass that drives
verification, so growing the set here would make the per-individual matrix
ragged. Empty test set and no parsimony ⇒ empty vector (lexicase then selects at
random).
"""
function Arborist.evaluate_cases(g::RuleNodeGenome, e::CDGPEvaluator)::Vector{Float64}
    expr = rulenode2expr(g.tree, e.grammar)
    n = length(e.test_cases)
    losses = Vector{Float64}(undef, n + length(e.incomplete) + (e.parsimony ? 1 : 0))
    for (i, io) in enumerate(e.test_cases)
        losses[i] = try
            execute_on_input(e.symboltable, expr, io.in) == io.out ? 0.0 : 1.0
        catch
            Inf
        end
    end
    for (j, b) in enumerate(e.incomplete)
        losses[n+j] = _incomplete_loss(e.completion, e.symboltable, expr, b)
    end
    e.parsimony && (losses[end] = Float64(length(g.tree)))
    return losses
end
