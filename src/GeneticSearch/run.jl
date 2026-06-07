"""
    run.jl

`run_ga_cegis` — wires the Z3-graded evaluator and grammar-aware operators into
Arborist's GA engine and runs it on a SyGuS spec. Spec- and grammar-driven, so
it works on any benchmark, not just max2.
"""

"""
    GAResult

Outcome of a `run_ga_cegis` run.

- `solved`            — was a fully-verified program found (0 constraints violated)?
- `program`           — the best `RuleNodeGenome`.
- `expr`              — its Julia-expression string.
- `num_violated`      — constraints the best program violates (0 ⇒ correct).
- `best_fitness`      — Arborist fitness of the best (violations + bloat term).
- `generations`       — generations run.
- `targeted_hits` / `fallback_hits` — how often targeted mutation used the Z3
                        witness vs. fell back to uniform mutation.
- `z3_calls`          — distinct programs verified (cache size; each = n_constraints Z3 calls).
"""
struct GAResult
    solved::Bool
    program::RuleNodeGenome
    expr::String
    num_violated::Int
    best_fitness::Float64
    generations::Int
    targeted_hits::Int
    fallback_hits::Int
    z3_calls::Int
end

"""
    run_ga_cegis(spec_path; kwargs...) -> GAResult

Run Z3-guided genetic synthesis on the SyGuS spec at `spec_path`.

Keyword arguments:
- `pop_size=40`, `generations=40`, `elitism=2`
- `max_depth=4`        — depth of randomly initialized programs
- `subtree_depth=3`    — depth of subtrees introduced by mutation
- `depth_cap=6`        — offspring deeper than this are rejected (keeps Z3 fast)
- `mutation_rate=0.6`, `crossover_rate=0.3`, `tournament_size=3`, `bloat_penalty=1e-3`
- `targeted=true`      — use counterexample-targeted mutation (vs. uniform baseline)
- `seed=1`, `verbose=true`
- `start_symbol=:Expr`
"""
function run_ga_cegis(spec_path::String;
                      pop_size::Int=40,
                      generations::Int=40,
                      elitism::Int=2,
                      max_depth::Int=4,
                      subtree_depth::Int=3,
                      depth_cap::Int=6,
                      mutation_rate::Float64=0.6,
                      crossover_rate::Float64=0.3,
                      tournament_size::Int=3,
                      bloat_penalty::Float64=1e-3,
                      targeted::Bool=true,
                      seed::Int=1,
                      verbose::Bool=true,
                      start_symbol::Symbol=:Expr)::GAResult

    Random.seed!(seed)  # make rand(RuleNode, …) reproducible

    spec = CEXGeneration.parse_spec_from_file(spec_path)
    grammar = build_grammar_from_spec(spec_path; start_symbol=start_symbol)
    symboltable = grammar2symboltable(grammar, Main)

    evaluator = Z3GradedEvaluator(spec, grammar, start_symbol, max_depth)

    targeted_op = CounterexampleTargetedMutation(grammar, subtree_depth, depth_cap,
                                                 evaluator.blackboard, symboltable)
    subtree_op = GrammarSubtreeMutation(grammar, subtree_depth, depth_cap)
    xover = GrammarSubtreeCrossover(grammar, depth_cap)

    mutation_ops = Arborist.AbstractMutationOperator[
        targeted ? targeted_op : subtree_op,
        subtree_op,
    ]

    problem = Arborist.GPProblem(evaluator, RuleNodeGenome; seed=seed)
    algorithm = Arborist.GeneticProgramming(
        pop_size=pop_size,
        generations=generations,
        elitism=elitism,
        mutation_rate=mutation_rate,
        crossover_rate=crossover_rate,
        bloat_penalty=bloat_penalty,
        selection=Arborist.TournamentSelection(tournament_size),
        mutation_ops=mutation_ops,
        crossover_ops=Arborist.AbstractCrossoverOperator[xover],
        parallel=false,  # Z3 shells out per call; keep serial for determinism
    )

    solved_gen = Ref(0)
    callback = function (gen, best_fitness, best_genome)
        if solved_gen[] == 0 && best_fitness < 1.0
            solved_gen[] = gen
            verbose && println("  [gen $gen] VERIFIED solution: $(Arborist.serialize(best_genome))")
        elseif verbose && gen % 5 == 0
            println("  [gen $gen] best fitness = $(round(best_fitness, digits=4)) : $(Arborist.serialize(best_genome))")
        end
    end

    result = Arborist.solve(problem, algorithm; verbose=false, callback=callback)

    best = result.best_genome
    key = Arborist.serialize(best)
    diag = get(evaluator.blackboard, key, nothing)
    nviol = diag === nothing ? evaluator.n_constraints : diag.num_violated

    return GAResult(
        nviol == 0,
        best,
        string(rulenode2expr(best.tree, grammar)),
        nviol,
        result.best_fitness,
        generations,
        targeted_op.targeted_hits[],
        targeted_op.fallback_hits[],
        length(evaluator.cache),
    )
end
