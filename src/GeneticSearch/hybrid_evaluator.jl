"""
    hybrid_evaluator.jl

`HybridCDGPEvaluator` — combines the CDGP test-case signal and the
constraint-graded signal into one evaluator, extracting as much information
from the warm in-process solvers as they can give:

  - **Per-constraint verdicts** (`ConstraintSatSolver`, one `check-sat-assuming`
    per constraint per distinct genome) — the ∀-quantified "is this behavior
    right everywhere" bits, plus a **witness input** for every violated
    constraint (the Z3 model).
  - **Witness batteries** (default): every witness Z3 ever produces is filed
    under its constraint and thereafter replayed *pointwise by the
    interpreter* against every genome (`eval_constraint_pointwise`, no solver
    involved). This turns each constraint from one all-or-nothing ∀-bit into a
    growing set of graded cases — a candidate that repairs 3 of a constraint's
    5 known witnesses is now rewarded for it. Set `witness_cases=false` for the
    original one-bit-per-constraint behavior.
  - **Witness-derived tests**: when a candidate passes every accumulated test
    but still violates constraints, the first violation witness is completed
    into a full `(input, expected)` test via `complete_output`. This replaces
    CDGP's separate full counterexample query: the per-constraint check already
    *found* the counterexample, we just harvest it. When the spec accepts
    several outputs at that input the harvest is an **incomplete** test instead
    (input only, judged against every constraint; `incomplete_tests.jl`) — the
    same policy as `CDGPEvaluator`, so both see identical kinds of test.
  - **Formal verification for free**: all constraints `:unsat` ⇒ solved, no
    extra query.

With witness batteries the solver's role narrows to **witness discovery and
certification**: a genome is sent to Z3 only once it is clean on every known
test *and* every known witness (i.e. the cheap evidence is exhausted). Either
it verifies — done — or it yields fresh witnesses that discriminate it from
then on. This is also what keeps the NSGA-II constraint objective informative:
it is an interpreter-computed count available for every genome, not a verdict
only the checked elite possesses.

Selection regimes served by one evaluator (verdicts cached per genome, so each
regime reads the same single Z3 session per distinct genome):

  - `evaluate_genome`  — scalar: failed tests + failed witnesses (+ violated
    constraints, for genomes that reached certification).
  - `evaluate_cases`   — lexicase: `[per-test losses…, per-witness losses…]`,
    optionally closed by a program-size case (`parsimony`).
  - `evaluate_multi`   — NSGA-II objectives `[failed_tests,
    constraint_violations]` (complexity intentionally excluded — see
    `evaluate_multi`; size is a tie-break, not an objective).

Cache discipline: constraint verdicts+witnesses are candidate-intrinsic (never
stale); the witness bank is append-only, so cached loss vectors stay valid as
prefixes and are simply extended; test-loss counts go stale whenever a harvest
grows the test set and are dropped wholesale. Mutates shared state — GA must
run `parallel=false`.
"""

