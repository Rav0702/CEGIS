"""
Guarded patches (`GeneticSearch.site_patches` / `guarded_patch`, RQ1_RQ2_PLAN.md §7.3a):
a patch `ite(g, e, n)` must fix the failing inputs it claims to cover and must never break
a passing one; the unguarded `n := e` may. Checked with the interpreter on the
`array_search4` SyGuS grammar, with a hand-written target `max(x1, k)`.
"""

@testset "guarded patch construction" begin
    CG = CEGIS.CEXGeneration
    GS = CEGIS.GeneticSearch
    spec = CG.parse_spec_from_file(joinpath(@__DIR__, "..", "spec_files", "case_split", "array_search4.sl"))
    g = CEGIS.GrammarBuilding.build_grammar_from_sygus(spec)
    st = grammar2symboltable(g, Main)
    kit = GS.PatchKit(g)
    @test all(>(0), (kit.le, kit.ite, kit.andr, kit.notr))

    r(e) = findfirst(==(e), g.rules)
    inp(x1, k) = Dict{Symbol,Any}(:x1 => x1, :x2 => 0, :x3 => 0, :x4 => 0, :k => k)
    target(x) = max(x[:x1], x[:k])
    item(x) = (x, out -> out == target(x))
    run(t, x) = execute_on_input(st, rulenode2expr(t, g), x)

    tree = RuleNode(r(:x1))                                   # right when x1 >= k
    fail = Any[item(inp(0, 3)), item(inp(-2, 4))]
    pass = Any[item(inp(5, 1)), item(inp(2, 2))]

    pats = GS.site_patches(kit, tree, Int[], fail, pass)
    @test !isempty(pats)
    @test pats[1][3] == 2                                     # best patch covers both failing inputs
    for (gd, e, cov) in pats
        child = GS.guarded_patch(tree, Int[], kit, gd, e)
        @test all(it -> it[2](run(child, it[1])), pass)       # never breaks a passing input
        @test count(it -> it[2](run(child, it[1])), fail) >= cov
    end
    # some patch is max(x1, k) everywhere (e.g. ite(x1 <= k, k, x1)); `k` unguarded breaks (5, 1)
    grid = [inp(a, b) for a in -3:3 for b in -3:3]
    @test any(p -> all(x -> run(GS.guarded_patch(tree, Int[], kit, p[1], p[2]), x) == target(x), grid), pats)
    plain = GS.plain_patch(tree, Int[], RuleNode(r(:k)))
    @test run(plain, inp(5, 1)) != target(inp(5, 1))
    @test tree == RuleNode(r(:x1))                            # patches copy, never mutate

    # nothing repairable ⇒ no patch
    @test isempty(GS.site_patches(kit, tree, Int[], Any[(inp(0, 0), _ -> false)], pass))
end

import Arborist

@testset "GuidedPatchMutation" begin
    CG = CEGIS.CEXGeneration
    GS = CEGIS.GeneticSearch
    path = joinpath(@__DIR__, "..", "spec_files", "case_split", "array_search4.sl")
    spec = CG.parse_spec_from_file(path)
    g = CEGIS.GrammarBuilding.build_grammar_from_sygus(spec)
    st = grammar2symboltable(g, Main)
    r(e) = findfirst(==(e), g.rules)
    inp(x1, k) = Dict{Symbol,Any}(:x1 => x1, :x2 => 0, :x3 => 0, :x4 => 0, :k => k)
    target(x) = max(x[:x1], x[:k])
    run(t, x) = execute_on_input(st, rulenode2expr(t, g), x)

    # The operator reads only the evaluator's tests: hand it a max(x1, k) test set.
    e = GS.CDGPEvaluator(spec, g, :Expr, 4)
    for (a, b) in ((0, 3), (-2, 4), (5, 1), (2, 2), (3, -1), (4, 0), (1, 1), (6, 2), (7, 3), (2, -3))
        push!(e.test_cases, IOExample(inp(a, b), target(inp(a, b))))
    end
    parent = GS.RuleNodeGenome(RuleNode(r(:x1)), g, :Expr)
    passed = [io for io in e.test_cases if run(parent.tree, io.in) == io.out]
    op = GS.GuidedPatchMutation(g, 3, 12, e; rate = 1.0, budget = 1000, min_pass = 1)
    rng = Random.MersenneTwister(3)
    for _ in 1:30
        before = op.stats[:applied]
        child = Arborist.mutate(op, parent, rng)
        if op.stats[:applied] > before                        # a guided child: breaks no passed test
            @test all(io -> run(child.tree, io.in) == io.out, passed)
            @test count(io -> run(child.tree, io.in) == io.out, e.test_cases) > length(passed)
        end
    end
    s = GS.guided_stats(op)
    @test s.mode === :patch && s.attempts == 30 && s.applied > 0
    @test s.analyses == 1 && s.cache_hits == 29                 # one analysis, then cached
    @test parent.tree == RuleNode(r(:x1))

    # v2: sampled localization, small pool, builds on the 3 most recent passing tests — the
    # written patch is validated on all of them, so it still never breaks a passed test.
    op2 = GS.GuidedPatchMutation(g, 3, 12, e; rate = 1.0, budget = 1000, min_pass = 1,
                                 sites = :l3_sampled, candidates = 2, extra = 2, max_pass = 3,
                                 keep_cache = true)
    for _ in 1:30
        before = op2.stats[:applied]
        child = Arborist.mutate(op2, parent, rng)
        op2.stats[:applied] > before && @test all(io -> run(child.tree, io.in) == io.out, passed)
    end
    s2 = GS.guided_stats(op2)
    @test s2.applied > 0 && s2.analyses == 1 && s2.t_localize >= 0 && s2.t_build >= 0
    @test_throws ArgumentError GS.GuidedPatchMutation(g, 3, 12, e; sites = :everywhere)

    # Budget: out of tokens ⇒ fallback, refilled per generation.
    op0 = GS.GuidedPatchMutation(g, 3, 12, e; rate = 1.0, budget = 0, min_pass = 1)
    Arborist.mutate(op0, parent, rng)
    @test GS.guided_stats(op0).budget_skip == 1 && GS.guided_stats(op0).applied == 0
    # Too few passing tests ⇒ ineligible.
    op9 = GS.GuidedPatchMutation(g, 3, 12, e; rate = 1.0, budget = 10, min_pass = 99)
    Arborist.mutate(op9, parent, rng)
    @test GS.guided_stats(op9).ineligible == 1

    # run_cdgp wiring: counters reported, token budget respected, placebo runs, bad combos rejected.
    res = GS.run_cdgp(path; grammar = g, selection = Arborist.LexicaseSelection(), pop_size = 60,
                      generations = 20, max_depth = 5, depth_cap = 10, seed = 2, verbose = false,
                      guided = :patch, guided_budget = 1, guided_min_pass = 2)
    @test res.guided.mode === :patch && res.guided.attempts > 0
    @test res.guided.analyses + res.guided.site_builds <= res.generations + 1
    resp = GS.run_cdgp(path; grammar = g, selection = Arborist.LexicaseSelection(), pop_size = 60,
                       generations = 10, max_depth = 5, depth_cap = 10, seed = 2, verbose = false,
                       guided = :placebo, guided_min_pass = 2)
    @test resp.guided.mode === :placebo
    @test GS.run_cdgp(path; grammar = g, pop_size = 20, generations = 2, verbose = false).guided.mode === :none
    @test_throws ArgumentError GS.run_cdgp(path; grammar = g, fitness = :hybrid, guided = :patch,
                                           generations = 1, verbose = false)
