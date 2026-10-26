"""
    state_and_init.jl

Population initialization for the `RuleNodeGenome`. Arborist's `solve` calls
`_initialize_population(problem, algorithm, rng)` and then hands the result to
`_run_evolution!`, whose signature requires the carrier to be a `GenState`. We
don't use `GenState` for RuleNode sampling, so we build a minimal one purely to
satisfy that type; random trees come from Herb's `rand(RuleNode, …)` sampler.
"""

"""
Normalization hook for freshly *sampled* genomes.

Arborist's init entry points receive only `(problem, algorithm, rng)`, so there
is no argument through which `run_cdgp` can pass its `normalize` setting down to
the sampler. This module-level switch carries it. It is set by `run_cdgp`
immediately before `solve` and is safe because the GA runs `parallel=false`
(the evaluators mutate shared state, so it could not be threaded anyway).

`nothing` ⇒ sample as-is; a `GrammarOps` ⇒ normalize every sampled tree.
"""
const _INIT_NORMALIZE = Ref{Union{GrammarOps,Nothing}}(nothing)

"""
E4 seeds for the first population (`run_cdgp(...; seed_programs)`, seed_programs.jl). `_initialize_population`
samples the population as usual, puts these trees in its first slots and empties the hook, so only a run's first
round is seeded and the sampled genomes are those of the unseeded run. Set by `run_cdgp` just before its first
`solve`; safe for the same reason as `_INIT_NORMALIZE`.
"""
const _INIT_SEEDS = Ref{Vector{RuleNode}}(RuleNode[])

_sample_tree(ev) = begin
    t = rand(RuleNode, ev.grammar, ev.start_symbol, ev.max_depth)
    ops = _INIT_NORMALIZE[]
    ops === nothing ? t : normalize_program(t, ev.grammar, ops)
end

"""
    _initialize_population(problem::GPProblem{RuleNodeGenome,E}, algorithm, rng)

Sample `pop_size` random grammar-valid trees of the start symbol. Returns
`(genomes, state::GenState)` as required by `_run_evolution!`.

Note: `rand(RuleNode, grammar, sym, depth)` draws from Julia's global RNG, not
`rng`; `run_ga_cegis` seeds the global RNG for reproducibility.
"""
function Arborist._initialize_population(problem::Arborist.GPProblem{RuleNodeGenome,E},
                                         algorithm::Arborist.GeneticProgramming,
                                         rng::AbstractRNG) where {E}
    ev = problem.evaluator
    grammar = ev.grammar
    start_symbol = ev.start_symbol
    max_depth = ev.max_depth

    genomes = Vector{RuleNodeGenome}(undef, algorithm.pop_size)
    for i in 1:algorithm.pop_size
        genomes[i] = RuleNodeGenome(_sample_tree(ev), grammar, start_symbol)
    end
    seeds = _INIT_SEEDS[]
    _INIT_SEEDS[] = RuleNode[]
    for (i, s) in enumerate(seeds)
        i <= length(genomes) && (genomes[i] = RuleNodeGenome(s, grammar, start_symbol))
    end

    # Minimal GenState carrier (unused by the basic evolution loop, but required
    # by the `_run_evolution!(::Tuple{Vector{G}, GenState}, …)` signature).
    state = Arborist.GenState(rng, problem.function_set,
                              Arborist.input_signature(ev),
                              Arborist.output_signature(ev),
                              problem.num_temps)
    return (genomes, state)
end

"""
    _nsga2_init_population(problem::GPProblem{RuleNodeGenome,E}, algorithm::NSGAII, rng)

NSGA-II population init for `RuleNodeGenome` (the NSGA-II solve path carries no
GenState, so this returns the genome vector only). Same sampler as the GA path.
"""
function Arborist._nsga2_init_population(problem::Arborist.GPProblem{RuleNodeGenome,E},
                                         algorithm::Arborist.NSGAII,
                                         rng::AbstractRNG) where {E<:Arborist.AbstractMultiObjectiveEvaluator}
    ev = problem.evaluator
    return [RuleNodeGenome(_sample_tree(ev), ev.grammar, ev.start_symbol)
            for _ in 1:algorithm.pop_size]
end