"""
    HybridCDGPEvaluator(spec, grammar, start_symbol, max_depth;
                        mod=Main, z3_timeout_ms=100, max_tests=typemax(Int),
                        gate_constraints=true, witness_cases=true,
                        max_witnesses=6, parsimony=true)

`max_tests` caps the witness-harvested test set (complete and incomplete
together; unlimited by default — it was 64 until 2026-09-26, which bound on
max5 and the multi-answer specs while the test evaluator had no cap) and `max_witnesses` caps the witness battery *per constraint* (the
∀-check itself stays active regardless). Throws for specs outside the
in-process scope. `incomplete_tests=false` harvests every witness into a
complete test with the solver's output (ablation; see `incomplete_tests.jl`).

`gate_constraints=true` (default) reserves the per-constraint Z3 checks for
candidates that are clean on all cheap evidence — every accumulated test and,
with `witness_cases`, every banked witness. Early on both are empty, so the
whole population is checked (the constraint-rich bootstrap that fills the
bank); as evidence accumulates, Z3 spend concentrates on genuinely promising
genomes. Pass `false` for the original check-every-genome behavior.

`parsimony=true` appends program size as one extra lexicase case. Since
complexity is no longer a Pareto objective, lexicase would otherwise run with
zero size pressure (observed: 120-node solutions on max6). As one case among
many in a shuffled order it acts as a tie-break among survivors in the common
case, rather than as a hard size filter.
"""
mutable struct HybridCDGPEvaluator <: Arborist.AbstractMultiObjectiveEvaluator
    spec::Any                # CEXGeneration.Spec
    grammar::AbstractGrammar
    start_symbol::Symbol
    max_depth::Int
    func_name::String
    param_names::Vector{Symbol}
    symboltable::Any
    css::CEXGeneration.ConstraintSatSolver
    cex::CEXGeneration.CexSolver
    n_constraints::Int
    constraint_sexprs::Vector{Any}          # parsed once, for pointwise replay
    test_cases::Vector{IOExample}
    counterexamples::Vector{Counterexample}
    seen_inputs::Set{Any}    # dedupe key set for harvested witness inputs
    # Witness battery: (constraint index, free-var binding). Append-only *within*
    # a round; `hybrid_evict_witnesses!` may remove entries at a round boundary.
    witness_bank::Vector{Tuple{Int,Dict{String,Any}}}
    witness_seen::Set{Tuple{Int,Any}}       # dedupe, per (constraint, input)
    witness_input_seen::Set{Any}            # dedupe across constraints (§5.1)
    witness_counts::Vector{Int}             # banked witnesses per constraint
    # serialized genome → (statuses, witnesses); nothing ⇒ SMT conversion failed.
    status_cache::Dict{String,Union{Tuple{Vector{Symbol},Vector{Union{Dict{String,Any},Nothing}}},Nothing}}
    test_cache::Dict{String,Float64}        # failed-test counts; stale on test growth
    witness_cache::Dict{String,Vector{Float64}}  # per-witness losses; extended on growth
    solved::Union{RuleNodeGenome,Nothing}
    z3_checks::Int
    harvested::Int           # witness→test conversions performed
    max_tests::Int
    max_witnesses::Int
    gate_constraints::Bool   # Z3 constraint checks only for evidence-clean genomes
    witness_cases::Bool      # replay banked witnesses as graded cases
    parsimony::Bool          # append a program-size lexicase case
    tests_ratio::Float64     # gate opens for genomes passing ≥ this ratio of cheap evidence (q)
    # ── witness battery management (CDGP_WITNESS_PLAN.md) ────────────────────
    witness_policy::Symbol   # :none (frozen bank) | :fifo | :info
    max_witnesses_total::Int # global cap on banked witnesses, across constraints
    witness_dedupe_inputs::Bool  # reject an input already banked under any constraint
    witness_test_ratio::Float64  # :ratio policy — witnesses allowed per accumulated test
    witness_touched::Set{String} # genome keys scored since the last eviction
    # Instrumentation (§6.0): one entry per eviction round.
    witness_evicted::Int
    witness_log::Vector{NamedTuple{(:round, :bank, :touched, :allpass, :allfail, :evicted),
                                   Tuple{Int,Int,Int,Int,Int,Int}}}
    incomplete::Vector{Dict{String,Any}}  # incomplete tests: free-var bindings, judged pointwise
    completion::TestCompletion            # complete-vs-incomplete policy and its counters
end

