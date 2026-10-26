"""
    trace.jl

Per-generation instrumentation for `run_cdgp`, and a fixed validation battery
for scoring programs on a scale that does not move.

## Why training fitness is not enough for "fitness over generations"

CDGP's fitness is measured against an evidence set that **grows during the run**
(tests harvested from counterexamples, witnesses banked from violations). So the
best training fitness is a sawtooth: the population drives it towards 0, a new
counterexample arrives, and it jumps back up — without the population having
got any worse. Two consequences for plotting:

1. A training-fitness curve compares a genome at generation 10 against a
   different, smaller yardstick than at generation 100.
2. Arms accumulate evidence at different rates and, across fitness modes
   (`:tests` vs `:hybrid`), do not even share a scale.

`ValidationBattery` fixes both. It is a fixed set of concrete inputs, chosen once
per spec and shared by every arm and seed, on which a program is scored against
**the specification itself** — pointwise, via `eval_constraint_pointwise`, with
no Z3. The headline measure, `acc`, is the fraction of inputs at which *every*
constraint holds. Because the paired spec variants are pointwise-equivalent, `acc`
is also invariant to specification style: a case-split spec and its
functional-definition twin score a program identically, which the
per-(input, constraint) rate `pairs` does not (an implication with a false guard
holds vacuously, so a six-way split floors `pairs` near 5/6 for any program).

Validation is computed **after** the run, on the distinct best genomes the trace
recorded, so it costs nothing inside the timed search.
"""

"""
    CDGPTrace()

Collector for `run_cdgp(...; trace=CDGPTrace())`. After the run it holds one
entry per generation (best/mean training fitness, best program size, evidence
counts, cumulative Z3 calls by kind), one entry per round (population diversity
and size), the distinct best genomes seen, and the generation at which a
verified program first existed.

Z3 counts are cumulative **from the start of this run** (diffed from a
`z3_stats()` snapshot), so they are unaffected by anything else the process did.

The solve point is recorded at generation resolution. `run_cdgp` itself only
notices a solve at the end of a round, so its wall-clock `secs` overstates
time-to-solve by up to `generations_per_round - 1` generations; use
`solve_elapsed_s` for survival analysis.
"""
mutable struct CDGPTrace
    # ── one entry per generation ─────────────────────────────────────────────
    gen::Vector{Int}
    round::Vector{Int}
    elapsed_s::Vector{Float64}
    best_fitness::Vector{Float64}     # Arborist scalar fitness (includes bloat penalty); NaN under NSGA-II
    mean_fitness::Vector{Float64}     # mean finite fitness; filled from the round's history
    best_size::Vector{Int}
    best_key::Vector{String}          # serialized best genome; "" when unavailable (NSGA-II)
    tests::Vector{Int}                # accumulated tests, complete + incomplete
    incomplete_tests::Vector{Int}     # of which incomplete
    witnesses::Vector{Int}
    solved::Vector{Bool}              # a verified program exists by this generation
    z3_constraint_checks::Vector{Int}
    z3_cex_queries::Vector{Int}
    z3_complete_output::Vector{Int}
    z3_output_unique::Vector{Int}
    z3_subprocess::Vector{Int}
    z3_time_s::Vector{Float64}
    # ── one entry per round ──────────────────────────────────────────────────
    round_end_gen::Vector{Int}
    unique_genomes::Vector{Int}
    mean_size::Vector{Float64}
    max_size::Vector{Int}
    # ── run level ────────────────────────────────────────────────────────────
    genomes::Dict{String,RuleNodeGenome}   # distinct best genomes, for post-hoc scoring
    stopped_early::Bool                    # run ended mid-round at a solve (last round has no population stats)
    solve_gen::Int                         # 0 ⇒ never solved
    solve_elapsed_s::Float64               # NaN ⇒ never solved
    harvested::Int                         # witness→test conversions (hybrid; else 0)
    witnesses_evicted::Int                 # battery evictions (hybrid; else 0)
    completion::Any                        # completion_stats at the last generation (nothing before)
    z3_base::Any                           # z3_stats() snapshot at run start
    t0::Float64
end

CDGPTrace() = CDGPTrace(Int[], Int[], Float64[], Float64[], Float64[], Int[], String[],
                        Int[], Int[], Int[], Bool[], Int[], Int[], Int[], Int[], Int[], Float64[],
                        Int[], Int[], Float64[], Int[],
                        Dict{String,RuleNodeGenome}(), false, 0, NaN, 0, 0, nothing, nothing, 0.0)

Base.length(tr::CDGPTrace) = length(tr.gen)

