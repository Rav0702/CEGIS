"""
    state_and_init.jl

Population initialization for the `RuleNodeGenome`. Arborist's `solve` calls
`_initialize_population(problem, algorithm, rng)` and then hands the result to
`_run_evolution!`, whose signature requires the carrier to be a `GenState`. We
don't use `GenState` for RuleNode sampling, so we build a minimal one purely to
satisfy that type; random trees come from Herb's `rand(RuleNode, …)` sampler.
"""

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
        tree = rand(RuleNode, grammar, start_symbol, max_depth)
        genomes[i] = RuleNodeGenome(tree, grammar, start_symbol)
    end

    # Minimal GenState carrier (unused by the basic evolution loop, but required
    # by the `_run_evolution!(::Tuple{Vector{G}, GenState}, …)` signature).
    state = Arborist.GenState(rng, problem.function_set,
                              Arborist.input_signature(ev),
                              Arborist.output_signature(ev),
                              problem.num_temps)
    return (genomes, state)
end
