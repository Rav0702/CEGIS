"""
    run_cdgp.jl

`run_cdgp` — wires the `CDGPEvaluator` and grammar-aware operators into
Arborist's GA engine. Evolution runs in rounds of `generations_per_round`
generations, warm-starting each round from the previous round's final
population. Arborist's `solve` has no early-stop hook, so the per-generation
callback throws `_CDGPSolved` as soon as the evaluator holds a formally verified
program, and the run ends at that generation rather than at the end of the round.
(Finishing the round wasted up to `generations_per_round - 1` generations of
evaluation after the solve — for the hybrid evaluator, Z3-checking a population
full of near-solutions: a median 13 extra tests harvested per solved max5 run.) The fresh evaluation at each
round start also refreshes elites whose carried-over fitness went stale after
a mid-round counterexample grew the test set.
"""

"""
    CDGPResult

Outcome of a `run_cdgp` run.

- `solved`           — was a formally verified program found (Z3 `:unsat`)?
- `program`          — the verified `RuleNodeGenome` (or best-by-fitness if unsolved;
                       `nothing` when no round ran).
- `expr`             — its Julia-expression string.
- `best_fitness`     — Arborist fitness of the final round's best (failed tests + bloat term);
                       for a solved run, the verified program's (the bloat term alone).
- `generations`      — total generations run; a solved run stops at the generation in
                       which the verified program appeared.
- `rounds`           — number of `solve` rounds run.
- `test_cases`       — the accumulated counterexample-derived **complete** tests
                       (always empty for `fitness=:constraints`).
- `counterexamples`  — the counterexamples in discovery order (empty for `fitness=:constraints`);
                       those that became incomplete tests have `expected_output === nothing`.
- `verifications`    — Z3 work issued: counterexample queries (one per distinct
                       test-perfect program) for `fitness=:tests`;
                       `check-sat-assuming` calls for `fitness=:constraints`.
- `witnesses`        — banked violation witnesses replayed as graded cases
                       (`fitness=:hybrid` with `witness_cases`; `0` otherwise).
- `incomplete_tests` — the accumulated **incomplete** tests (free-var bindings), for
                       counterexamples where the spec accepts several outputs.
- `completion`       — `completion_stats` of the evaluator: whether the spec was proven
                       single-answer, and how many tests of each kind were created, how
                       many uniqueness queries ran, how many tests went unchecked.
- `harvest`          — what the counterexample path did (`harvest_stats`): verification
                       events that found a violation, witnesses returned, tests added,
                       duplicates, completion failures, capped, multi-test events.
- `guided`           — what the guided mutation path did (`guided_stats`; `mode = :none`
                       when the run used plain subtree mutation).
"""
struct CDGPResult
    solved::Bool
    program::Union{RuleNodeGenome,Nothing}
    expr::String
    best_fitness::Float64
    generations::Int
    rounds::Int
    test_cases::Vector{IOExample}
    counterexamples::Vector{Counterexample}
    verifications::Int
    witnesses::Int
    incomplete_tests::Vector{Dict{String,Any}}
    completion::NamedTuple
    harvest::NamedTuple
    guided::NamedTuple
end

"""Thrown from the per-generation callback to stop a round at the solve."""
struct _CDGPSolved <: Exception end