function HybridCDGPEvaluator(spec, grammar::AbstractGrammar, start_symbol::Symbol,
                             max_depth::Int; mod::Module=Main,
                             z3_timeout_ms::Integer=100, max_tests::Int=typemax(Int),
                             gate_constraints::Bool=true,
                             witness_cases::Bool=true, max_witnesses::Int=6,
                             parsimony::Bool=true, tests_ratio::Float64=1.0,
                             witness_policy::Symbol=:none,
                             max_witnesses_total::Int=typemax(Int),
                             witness_dedupe_inputs::Bool=false,
                             witness_test_ratio::Float64=1.0,
                             incomplete_tests::Bool=true)
    witness_policy in (:none, :fifo, :info, :ratio) ||
        throw(ArgumentError("witness_policy must be :none, :fifo, :info or :ratio, " *
                            "got :$witness_policy"))
    isempty(spec.synth_funs) && error("HybridCDGPEvaluator: spec has no synth-fun")
    isempty(spec.constraints) && error("HybridCDGPEvaluator: spec has no constraints")
    sf = spec.synth_funs[1]
    sexprs = Any[CEXGeneration.read_sexprs(c)[1] for c in spec.constraints]
    # If a spec uses syntax the interpreter does not cover, *every* genome would
    # be unevaluable on witness cases and the run would flatten to `Inf`
    # fitness — so the battery is disabled up front, falling back to ∀-verdict
    # cases.
    witness_cases = witness_cases && _pointwise_ok(sexprs, sf.name, spec)
    cex = CEXGeneration.CexSolver(spec; timeout_ms=z3_timeout_ms, nl_arith=false)
    return HybridCDGPEvaluator(
        spec, grammar, start_symbol, max_depth,
        sf.name, Symbol[Symbol(p) for (p, _) in sf.params],
        grammar2symboltable(grammar, mod),
        CEXGeneration.ConstraintSatSolver(spec; timeout_ms=z3_timeout_ms, nl_arith=false),
        cex,
        length(spec.constraints), sexprs,
        IOExample[], Counterexample[], Set{Any}(),
        Tuple{Int,Dict{String,Any}}[], Set{Tuple{Int,Any}}(), Set{Any}(),
        zeros(Int, length(spec.constraints)),
        Dict{String,Union{Tuple{Vector{Symbol},Vector{Union{Dict{String,Any},Nothing}}},Nothing}}(),
        Dict{String,Float64}(), Dict{String,Vector{Float64}}(),
        nothing, 0, 0, max_tests, max_witnesses,
        gate_constraints, witness_cases, parsimony, tests_ratio,
        witness_policy, max_witnesses_total, witness_dedupe_inputs,
        witness_test_ratio, Set{String}(), 0,
        NamedTuple{(:round, :bank, :touched, :allpass, :allfail, :evicted),
                   Tuple{Int,Int,Int,Int,Int,Int}}[],
        Dict{String,Any}[], TestCompletion(spec, cex; enabled=incomplete_tests),
    )
end

function Arborist.input_signature(e::HybridCDGPEvaluator)::Dict{Symbol,DataType}
    sf = e.spec.synth_funs[1]
    return Dict{Symbol,DataType}(Symbol(p) => _sort_to_type(s) for (p, s) in sf.params)
end

function Arborist.output_signature(e::HybridCDGPEvaluator)::Dict{Symbol,DataType}
    sf = e.spec.synth_funs[1]
    return Dict{Symbol,DataType}(:out => _sort_to_type(sf.sort))
end

"""Callback applying the candidate `expr` to concrete synth-fun arguments."""
function _hybrid_apply(e::HybridCDGPEvaluator, expr)
    pnames = e.param_names
    return function (argvals::Vector{Any})
        length(argvals) == length(pnames) ||
            throw(CEXGeneration.PointwiseError("synth-fun applied at wrong arity"))
        input = Dict{Symbol,Any}(pnames[i] => argvals[i] for i in eachindex(pnames))
        return execute_on_input(e.symboltable, expr, input)
    end
end

"""
File a violation witness under its constraint (deduped, capped).

Three admission limits, in order: the **global** cap (`max_witnesses_total`)
bounds the whole pool, which the per-constraint cap alone cannot do — on a
spec with many constraints the battery otherwise outgrows the test set
(observed on max10: 66 witnesses against a 64-test cap). Then the
per-constraint cap. Then dedupe: always on `(constraint, input)`, and with
`witness_dedupe_inputs` also across constraints, since one input violating
three constraints is otherwise banked three times and acts like a single
lexicase case holding three tickets in the shuffle.
"""
function _hybrid_record_witnesses!(e::HybridCDGPEvaluator, statuses, witnesses)::Bool
    e.witness_cases || return false
    grew = false
    for i in eachindex(statuses)
        length(e.witness_bank) >= e.max_witnesses_total && break
        statuses[i] === :sat || continue
        e.witness_counts[i] >= e.max_witnesses && continue
        w = witnesses[i]
        (w === nothing || isempty(w)) && continue
        ikey = Tuple(sort!([(k, v) for (k, v) in w]))
        key = (i, ikey)
        key in e.witness_seen && continue
        e.witness_dedupe_inputs && ikey in e.witness_input_seen && continue
        push!(e.witness_seen, key)
        push!(e.witness_input_seen, ikey)
        push!(e.witness_bank, (i, Dict{String,Any}(w)))
        e.witness_counts[i] += 1
        grew = true
    end
    return grew
end