end

@testset "spec answer recipes (guided v3)" begin
    CG = CEGIS.CEXGeneration
    GS = CEGIS.GeneticSearch
    rng = Random.MersenneTwister(11)
    for (rel, n_expected) in (("grammar_variants/max6_logic.sl", 6), ("case_split/array_search4.sl", 5),
                              ("case_split/countpos4_split.sl", 16), ("multi_answer/above4.sl", 4))
        path = joinpath(@__DIR__, "..", "spec_files", rel)
        spec = CG.parse_spec_from_file(path)
        g = CEGIS.GrammarBuilding.build_grammar_from_sygus(spec)
        st = grammar2symboltable(g, Main)
        fname = spec.synth_funs[1].name
        rs = GS.spec_answer_recipes(spec, g)
        @test rs !== nothing && length(rs) == n_expected
        sexprs = Any[CG.read_sexprs(c)[1] for c in spec.constraints]
        names = [fv.name for fv in spec.free_vars]
        # Soundness: wherever a guard fires, the term is a valid answer; the grammar guard agrees.
        for r in rs, _ in 1:100
            vals = rand(rng) < 0.6 ? sort(Random.randperm(rng, 41)[1:length(names)] .- 21) : rand(rng, -9:9, length(names))
            x = Dict{Symbol,Any}(Symbol(n) => v for (n, v) in zip(names, vals))
            GS.recipe_fires(r, fname, x) || continue
            @test r.guard === nothing || execute_on_input(st, rulenode2expr(r.guard, g), x) == true
            out = execute_on_input(st, rulenode2expr(r.term, g), x)
            b = Dict{String,Any}(String(k) => v for (k, v) in x)
            @test all(s -> CG.eval_constraint_pointwise(s, fname, b, _ -> out), sexprs)
        end
    end
    # The generated grammar (no and/or/not): conjunctions become a 0/1 sum through the coercion.
    p6 = joinpath(@__DIR__, "..", "spec_files", "phase3_benchmarks", "max6_simple.sl")
    rs6 = GS.spec_answer_recipes(CG.parse_spec_from_file(p6), CEGIS.build_grammar_from_spec(p6))
    @test rs6 !== nothing && length(rs6) == 6
    # run_cdgp wiring: answer patches are written.
    res = GS.run_cdgp(p6; grammar = CEGIS.build_grammar_from_spec(p6), selection = Arborist.LexicaseSelection(),
                      pop_size = 300, generations = 60, max_depth = 6, depth_cap = 14, seed = 3, verbose = false,
                      guided = :patch, guided_budget = 8, guided_min_pass = 1, guided_sites = :l3_sampled,
                      guided_extra = 2, guided_max_pass = 32, guided_keep_cache = true, guided_shapes = :spec)
    @test res.guided.shape_applied > 0
    @test_throws ArgumentError GS.run_cdgp(p6; guided = :patch, guided_shapes = :bogus, generations = 1, verbose = false)
end
