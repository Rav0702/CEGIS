"""
`RecipeIterator` / `run_recipe_cegis` (src/recipe_iterator.jl): the non-GP reference that runs
CEGIS over the spec's answer recipes. Solves covered specs directly (single- and multi-answer),
works through the classic CEGIS loop via `notify_counterexample!`, and stops cleanly when the spec
yields no recipes or is out of scope.
"""

@testset "RecipeIterator and run_recipe_cegis" begin
    GS = CEGIS.GeneticSearch
    CG = CEGIS.CEXGeneration
    root = joinpath(@__DIR__, "..", "spec_files")
    gram(p, spec) = spec.synth_funs[1].grammar !== nothing ?
        CEGIS.GrammarBuilding.build_grammar_from_sygus(spec) : CEGIS.build_grammar_from_spec(p)

    # Covered specs: solved, verified independently, one case per counterexample.
    for (rel, max_programs) in (("phase3_benchmarks/max6_simple.sl", 6), ("multi_answer/above4.sl", 4),
                                ("case_split/array_search4.sl", 5), ("case_split/countpos4_split.sl", 16))
        p = joinpath(root, rel)
        spec = CG.parse_spec_from_file(p)
        g = gram(p, spec)
        tr = GS.CDGPTrace()
        r = CEGIS.run_recipe_cegis(p; grammar = g, max_time = 60.0, trace = tr, pop_size = 400)  # GA kwargs ignored
        @test r.solved
        @test r.generations <= max_programs
        @test r.guided.mode === :recipes && r.guided.applied == r.generations - 1
        @test length(tr) == r.generations && tr.solve_gen == r.generations
        smt = CG.rulenode_to_smt2(r.program.tree, g)
        @test CG.verify_query(CG.generate_cex_query(spec, Dict(spec.synth_funs[1].name => smt))).status == :unsat
    end

    # No recipes (functional spec whose answer contains ite) and out of scope (f(x,y) = f(y,x)).
    for rel in ("paired/ours/countpos3.sl", "phase3_benchmarks/symmetric_max.sl")
        p = joinpath(root, rel)
        r = CEGIS.run_recipe_cegis(p; grammar = gram(p, CG.parse_spec_from_file(p)), max_time = 30.0)
        @test !r.solved && r.generations == 1
    end

    # Iterator protocol: first program, then one case per notified counterexample, nothing otherwise.
    p = joinpath(root, "phase3_benchmarks", "max6_simple.sl")
    spec = CG.parse_spec_from_file(p)
    g = CEGIS.build_grammar_from_spec(p)
    it = CEGIS.RecipeIterator(spec, g)
    @test HerbSearch.get_grammar(it) === g
    first_prog, st = iterate(it)
    @test first_prog isa RuleNode
    @test iterate(it, st) === nothing                   # no counterexample yet: nothing new
    it2 = CEGIS.RecipeIterator(spec, g)
    iterate(it2)
    x = Dict{Symbol,Any}(:x0 => 0, :x1 => 0, :x2 => 0, :x3 => 9, :x4 => 0, :x5 => 0)
    CEGIS.notify_counterexample!(it2, CEGIS.Counterexample(x, 9, nothing))
    nxt, _ = iterate(it2, nothing)
    st2 = grammar2symboltable(g, Main)
    @test execute_on_input(st2, rulenode2expr(nxt, g), x) == 9 && it2.cases == 1

    # Through the classic CEGIS loop (single-answer spec).
    it3 = CEGIS.RecipeIterator(spec, g)
    res = redirect_stdout(devnull) do
        CEGIS.run_synthesis(CEGIS.CEGISProblem(p), it3; max_time = 60.0)
    end
    @test res.status == CEGIS.cegis_success
end

@testset "GA ablation: recipes as the only variation" begin
    GS = CEGIS.GeneticSearch
    CG = CEGIS.CEXGeneration
    p = joinpath(@__DIR__, "..", "spec_files", "phase3_benchmarks", "max6_simple.sl")
    spec = CG.parse_spec_from_file(p)
    g = CEGIS.build_grammar_from_spec(p)
    e = GS.CDGPEvaluator(spec, g, :Expr, 4)
    # A parent that fails nothing yet is ineligible: with fallback=:keep it comes back unchanged.
    op = GS.GuidedPatchMutation(g, 3, 14, e; rate = 1.0, budget = 100, min_pass = 1, sites = :none,
                                shapes = :spec, fallback = :keep)
    parent = GS.RuleNodeGenome(RuleNode(findfirst(==(:x0), g.rules)), g, :Expr)
    @test Arborist.mutate(op, parent, Random.MersenneTwister(1)) === parent
    @test_throws ArgumentError GS.GuidedPatchMutation(g, 3, 14, e; fallback = :bogus)
    # run_cdgp wiring: no crossover, no subtree mutation, no localization — only answer patches.
    res = GS.run_cdgp(p; grammar = g, selection = Arborist.LexicaseSelection(), pop_size = 200,
                      generations = 60, max_depth = 6, depth_cap = 14, seed = 3, verbose = false,
                      crossover_rate = 0.0, mutation_rate = 1.0, guided = :patch, guided_rate = 1.0,
                      guided_budget = 8, guided_min_pass = 1, guided_sites = :none, guided_keep_cache = true,
                      guided_shapes = :spec, guided_fallback = :keep)
    @test res.guided.applied == res.guided.shape_applied        # every written child is an answer patch
    @test res.guided.site_builds == 0 && res.guided.t_localize == 0.0
end