"""Anchor the trace to the run's clock and to the Z3 counters as they stand now."""
function _trace_begin!(tr::CDGPTrace, t0::Float64)
    tr.t0 = t0
    tr.z3_base = CEXGeneration.z3_stats()
    return tr
end

function _trace_push_common!(tr::CDGPTrace, evaluator, g::Int, rnd::Int)
    push!(tr.gen, g)
    push!(tr.round, rnd)
    push!(tr.elapsed_s, time() - tr.t0)
    push!(tr.mean_fitness, NaN)
    ninc = length(_cdgp_incomplete(evaluator))
    push!(tr.tests, length(_cdgp_tests(evaluator)) + ninc)
    push!(tr.incomplete_tests, ninc)
    push!(tr.witnesses, _cdgp_witnesses(evaluator))
    solved = evaluator.solved !== nothing
    push!(tr.solved, solved)
    if solved && tr.solve_gen == 0
        tr.solve_gen = g
        tr.solve_elapsed_s = tr.elapsed_s[end]
    end
    tr.harvested = hasproperty(evaluator, :harvested) ? evaluator.harvested : 0
    tr.witnesses_evicted = hasproperty(evaluator, :witness_evicted) ? evaluator.witness_evicted : 0
    tr.completion = _cdgp_completion(evaluator)
    d = CEXGeneration.z3_stats_diff(CEXGeneration.z3_stats(), tr.z3_base)
    push!(tr.z3_constraint_checks, d.constraint_checks)
    push!(tr.z3_cex_queries, d.cex_queries)
    push!(tr.z3_complete_output, d.complete_output)
    push!(tr.z3_output_unique, d.output_unique)
    push!(tr.z3_subprocess, d.subprocess)
    push!(tr.z3_time_s, d.time_s)
    return nothing
end

"""
Arborist callback for one round. Generation numbers restart at 1 on every
`solve` call, so `gen_offset` (generations completed in earlier rounds) maps
them onto the run's global generation axis.
"""
function _trace_callback(tr::CDGPTrace, evaluator, rnd::Int, gen_offset::Int, engine::Symbol)
    if engine === :ga
        return function (gen, best_fitness, best_genome)
            _trace_push_common!(tr, evaluator, gen_offset + gen, rnd)
            push!(tr.best_fitness, Float64(best_fitness))
            key = Arborist.serialize(best_genome)
            push!(tr.best_key, key)
            push!(tr.best_size, length(best_genome.tree))
            # Deep-copied because the population's genome objects may be reused.
            haskey(tr.genomes, key) || (tr.genomes[key] = deepcopy(best_genome))
            return nothing
        end
    end
    # NSGA-II reports (gen, front_size, hypervolume): no per-generation best.
    return function (gen, _front_size, _hv)
        _trace_push_common!(tr, evaluator, gen_offset + gen, rnd)
        push!(tr.best_fitness, NaN)
        push!(tr.best_key, "")
        push!(tr.best_size, 0)
        return nothing
    end
end

"""
The run stopped at a solve partway through a round, so Arborist returned no
result for it: those generations keep `mean_fitness = NaN`, and the round has no
population-stats entry. The solve itself was recorded by the callback.
"""
function _trace_round_stopped!(tr::CDGPTrace)
    tr.stopped_early = true
    return nothing
end

"""
Fold round-level results into the trace: mean fitness history, population
stats, and a solve that no callback saw.

Arborist calls the callback at the *start* of each generation, after that
generation's population is evaluated. Offspring bred in a round's final
generation are evaluated after the last callback, so a solve found there is
invisible to the callback — the run then stops before another round begins. It
is attributed here to the round's last generation, timed at round end (accurate
to one generation's evaluation).
"""
function _trace_round_end!(tr::CDGPTrace, result, first_idx::Int, evaluator)
    last_idx = length(tr.gen)
    n = last_idx - first_idx + 1
    if n > 0 && evaluator.solved !== nothing && tr.solve_gen == 0
        tr.solve_gen = tr.gen[last_idx]
        tr.solve_elapsed_s = time() - tr.t0
        tr.solved[last_idx] = true
    end
    if n > 0 && hasproperty(result, :mean_history)
        mh = result.mean_history
        k = min(n, length(mh))
        for j in 1:k
            tr.mean_fitness[last_idx - k + j] = mh[end - k + j]
        end
    end
    # NSGA-II: recover this round's best from the front for the last generation.
    if n > 0 && tr.best_key[last_idx] == ""
        (bg, bf) = _cdgp_best(result)
        if bg !== nothing
            key = Arborist.serialize(bg)
            tr.best_key[last_idx] = key
            tr.best_fitness[last_idx] = bf
            tr.best_size[last_idx] = length(bg.tree)
            haskey(tr.genomes, key) || (tr.genomes[key] = deepcopy(bg))
        end
    end
    pop = result.population
    push!(tr.round_end_gen, n > 0 ? tr.gen[last_idx] : 0)
    push!(tr.unique_genomes, length(unique(Arborist.serialize(p) for p in pop)))
    sizes = [length(p.tree) for p in pop]
    push!(tr.mean_size, isempty(sizes) ? NaN : sum(sizes) / length(sizes))
    push!(tr.max_size, isempty(sizes) ? 0 : maximum(sizes))
    return nothing