"""Per-constraint verdicts + witnesses, cached per genome; sets `solved` on all-`:unsat`."""
function _hybrid_statuses!(e::HybridCDGPEvaluator, g::RuleNodeGenome)
    key = Arborist.serialize(g)
    haskey(e.status_cache, key) && return e.status_cache[key]

    smt = try
        CEXGeneration.rulenode_to_smt2(g.tree, e.grammar;
                                    context_type=_synth_context_type(e.spec))
    catch
        return (e.status_cache[key] = nothing)
    end

    r, witnesses = CEXGeneration.check_constraint_satisfaction_witnesses(
        e.css, e.func_name, smt)
    e.z3_checks += e.n_constraints

    if e.solved === nothing && all(==(:unsat), r.status)
        e.solved = g
    end
    _hybrid_record_witnesses!(e, r.status, witnesses)
    return (e.status_cache[key] = (r.status, witnesses))
end

"""Failed-test count on the current test set, complete and incomplete (`Inf` if the interpreter throws)."""
function _hybrid_failed_tests!(e::HybridCDGPEvaluator, g::RuleNodeGenome, key::String)::Float64
    haskey(e.test_cache, key) && return e.test_cache[key]
    expr = rulenode2expr(g.tree, e.grammar)
    failed = 0
    for io in e.test_cases
        out = try
            execute_on_input(e.symboltable, expr, io.in)
        catch
            return (e.test_cache[key] = Inf)
        end
        out == io.out || (failed += 1)
    end
    for b in e.incomplete
        loss = _incomplete_loss(e.completion, e.symboltable, expr, b)
        isfinite(loss) || return (e.test_cache[key] = Inf)
        failed += Int(loss)
    end
    return (e.test_cache[key] = Float64(failed))
end

"""Accumulated tests of both kinds."""
_hybrid_n_tests(e::HybridCDGPEvaluator) = length(e.test_cases) + length(e.incomplete)

"""
Per-banked-witness losses (`0.0` holds, `1.0` violated, `Inf` unevaluable).

The bank is append-only *within a round*, so a cached vector is a valid prefix
and is extended in place rather than recomputed. That prefix property is the
reason `hybrid_evict_witnesses!` must `empty!(witness_cache)`: this validity
test compares lengths only, so after an evict-plus-admit a stale vector would
have the right length and the wrong contents — wrong fitness, no error.

Keys are recorded in `witness_touched` so the eviction pass can transpose the
cached rows into per-witness columns without re-evaluating anything.
"""
function _hybrid_witness_losses!(e::HybridCDGPEvaluator, g::RuleNodeGenome,
                                 key::String)::Vector{Float64}
    (!e.witness_cases || isempty(e.witness_bank)) && return Float64[]
    e.witness_policy === :info && push!(e.witness_touched, key)
    cached = get(e.witness_cache, key, nothing)
    cached !== nothing && length(cached) == length(e.witness_bank) && return cached

    losses = cached === nothing ? Float64[] : cached
    expr = rulenode2expr(g.tree, e.grammar)
    apply = _hybrid_apply(e, expr)
    for idx in (length(losses)+1):length(e.witness_bank)
        (ci, w) = e.witness_bank[idx]
        push!(losses, try
            CEXGeneration.eval_constraint_pointwise(
                e.constraint_sexprs[ci], e.func_name, w, apply) ? 0.0 : 1.0
        catch
            Inf
        end)
    end
    return (e.witness_cache[key] = losses)
end

_hybrid_failed_witnesses(losses::Vector{Float64})::Float64 =
    isempty(losses) ? 0.0 : Float64(count(!=(0.0), losses))