# Uniform accessors so the round loop and CDGPResult work with any evaluator.
_cdgp_tests(e::CDGPEvaluator) = e.test_cases
_cdgp_tests(::CDGPConstraintEvaluator) = IOExample[]
_cdgp_tests(e::HybridCDGPEvaluator) = e.test_cases
_cdgp_counterexamples(e::CDGPEvaluator) = e.counterexamples
_cdgp_counterexamples(::CDGPConstraintEvaluator) = Counterexample[]
_cdgp_counterexamples(e::HybridCDGPEvaluator) = e.counterexamples
_cdgp_z3_calls(e::CDGPEvaluator) = e.verifications
_cdgp_z3_calls(e::CDGPConstraintEvaluator) = e.z3_checks
_cdgp_z3_calls(e::HybridCDGPEvaluator) = e.z3_checks
_cdgp_witnesses(::Union{CDGPEvaluator,CDGPConstraintEvaluator}) = 0
_cdgp_witnesses(e::HybridCDGPEvaluator) = length(e.witness_bank)
_cdgp_incomplete(e::Union{CDGPEvaluator,HybridCDGPEvaluator}) = e.incomplete
_cdgp_incomplete(::CDGPConstraintEvaluator) = Dict{String,Any}[]
_cdgp_completion(e::Union{CDGPEvaluator,HybridCDGPEvaluator}) = completion_stats(e.completion)
_cdgp_completion(::CDGPConstraintEvaluator) =
    (enabled = false, single_answer = nothing, pointwise = false,
     complete = 0, incomplete = 0, unique_checks = 0, unchecked = 0)
_cdgp_harvest(e::CDGPEvaluator) = harvest_stats(e.harvest)
_cdgp_harvest(e::HybridCDGPEvaluator) =
    (requested = :hybrid, mode = :hybrid, fallback = false, events = 0, witnesses = 0,
     added = e.harvested, dup = 0, no_output = 0, capped = 0, multi_events = 0, max_per_event = 0)
_cdgp_harvest(::CDGPConstraintEvaluator) =
    (requested = :none, mode = :none, fallback = false, events = 0, witnesses = 0,
     added = 0, dup = 0, no_output = 0, capped = 0, multi_events = 0, max_per_event = 0)
_cdgp_tests_label(e) = isempty(_cdgp_incomplete(e)) ? "tests=$(length(_cdgp_tests(e)))" :
    "tests=$(length(_cdgp_tests(e)))+$(length(_cdgp_incomplete(e)))inc"
_cdgp_progress(e::CDGPEvaluator) =
    "$(_cdgp_tests_label(e)) z3_calls=$(e.verifications)"
_cdgp_progress(e::CDGPConstraintEvaluator) =
    "constraints=$(e.n_constraints) z3_checks=$(e.z3_checks)"
_cdgp_progress(e::HybridCDGPEvaluator) =
    "$(_cdgp_tests_label(e)) (harvested=$(e.harvested)) " *
    "witnesses=$(length(e.witness_bank)) " *
    "constraints=$(e.n_constraints) z3_checks=$(e.z3_checks)"

# Best genome + scalar fitness across the two engines' result types. For
# NSGA-II the "best" is the front member with the lowest failed_tests +
# violated_constraints, tie-broken by program size (size is deliberately not
# a Pareto objective — see HybridCDGPEvaluator.evaluate_multi).
_cdgp_best(result::Arborist.GPResult) = (result.best_genome, result.best_fitness)
function _cdgp_best(result::Arborist.NSGAIIResult)
    isempty(result.pareto_front) && return (nothing, Inf)
    order = sortperm(eachindex(result.pareto_front);
                     by=i -> (sum(result.pareto_fitnesses[i]),
                              Float64(length(result.pareto_front[i].tree))))
    i = order[1]
    return (result.pareto_front[i], sum(result.pareto_fitnesses[i]))
end

