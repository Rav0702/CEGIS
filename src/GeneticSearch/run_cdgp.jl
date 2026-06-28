"""
    run_cdgp.jl

`run_cdgp` — wires the `CDGPEvaluator` and grammar-aware operators into
Arborist's GA engine. Arborist's `solve` has no early-stop hook, so evolution
runs in rounds of `generations_per_round` generations, warm-starting each round
from the previous round's final population; the loop stops as soon as the
evaluator records a formally verified solution. The fresh evaluation at each
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
- `best_fitness`     — Arborist fitness of the final round's best (failed tests + bloat term).
- `generations`      — total generations run across all rounds.
- `rounds`           — number of `solve` rounds run.
- `test_cases`       — the accumulated counterexample-derived test set.
- `counterexamples`  — the counterexamples in discovery order.
- `verifications`    — Z3 counterexample queries issued (one per distinct test-perfect program).
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
  `Arborist.LexicaseSelection()` for lexicase (each accumulated counterexample
  test becomes a separate selection case via `evaluate_cases`).
- `seed=1`, `verbose=true`
- `start_symbol=:Expr`
- `max_time=Inf`       — wall-clock budget in seconds (checked between rounds)
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
                  seed::Int=1,
                  verbose::Bool=true,
                  start_symbol::Symbol=:Expr,
                  max_time::Float64=Inf)::CDGPResult

    Random.seed!(seed)  # make rand(RuleNode, …) reproducible

    spec = CEXGeneration.parse_spec_from_file(spec_path)
    grammar = build_grammar_from_spec(spec_path; start_symbol=start_symbol)
    evaluator = CDGPEvaluator(spec, grammar, start_symbol, max_depth)

    sel = selection === nothing ? Arborist.TournamentSelection(tournament_size) : selection

    algorithm = Arborist.GeneticProgramming(
        pop_size=pop_size,
        generations=generations_per_round,
        elitism=elitism,
        mutation_rate=mutation_rate,
        crossover_rate=crossover_rate,
        bloat_penalty=bloat_penalty,
        selection=sel,
        mutation_ops=Arborist.AbstractMutationOperator[
            GrammarSubtreeMutation(grammar, subtree_depth, depth_cap),
        ],
        crossover_ops=Arborist.AbstractCrossoverOperator[
            GrammarSubtreeCrossover(grammar, depth_cap),
        ],
        parallel=false,  # the evaluator mutates shared state (test set, cache)
    )

    t0 = time()
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
        result = Arborist.solve(problem, algorithm; verbose=false,
                                initial_population=population)
        population = result.population
        gens_done += generations_per_round

        if verbose
            if evaluator.solved !== nothing
                println("  [round $rounds] VERIFIED solution: $(Arborist.serialize(evaluator.solved))")
            else
                println("  [round $rounds] gens=$gens_done tests=$(length(evaluator.test_cases)) " *
                        "z3_calls=$(evaluator.verifications) " *
                        "best=$(round(result.best_fitness, digits=4)) : " *
                        "$(Arborist.serialize(result.best_genome))")
            end
        end
    end

    solved = evaluator.solved !== nothing
    best = solved ? evaluator.solved :
           result === nothing ? nothing : result.best_genome

    return CDGPResult(
        solved,
        best,
        best === nothing ? "" : string(rulenode2expr(best.tree, grammar)),
        result === nothing ? Inf : result.best_fitness,
        gens_done,
        rounds,
        evaluator.test_cases,
        evaluator.counterexamples,
        evaluator.verifications,
    )
end