"""
    hybrid_evict_witnesses!(e, round) -> Int

Drop banked witnesses that no longer earn their place, returning the number
evicted. **Call only at a round boundary**, never mid-generation: Arborist's
lexicase reads `n_cases` from individual 1 alone and indexes every other
individual at those positions, so changing the bank inside a selection pass
gives a ragged matrix — a `BoundsError`, or a silent truncation.

Policies:

- `:none` — the original frozen bank. Once a constraint reaches
  `max_witnesses`, its evidence never changes again, so late genomes are graded
  against witnesses harvested from generation-1 primitives.
- `:fifo` — retire the oldest witness of every saturated constraint each round,
  freeing a slot for fresher evidence. The ablation baseline: if this matches
  `:info`, the informativeness machinery is not paying for itself.
- `:ratio` — hold the pool to `witness_test_ratio` witnesses per accumulated
  test (floored at one per constraint), retiring oldest first. This is the
  policy the §6.0 instrumentation actually supports: the battery was measured
  outgrowing the test set 3:1 to 7.5:1, so lexicase selects mostly on witnesses
  and the accumulated tests stop steering.
- `:info` — drop witnesses whose loss column is **constant across the genomes
  scored this round**. A case everyone passes, or everyone fails, filters
  nobody in a lexicase shuffle, so it carries no selection information. This
  costs a transpose rather than a sweep: `witness_cache` already holds the
  per-genome loss rows. **Measured to be near-inert**: over ~40 rounds on
  max5 / countpos3 / median3, with 600–1500 genomes scored per round, it found
  one constant column in total. Kept for the record and as an ablation; it is
  not the recommended policy.

At least one witness per constraint is always retained, newest first, so a
constraint never silently loses its graded stand-in and fall back to the
∀-verdict. `witness_seen` is deliberately *not* pruned — leaving it intact
stops an evicted witness being re-banked immediately, which would thrash.
"""
function hybrid_evict_witnesses!(e::HybridCDGPEvaluator, round::Int=0)::Int
    (!e.witness_cases || e.witness_policy === :none || isempty(e.witness_bank)) && return 0

    n = length(e.witness_bank)
    drop = falses(n)
    allpass = 0
    allfail = 0
    ntouched = 0

    if e.witness_policy === :fifo
        # Oldest first, one per constraint that has hit its cap.
        for ci in 1:e.n_constraints
            e.witness_counts[ci] >= e.max_witnesses || continue
            idx = findfirst(j -> e.witness_bank[j][1] == ci, 1:n)
            idx === nothing || (drop[idx] = true)
        end
    elseif e.witness_policy === :ratio
        # Hold the pool to `witness_test_ratio` witnesses per accumulated test,
        # retiring oldest first. Measured pathology (§6.0 instrumentation): the
        # battery outgrows the test set 3:1 to 7.5:1, so lexicase selects mostly
        # on witnesses and the accumulated tests stop steering. A per-constraint
        # cap cannot bound this — the pool scales with `n_constraints`.
        # Floor at one per constraint, so the cap never fights the
        # keep-one-per-constraint guarantee below.
        budget = max(e.n_constraints,
                     floor(Int, e.witness_test_ratio * _hybrid_n_tests(e)))
        excess = n - budget
        for j in 1:n
            excess > 0 || break
            drop[j] = true
            excess -= 1
        end
    else  # :info
        rows = [e.witness_cache[k] for k in e.witness_touched if haskey(e.witness_cache, k)]
        ntouched = length(rows)
        # Too little evidence to judge a column — leave the bank alone.
        ntouched < 2 && return 0
        for j in 1:n
            col = (r[j] for r in rows if length(r) >= j)
            first_val = nothing
            constant = true
            seen = 0
            for v in col
                seen += 1
                if first_val === nothing
                    first_val = v
                elseif (v == 0.0) != (first_val == 0.0)
                    constant = false
                    break
                end
            end
            (seen < 2 || !constant) && continue
            drop[j] = true
            first_val == 0.0 ? (allpass += 1) : (allfail += 1)
        end
    end

    # Never take a constraint to zero witnesses: un-drop its newest.
    for ci in 1:e.n_constraints
        idxs = [j for j in 1:n if e.witness_bank[j][1] == ci]
        isempty(idxs) && continue
        all(j -> drop[j], idxs) && (drop[last(idxs)] = false)
    end

    nevict = count(drop)
    if nevict > 0
        keep = [j for j in 1:n if !drop[j]]
        e.witness_bank = e.witness_bank[keep]
        fill!(e.witness_counts, 0)
        for (ci, _) in e.witness_bank
            e.witness_counts[ci] += 1
        end
        # The prefix cache is invalidated wholesale: its validity test is a
        # length comparison, which eviction makes unsound (see above).
        empty!(e.witness_cache)
        e.witness_evicted += nevict
    end
    empty!(e.witness_touched)

    push!(e.witness_log, (round = round, bank = n, touched = ntouched,
                          allpass = allpass, allfail = allfail, evicted = nevict))
    return nevict
end

"""Per-round witness-battery instrumentation (§6.0), oldest round first."""
hybrid_witness_log(e::HybridCDGPEvaluator) = e.witness_log