"""
    run_cdgp(spec_path; kwargs...) -> CDGPResult

Run counterexample-driven genetic programming on the SyGuS spec at `spec_path`.

Keyword arguments:
- `pop_size=100`, `generations=200`, `elitism=2` — with only a handful of tests
  the fitness signal is sparse, so CDGP needs a larger population than the
  graded approach (`pop_size=40` stagnates even on max2)
- `generations_per_round=10` — generations per `solve` round (solved-check granularity)
- `max_depth=4`        — depth of randomly initialized programs
- `subtree_depth=3`    — depth of subtrees introduced by mutation
- `depth_cap=6`        — offspring deeper than this are rejected (keeps Z3 fast)
- `mutation_rate=0.6`, `crossover_rate=0.3`, `tournament_size=3`, `bloat_penalty=1e-3`
- `selection=nothing`  — parent-selection strategy; `nothing` ⇒
  `Arborist.TournamentSelection(tournament_size)`. Pass
  `Arborist.LexicaseSelection()` for lexicase; the selection cases come from
  the evaluator's `evaluate_cases` (accumulated counterexample tests for
  `fitness=:tests`, spec constraints for `fitness=:constraints`).
- `fitness=:tests`     — fitness mode:
  - `:tests` — classic CDGP (`CDGPEvaluator`): failed tests on the accumulated
    counterexample set; Z3 only verifies test-perfect candidates (in-process
    `CexSolver` when the spec allows it, else a z3 subprocess).
  - `:constraints` — constraint-graded (`CDGPConstraintEvaluator`): violated
    spec constraints, each checked per-genome on the warm in-process
    `ConstraintSatSolver`; `0` ⇒ formally verified, no test set.
  - `:hybrid` — both signals (`HybridCDGPEvaluator`): fitness = failed tests +
    failed banked witnesses + unproven constraints; violation witnesses are
    banked as graded cases and (for test-perfect candidates) harvested into
    new tests (`complete_output`); lexicase cases = tests ++ witnesses.
- `witness_cases=true` — (`:hybrid` only) replay every witness Z3 has produced
  pointwise against every genome (`eval_constraint_pointwise`, interpreter
  only), turning each constraint's single ∀-bit into a growing graded battery.
  `false` restores the one-case-per-constraint pool.
- `max_witnesses=6`    — (`:hybrid` only) per-constraint cap on the battery.
- `max_tests=typemax(Int)` — (`:hybrid` only) cap on the harvested test set
  (complete + incomplete). Unlimited, like the test evaluator's; runs stored
  before 2026-09-26 used 64 (arm `hybrid-ratio-cap64` reproduces that).
- `witness_policy=:none` — (`:hybrid` only) battery eviction, applied at round
  boundaries (see `CDGP_WITNESS_PLAN.md`). `:none` keeps the original frozen
  bank: once a constraint hits `max_witnesses` its evidence never changes, so
  late genomes are graded against generation-1 witnesses. `:ratio` holds the
  pool to `witness_test_ratio` witnesses per accumulated test, oldest retired
  first — the policy the instrumentation supports, since the battery was
  measured outgrowing the test set 3:1 to 7.5:1. `:fifo` retires the oldest
  witness of each saturated constraint per round. `:info` drops witnesses whose
  loss column is constant across the population; measured near-inert (one
  constant column in ~40 rounds) and kept only as an ablation.
- `witness_test_ratio=1.0` — (`:hybrid`, `witness_policy=:ratio`) witnesses
  allowed per accumulated test, floored at one per constraint.
- `max_witnesses_total=typemax(Int)` — (`:hybrid` only) hard global cap on the
  battery. The per-constraint cap cannot bound the pool, which scales with
  `n_constraints`.
- `witness_dedupe_inputs=false` — (`:hybrid` only) reject an input already
  banked under any constraint. One input violating three constraints is
  otherwise banked three times and acts as one lexicase case holding three
  tickets in the shuffle.
- `incomplete_tests=true` — (`:tests` and `:hybrid`) when the spec accepts
  several outputs at a counterexample's input, keep the input only and judge
  candidates by whether they satisfy the constraints there, instead of
  demanding the one output Z3 happened to pick (which fails correct programs).
  Costs one Z3 query per run on single-answer specs and changes nothing else
  there; see `incomplete_tests.jl`. `false` is the legacy behaviour, for
  ablation.
- `cex_mode=:single`   — (`:tests` only) `:per_constraint` verifies with one
  universal check per constraint and turns every violated constraint's witness
  into a test (up to `max_new_tests` per verification) instead of one
  counterexample per verification; see `CDGPEvaluator`. Falls back to `:single`
  for specs outside the in-process solvers' scope (recorded in `harvest`).
- `max_new_tests=typemax(Int)` — (`cex_mode=:per_constraint`) cap on tests added
  by one verification.
- `guided=:none`       — (`:tests`, `engine=:ga` only) mutation operator: `:none` is plain
  subtree mutation; `:patch` is `GuidedPatchMutation` — for parents failing some tests,
  SMT localization + a guarded partial repair `ite(g, e, n)` built from the tests
  (RQ1_RQ2_PLAN.md §7.5), falling back to subtree mutation otherwise; `:placebo` does the
  same work but writes a random subtree at the chosen site (control arm).
- `guided_rate=0.3`, `guided_budget=2`, `guided_min_pass=8` — probability a mutation tries
  the guided path; localizations + site builds allowed per generation; tests a parent
  must pass to be eligible. See `GuidedPatchMutation`.
- `guided_sites=:l3`, `guided_candidates=6`, `guided_extra=3`, `guided_max_pass=typemax(Int)`,
  `guided_keep_cache=false` — the v2 speed-ups (RQ1_RQ2_PLAN.md §7.10; defaults = v1):
  `:l3_sampled` localizes over the root plus `guided_candidates - 1` random active nodes;
  `guided_extra` is the term-pool depth; `guided_max_pass` caps the passing tests a build uses
  (the drawn patch is then validated on all of them); `guided_keep_cache` keeps a program's
  analysis when the test set grows. `guided_shapes=:spec` (v3) adds spec-derived answer
  patches `ite(G_t, t, ·)` at the root (see `constraint_patches.jl`). Ablation: `guided_sites=:none`
  disables localization and site patches; `guided_fallback=:keep` returns the parent instead of a
  subtree mutation.
- `tests_ratio=1.0`    — fitness threshold *q* (Błądek et al., EC 2018): a
  candidate is sent to Z3 once it passes at least this ratio of the accumulated
  tests, instead of only when test-perfect. `1.0` is the conservative variant
  (unchanged behaviour); `0.75` was the paper's best, eliciting counterexamples
  earlier rather than stalling until every accumulated test is passed at once.
  For `:hybrid` it gates the per-constraint Z3 spend over tests + banked
  witnesses (`gate_constraints` must stay on); ignored for `:constraints`.
- `parsimony=true`     — append program size as one extra lexicase case
  (`:tests` and `:hybrid`), restoring gentle size pressure now that complexity
  is not a Pareto objective. Without it lexicase has *no* bloat control at all,
  since a bloated specialist wins its cases as well as a compact one: on the
  official SyGuS `max4`, `fitness=:tests` + lexicase scored 1/10 with 119-node
  programs before this applied to the test evaluator.
- `gate_constraints=true` — (`:hybrid` only) run per-constraint Z3 checks only
  for candidates clean on all cheap evidence (every test and every banked
  witness). Cures Z3-cost generation starvation; pass `false` for the
  check-every-genome behavior.
- `engine=:ga`         — `:ga` (GeneticProgramming + `selection`) or `:nsga2`
  (Pareto selection over `[failed_tests, constraint_violations]`; program size
  is only a best-extraction tie-break; requires `fitness=:hybrid`; `selection`
  is ignored, `pop_size` rounded even).
- `normalize=false`    — reduce every sampled/mutated/crossed genome to its
  semantic normal form before it enters the population (`normalize_program`):
  deletes `x*0`, `a+0`, `ifelse(p,a,a)`, reflexive comparisons and folds
  constants, mirrors `a>b` to `b<a`, and sorts commutative operands. Prevents
  meaningless candidates at birth instead of selecting against them, and
  collapses the evaluators' caches onto one representative per semantics.
  Off by default because it also removes GP introns (neutral subtrees that
  buffer destructive crossover) — an A/B, not a free win.
- `minimize=false`     — when solved, greedily shrink the program while it
  still formally verifies (`minimize_program` on the warm solver) before
  returning it.
- `z3_timeout_ms=nothing` — per-check Z3 timeout for the in-process solvers;
  `nothing` ⇒ mode default (`5_000` for `:tests`, `100` for `:constraints`).
  Guards `max_time` (which is only checked between rounds) against nonlinear
  candidates that can stall a single Z3 check for minutes.
- `seed_programs=:none` — (`engine=:ga` only; E4) put `seed_fraction` of the first population as programs built
  from the spec's recipes and region guards: `:guard`, `:partial`, `:full` or the `:inert` placebo (see
  `seed_programs.jl`). Random leaves at most `seed_leaf_depth` deep, the tail at most `max_depth`. Drawn from their
  own RNG; the rest of the population is the unseeded run's. Recorded in `completion` (`programs_seeded`,
  `seed_size_mean`, `seed_guards_kept`: knowledge guards found verbatim in the returned program).
- `seed=1`, `verbose=true`
- `start_symbol=:Expr`
- `grammar=nothing`    — search space; `nothing` ⇒ synthesize one from the spec
  signature (`build_grammar_from_spec`). Pass the benchmark's *own* grammar
  (`build_grammar_from_sygus`) for results comparable to published SyGuS/CDGP
  numbers — the synthesized grammar is strictly larger (adds `*`, extra
  constants, and a Bool→Int coercion) and solves a different problem.
- `max_time=Inf`       — wall-clock budget in seconds (checked between rounds)
- `trace=nothing`      — pass a `CDGPTrace()` to record one entry per generation
  (best/mean fitness, best size, evidence counts, cumulative Z3 calls by kind),
  per-round population stats, the distinct best genomes, and the generation at
  which a verified program first existed. Observation only: it does not change
  the search. Score the recorded genomes afterwards with `ValidationBattery` /
  `trace_validation` for a fitness scale that does not move as evidence grows.
"""
function run_cdgp(spec_path::String;
                  pop_size::Int=100,
                  generations::Int=200,
                  generations_per_round::Int=10,
                  elitism::Int=2,
                  max_depth::Int=4,
                  subtree_depth::Int=3,
                  depth_cap::Int=6,
                  mutation_rate::Float64=0.6,
                  crossover_rate::Float64=0.3,
                  tournament_size::Int=3,
                  bloat_penalty::Float64=1e-3,
                  selection::Union{Arborist.AbstractSelectionStrategy,Nothing}=nothing,
                  fitness::Symbol=:tests,
                  engine::Symbol=:ga,
                  gate_constraints::Bool=true,
                  witness_cases::Bool=true,
                  max_witnesses::Int=6,
                  max_tests::Int=typemax(Int),
                  witness_policy::Symbol=:none,
                  max_witnesses_total::Int=typemax(Int),
                  witness_dedupe_inputs::Bool=false,
                  witness_test_ratio::Float64=1.0,
                  incomplete_tests::Bool=true,
                  cex_mode::Symbol=:single,
                  max_new_tests::Int=typemax(Int),
                  guided::Symbol=:none,
                  guided_rate::Float64=0.3,
                  guided_budget::Int=2,
                  guided_min_pass::Int=8,
                  guided_sites::Symbol=:l3,
                  guided_candidates::Int=6,
                  guided_extra::Int=3,
                  guided_max_pass::Int=typemax(Int),
                  guided_keep_cache::Bool=false,
                  guided_shapes::Symbol=:none,
                  guided_fallback::Symbol=:subtree,
                  parsimony::Bool=true,
                  tests_ratio::Float64=1.0,
                  normalize::Bool=false,
                  minimize::Bool=false,
                  z3_timeout_ms::Union{Integer,Nothing}=nothing,
                  seed::Int=1,
                  seed_tests::Symbol=:none,
                  seed_tests_range::Int=10,
                  seed_programs::Symbol=:none,
                  seed_fraction::Float64=0.1,
                  seed_leaf_depth::Int=3,
                  verbose::Bool=true,
                  start_symbol::Symbol=:Expr,
                  grammar::Union{AbstractGrammar,Nothing}=nothing,
                  max_time::Float64=Inf,
                  trace::Union{CDGPTrace,Nothing}=nothing)::CDGPResult

    fitness in (:tests, :constraints, :hybrid) ||
        throw(ArgumentError("run_cdgp: fitness must be :tests, :constraints or :hybrid, got :$fitness"))
    engine in (:ga, :nsga2) ||
        throw(ArgumentError("run_cdgp: engine must be :ga or :nsga2, got :$engine"))
    0.0 < tests_ratio <= 1.0 ||
        throw(ArgumentError("run_cdgp: tests_ratio (q) must be in (0, 1], got $tests_ratio"))
    cex_mode === :single || fitness === :tests ||
        throw(ArgumentError("run_cdgp: cex_mode=:$cex_mode applies to fitness=:tests only"))
    guided in (:none, :patch, :placebo) ||
        throw(ArgumentError("run_cdgp: guided must be :none, :patch or :placebo, got :$guided"))
    guided === :none || (fitness === :tests && engine === :ga) ||
        throw(ArgumentError("run_cdgp: guided=:$guided needs fitness=:tests and engine=:ga"))
    seed_tests in (:none, :regions, :regions_inner, :random) ||
        throw(ArgumentError("run_cdgp: seed_tests must be :none, :regions, :regions_inner or :random, got :$seed_tests"))
    seed_tests === :none || fitness === :tests ||
        throw(ArgumentError("run_cdgp: seed_tests needs fitness=:tests"))
    seed_programs in (:none, :guard, :partial, :full, :inert) ||
        throw(ArgumentError("run_cdgp: seed_programs must be :none, :guard, :partial, :full or :inert, got :$seed_programs"))
    seed_programs === :none || engine === :ga ||
        throw(ArgumentError("run_cdgp: seed_programs needs engine=:ga"))
    0.0 < seed_fraction <= 1.0 ||
        throw(ArgumentError("run_cdgp: seed_fraction must be in (0, 1], got $seed_fraction"))
    engine === :nsga2 && fitness !== :hybrid &&
        throw(ArgumentError("run_cdgp: engine=:nsga2 requires fitness=:hybrid " *
                            "(multi-objective evaluation lives on HybridCDGPEvaluator)"))

    Random.seed!(seed)  # make rand(RuleNode, …) reproducible

    spec = CEXGeneration.parse_spec_from_file(spec_path)
    grammar = grammar === nothing ?
        build_grammar_from_spec(spec_path; start_symbol=start_symbol) : grammar
    evaluator = fitness === :tests ?
        CDGPEvaluator(spec, grammar, start_symbol, max_depth;
                      z3_timeout_ms=something(z3_timeout_ms, 5_000),
                      parsimony=parsimony, tests_ratio=tests_ratio,
                      incomplete_tests=incomplete_tests,
                      cex_mode=cex_mode, max_new_tests=max_new_tests) :
        fitness === :constraints ?
        CDGPConstraintEvaluator(spec, grammar, start_symbol, max_depth;
                                z3_timeout_ms=something(z3_timeout_ms, 100)) :
        HybridCDGPEvaluator(spec, grammar, start_symbol, max_depth;
                            z3_timeout_ms=something(z3_timeout_ms, 100),
                            gate_constraints=gate_constraints,
                            witness_cases=witness_cases,
                            max_witnesses=max_witnesses,
                            max_tests=max_tests,
                            witness_policy=witness_policy,
                            max_witnesses_total=max_witnesses_total,
                            witness_dedupe_inputs=witness_dedupe_inputs,
                            witness_test_ratio=witness_test_ratio,
                            incomplete_tests=incomplete_tests,
                            parsimony=parsimony, tests_ratio=tests_ratio)

    # E3: starting tests before generation 0. :regions = one point per satisfiable premise of the spec's
    # implications; :random = the same number of uniform random inputs (own RNG, so the GA's stream is untouched).
    # E3b: :regions_inner = one point per premise drawn uniformly from inside it (own RNG), not z3's boundary model.
    if seed_tests !== :none
        pts = seed_tests === :regions_inner ?
            spec_region_inner_points(spec, Random.MersenneTwister(7919 * seed + 29);
                                     lo = -seed_tests_range, hi = seed_tests_range).points :
            spec_region_points(spec)
        if seed_tests === :random
            pts = random_points(spec, length(pts), Random.MersenneTwister(7919 * seed + 17);
                                lo = -seed_tests_range, hi = seed_tests_range)
        end
        nseed = _cdgp_seed_tests!(evaluator, pts)
        verbose && println("  seeded $nseed starting tests (:$seed_tests, $(length(pts)) points)")
    end

    # E4: spec knowledge as programs of the first population (seed_programs.jl); own RNG, global stream restored.
    seeds = seed_programs === :none ? RuleNode[] :
        spec_seed_programs(spec, grammar, start_symbol, seed_programs, max(1, round(Int, seed_fraction * pop_size));
                           depth_cap = depth_cap, rng_seed = 7919 * seed + 53, leaf_depth = seed_leaf_depth,
                           tail_depth = max_depth)
    isempty(seeds) || (verbose && println("  seeded $(length(seeds)) programs (:$seed_programs)"))

    # One mutation operator: Arborist samples `mutation_ops` uniformly, so the guided
    # operator dispatches internally (and falls back to subtree mutation itself).
    gop = guided === :none ? nothing :
        GuidedPatchMutation(grammar, subtree_depth, depth_cap, evaluator;
                            rate=guided_rate, budget=guided_budget, min_pass=guided_min_pass,
                            placebo=guided === :placebo, normalize=normalize,
                            sites=guided_sites, candidates=guided_candidates, extra=guided_extra,
                            max_pass=guided_max_pass, keep_cache=guided_keep_cache,
                            shapes=guided_shapes, fallback=guided_fallback)
    mutation_ops = Arborist.AbstractMutationOperator[
        gop === nothing ? GrammarSubtreeMutation(grammar, subtree_depth, depth_cap; normalize=normalize) : gop,
    ]
    crossover_ops = Arborist.AbstractCrossoverOperator[
        GrammarSubtreeCrossover(grammar, depth_cap; normalize=normalize),
    ]
    # Sampled genomes go through the module-level hook (see state_and_init.jl).
    _INIT_NORMALIZE[] = normalize ? GrammarOps(grammar) : nothing

    algorithm = if engine === :nsga2
        Arborist.NSGAII(
            pop_size=iseven(pop_size) ? pop_size : pop_size + 1,
            generations=generations_per_round,
            mutation_rate=mutation_rate,
            crossover_rate=crossover_rate,
            mutation_ops=mutation_ops,
            crossover_ops=crossover_ops,
            parallel=false,  # the evaluator mutates shared state (test set, caches)
        )
    else
        sel = selection === nothing ? Arborist.TournamentSelection(tournament_size) : selection
        Arborist.GeneticProgramming(
            pop_size=pop_size,
            generations=generations_per_round,
            elitism=elitism,
            mutation_rate=mutation_rate,
            crossover_rate=crossover_rate,
            bloat_penalty=bloat_penalty,
            selection=sel,
            mutation_ops=mutation_ops,
            crossover_ops=crossover_ops,
            parallel=false,  # the evaluator mutates shared state (test set, cache)
        )
    end

    _INIT_SEEDS[] = seeds        # consumed by the first round's population init (state_and_init.jl)
    t0 = time()
    trace === nothing || _trace_begin!(trace, t0)
    population = nothing
    result = nothing
    gens_done = 0
    rounds = 0

    while gens_done < generations && evaluator.solved === nothing &&
          time() - t0 < max_time
        rounds += 1
        # Distinct seed per round — reusing one seed would replay the identical
        # internal RNG stream on every solve call.
        problem = Arborist.GPProblem(evaluator, RuleNodeGenome; seed=seed + rounds)
        first_idx = trace === nothing ? 0 : length(trace) + 1
        trace_cb = trace === nothing ? nothing :
                   _trace_callback(trace, evaluator, rounds, gens_done, engine)
        # The callback fires at the start of each generation, right after that
        # generation's population was evaluated — the evaluation in which a
        # verified program is found. Stopping there ends the run at the solving
        # generation. (A solve among the offspring of a round's LAST generation
        # has no callback after it; that round ends normally a moment later.)
        gen_seen = Ref(0)
        cb = function (gen, a, b)
            gen_seen[] = gen
            gop === nothing || guided_new_generation!(gop)
            trace_cb === nothing || trace_cb(gen, a, b)
            evaluator.solved === nothing || throw(_CDGPSolved())
            return nothing
        end
        round_result = try
            Arborist.solve(problem, algorithm; verbose=false,
                           initial_population=population, callback=cb)
        catch err
            err isa _CDGPSolved || rethrow()
            nothing
        end
        if round_result === nothing
            # Stopped mid-round: no GPResult for this round. `result` keeps the
            # last completed round's, which the solved path below does not need.
            gens_done += gen_seen[]
            trace === nothing || _trace_round_stopped!(trace)
            verbose && println("  [round $rounds] VERIFIED solution at generation $gens_done: " *
                               Arborist.serialize(evaluator.solved))
            break
        end
        result = round_result
        population = result.population
        trace === nothing || _trace_round_end!(trace, result, first_idx, evaluator)
        gens_done += generations_per_round

        # Witness-battery eviction runs *here* and nowhere else: between rounds
        # the case matrix is not being read, so changing the bank's length is
        # safe. Firing it mid-pass would hand lexicase a ragged matrix.
        nevicted = evaluator isa HybridCDGPEvaluator ?
                   hybrid_evict_witnesses!(evaluator, rounds) : 0

        if verbose
            if evaluator.solved !== nothing
                println("  [round $rounds] VERIFIED solution: $(Arborist.serialize(evaluator.solved))")
            else
                (bg, bf) = _cdgp_best(result)
                println("  [round $rounds] gens=$gens_done $(_cdgp_progress(evaluator)) " *
                        (nevicted > 0 ? "evicted=$nevicted " : "") *
                        "best=$(round(bf, digits=4)) : " *
                        (bg === nothing ? "-" : Arborist.serialize(bg)))
            end
        end
    end

    _INIT_SEEDS[] = RuleNode[]   # in case no round ran
    solved = evaluator.solved !== nothing
    (rbest, rfit) = result === nothing ? (nothing, Inf) : _cdgp_best(result)
    # A verified program scores 0 on every evaluator (no failed test, witness or
    # unproven constraint), so its Arborist fitness is the bloat term alone.
    # Computed directly: a run that stopped mid-round has no final-round result.
    solved && (rfit = bloat_penalty * Arborist.complexity(evaluator.solved))
    best = solved ? evaluator.solved : rbest

    if minimize && solved && best !== nothing
        shrunk = minimize_program(best.tree, grammar, _minimize_verifier(evaluator))
        if verbose && length(shrunk) < length(best.tree)
            println("  minimized: $(length(best.tree)) → $(length(shrunk)) nodes")
        end
        best = RuleNodeGenome(shrunk, grammar, start_symbol)
    end

    completion = _cdgp_completion(evaluator)
    isempty(seeds) || (completion = merge(completion, (
        programs_seeded = length(seeds),
        seed_size_mean = round(sum(length, seeds) / length(seeds); digits = 1),
        seed_guards_kept = best === nothing ? 0 : seed_guards_kept(best.tree, spec, grammar, seed_programs))))

    return CDGPResult(
        solved,
        best,
        best === nothing ? "" : string(rulenode2expr(best.tree, grammar)),
        rfit,
        gens_done,
        rounds,
        _cdgp_tests(evaluator),
        _cdgp_counterexamples(evaluator),
        _cdgp_z3_calls(evaluator),
        _cdgp_witnesses(evaluator),
        _cdgp_incomplete(evaluator),
        completion,
        _cdgp_harvest(evaluator),
        guided_stats(gop),
    )
end