end

# ── validation battery ───────────────────────────────────────────────────────

"""
    ValidationBattery(spec, grammar; n=256, seed=20260925, small=3, wide=1000, mod=Main)

`n` fixed inputs over the spec's free variables, drawn once from a seeded RNG:
half from `-small:small` (dense in ties, zeros and sign changes, where these LIA
specs' bugs live) and half from `-wide:wide`. Bool variables are drawn
uniformly. The same `(spec, n, seed, small, wide)` always yields the same
battery, so every arm and seed is scored on identical inputs.

Known limitation: for **predicate** specs the input distribution is not balanced
by output, so a constant program can score well (random 4-tuples are rarely
sorted, so `false` is usually right). Balancing by output needs the expected
outputs up front (one `complete_output` per input) and is not done here.
"""
struct ValidationBattery
    inputs::Vector{Dict{String,Any}}
    sexprs::Vector{Any}
    func_name::String
    param_names::Vector{Symbol}
    symboltable::Any
    grammar::AbstractGrammar
end

function ValidationBattery(spec, grammar::AbstractGrammar; n::Int=256, seed::Integer=20260925,
                           small::Int=3, wide::Int=1000, mod::Module=Main)
    isempty(spec.synth_funs) && error("ValidationBattery: spec has no synth-fun")
    isempty(spec.free_vars) && error("ValidationBattery: spec declares no free variables")
    sf = spec.synth_funs[1]
    rng = Random.MersenneTwister(seed)
    inputs = Vector{Dict{String,Any}}(undef, n)
    for i in 1:n
        span = i <= n ÷ 2 ? small : wide
        inputs[i] = Dict{String,Any}(
            fv.name => (fv.sort == "Bool" ? rand(rng, Bool) : rand(rng, -span:span))
            for fv in spec.free_vars)
    end
    sexprs = Any[CEXGeneration.read_sexprs(c)[1] for c in spec.constraints]
    return ValidationBattery(inputs, sexprs, sf.name,
                             Symbol[Symbol(p) for (p, _) in sf.params],
                             grammar2symboltable(grammar, mod), grammar)
end

Base.length(vb::ValidationBattery) = length(vb.inputs)

"""
    validation_scores(vb, genome) -> (acc, pairs)

`acc` — fraction of battery inputs at which every constraint holds (the headline;
invariant to how the spec is split into constraints). `pairs` — fraction of
(input, constraint) pairs that hold (more graded, but style-dependent). An input
the interpreter cannot evaluate counts as a violation.
"""
function validation_scores(vb::ValidationBattery, g::RuleNodeGenome)
    expr = rulenode2expr(g.tree, vb.grammar)
    pnames = vb.param_names
    apply = function (argvals::Vector{Any})
        length(argvals) == length(pnames) ||
            throw(CEXGeneration.PointwiseError("synth-fun applied at wrong arity"))
        return execute_on_input(vb.symboltable,
                                expr, Dict{Symbol,Any}(pnames[i] => argvals[i] for i in eachindex(pnames)))
    end
    ok_inputs = 0
    ok_pairs = 0
    for w in vb.inputs
        all_ok = true
        for s in vb.sexprs
            holds = try
                CEXGeneration.eval_constraint_pointwise(s, vb.func_name, w, apply)
            catch
                false
            end
            holds ? (ok_pairs += 1) : (all_ok = false)
        end
        all_ok && (ok_inputs += 1)
    end
    ni = length(vb.inputs)
    return (acc = ok_inputs / ni, pairs = ok_pairs / (ni * length(vb.sexprs)))
end

"""
    trace_validation(tr, vb) -> Dict{String,NamedTuple}

Score every distinct best genome the trace recorded. Keyed by serialized genome,
so per-generation values are a lookup on `tr.best_key`. Runs after the search,
so it costs nothing inside the timed region.
"""
function trace_validation(tr::CDGPTrace, vb::ValidationBattery)
    return Dict(k => validation_scores(vb, g) for (k, g) in tr.genomes)
end