"""
Harvest the first available violation witness of a test-perfect genome into a
new test case — complete when the spec accepts one output there, incomplete
otherwise. Returns `true` if the test set grew (test cache is emptied).
"""
function _hybrid_harvest!(e::HybridCDGPEvaluator, statuses, witnesses)::Bool
    _hybrid_n_tests(e) >= e.max_tests && return false
    for i in eachindex(statuses)
        statuses[i] === :sat || continue
        w = witnesses[i]
        (w === nothing || isempty(w)) && return false
        wkey = Tuple(sort!([(k, v) for (k, v) in w]))
        wkey in e.seen_inputs && continue
        expected = CEXGeneration.complete_output(e.cex, w)
        expected === nothing && continue
        push!(e.seen_inputs, wkey)
        input = _model_to_input(e.spec, w)
        binding = _cex_binding(e.spec, w)
        if _completion_kind!(e.completion, e.cex, binding, expected) === :complete
            push!(e.counterexamples, Counterexample(input, expected, nothing))
            push!(e.test_cases, IOExample(input, expected))
        else
            push!(e.counterexamples, Counterexample(input, nothing, nothing))
            push!(e.incomplete, binding)
        end
        e.harvested += 1
        empty!(e.test_cache)   # all failed-test counts are stale on the grown set
        return true
    end
    return false
end

"""
Should this genome's per-constraint Z3 checks run now? The gate opens once the
candidate passes at least a fraction `tests_ratio` (q) of the cheap evidence —
the accumulated tests plus the banked witnesses. q=1.0 is the conservative gate
(check only candidates clean on *all* cheap evidence, i.e. `failed==0 &&
nwit==0`); lower q spends Z3 on near-clean candidates too, eliciting witnesses
and certification earlier — the hybrid analogue of the paper's fitness
threshold for the test-only variant.
"""
function _hybrid_gate_open(e::HybridCDGPEvaluator, failed::Float64, nwit::Float64)::Bool
    total = _hybrid_n_tests(e) + length(e.witness_bank)
    total == 0 && return true
    return (total - failed - nwit) >= e.tests_ratio * total
end

"""
Shared scoring core: returns `(failed_tests, constraint_score)` where
`constraint_score` counts failed banked witnesses plus, for genomes that
cleared the gate and were certified, the constraints Z3 could not prove.
Returns `nothing` when the genome is unevaluable.
"""
function _hybrid_score!(e::HybridCDGPEvaluator, g::RuleNodeGenome)
    key = Arborist.serialize(g)
    failed = _hybrid_failed_tests!(e, g, key)
    isfinite(failed) || return nothing

    wl = _hybrid_witness_losses!(e, g, key)
    any(isinf, wl) && return nothing
    nwit = _hybrid_failed_witnesses(wl)

    # Gate: spend Z3 only on candidates that clear the fitness threshold q over
    # the cheap evidence (tests + banked witnesses). Without a witness battery
    # there is no graded stand-in, so gated genomes keep the legacy pessimistic
    # constant (every gated genome ranks below every certified one, ordered among
    # themselves by tests alone).
    if e.gate_constraints && !_hybrid_gate_open(e, failed, nwit)
        return (failed, e.witness_cases ? nwit : Float64(e.n_constraints))
    end

    st = _hybrid_statuses!(e, g)
    st === nothing && return nothing
    statuses, witnesses = st
    nviol = Float64(count(!=(:unsat), statuses))

    # Harvest a witness into a test whenever the gate is open and constraints are
    # violated (at q=1.0 this only happens for test-perfect genomes, so behaviour
    # is unchanged there; at q<1.0 near-clean candidates also contribute tests).
    if nviol > 0 && _hybrid_harvest!(e, statuses, witnesses)
        # The harvested test came from this genome's own violation; recompute.
        failed = _hybrid_failed_tests!(e, g, key)
        isfinite(failed) || return nothing
    end
    # This genome's own fresh witnesses may have just entered the bank.
    wl = _hybrid_witness_losses!(e, g, key)
    any(isinf, wl) && return nothing

    # A violated constraint whose witness is already in the bank is paid for by
    # that witness case; only add the ∀-verdicts no witness represents (chiefly
    # `:unknown` timeouts and violations whose model was empty or capped out).
    extra = nviol
    if e.witness_cases
        covered = falses(e.n_constraints)
        for (idx, loss) in enumerate(wl)
            loss == 0.0 || (covered[e.witness_bank[idx][1]] = true)
        end
        extra = Float64(count(i -> statuses[i] !== :unsat && !covered[i],
                              1:e.n_constraints))
    end

    return (failed, _hybrid_failed_witnesses(wl) + extra)
end

"""
    evaluate_genome(g, e::HybridCDGPEvaluator) -> Float64

Scalar fitness = failed tests + failed witnesses + (for certified genomes)
constraints not proven to hold. Every term is a count of concrete failures, so
gated and certified genomes share one scale — no artificial constant penalty
is needed to keep them apart. When the test set can no longer discriminate a
candidate (0 failed tests) but constraints are violated, the violation witness
becomes a new test first.
"""
function Arborist.evaluate_genome(g::RuleNodeGenome, e::HybridCDGPEvaluator)::Float64
    s = _hybrid_score!(e, g)
    s === nothing && return Inf
    return s[1] + s[2]
end

"""
    evaluate_cases(g, e::HybridCDGPEvaluator) -> Vector{Float64}

Lexicase case pool = per-test losses (complete, then incomplete), then
per-banked-witness losses, then (with `parsimony`) one program-size case. Losses are `0.0` pass / `1.0` fail /
`Inf` crash. Does not grow the test set or the bank, so the case-vector length
is stable within a selection pass.

Witness cases need no Z3 and are therefore defined for *every* genome, gated or
not — the asymmetry of the old one-bit-per-constraint pool (where gated genomes
had to be given a neutral filler) is gone. With `witness_cases=false` the pool
falls back to that older layout.
"""
function Arborist.evaluate_cases(g::RuleNodeGenome, e::HybridCDGPEvaluator)::Vector{Float64}
    key = Arborist.serialize(g)
    expr = rulenode2expr(g.tree, e.grammar)

    losses = Float64[]
    for io in e.test_cases
        push!(losses, try
            execute_on_input(e.symboltable, expr, io.in) == io.out ? 0.0 : 1.0
        catch
            Inf
        end)
    end
    for b in e.incomplete
        push!(losses, _incomplete_loss(e.completion, e.symboltable, expr, b))
    end

    if e.witness_cases
        append!(losses, _hybrid_witness_losses!(e, g, key))
    else
        # Legacy pool: one ∀-verdict case per constraint. Gated genomes were
        # never checked, so they take a neutral 1.0 rather than new Z3 work.
        st = e.gate_constraints ?
             (haskey(e.status_cache, key) ? e.status_cache[key] : missing) :
             _hybrid_statuses!(e, g)
        if st === missing
            append!(losses, fill(1.0, e.n_constraints))
        elseif st === nothing
            append!(losses, fill(Inf, e.n_constraints))
        else
            statuses, _ = st
            for i in 1:e.n_constraints
                push!(losses, statuses[i] === :unsat ? 0.0 :
                              statuses[i] === :sat   ? 1.0 : Inf)
            end
        end
    end

    e.parsimony && push!(losses, Float64(length(g.tree)))
    return losses
end

"""
    evaluate_multi(e::HybridCDGPEvaluator, g) -> Vector{Float64}

NSGA-II objectives (all minimized): `[failed_tests, constraint_violations]`,
the two terms of `evaluate_genome`.

Complexity is deliberately NOT an objective: with it, tiny near-miss programs
(`y + x`, `max(z,x)`) stay non-dominated forever and the front never commits
to full correctness — observed degenerating on 4 of 5 benchmark specs. Size is
bounded by `depth_cap` and used only as a tie-break when extracting the best
front member (`_cdgp_best`).

The constraint objective is the witness-battery count, so it varies across the
whole population. Under the older ∀-bit scoring, gating pinned it to
`n_constraints` for every unchecked genome and NSGA-II silently degraded to
single-objective search (observed on max5: 8 genomes checked in 2,200
generations).
"""
function Arborist.evaluate_multi(e::HybridCDGPEvaluator, g::RuleNodeGenome)::Vector{Float64}
    s = _hybrid_score!(e, g)
    s === nothing && return [Inf, Inf]
    return [s[1], s[2]]
end

Arborist.objective_names(::HybridCDGPEvaluator) =
    ["failed_tests", "constraint_violations"]
