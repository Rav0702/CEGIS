"""
Spec knowledge as programs of the first population (src/GeneticSearch/seed_programs.jl, E4): the knowledge items, the
inert placebo, the four seed modes, the population hook, and `run_cdgp(...; seed_programs)`.
"""

import Arborist

@testset "seeded programs (E4)" begin
    GS = CEGIS.GeneticSearch
    CG = CEGIS.CEXGeneration
    root = joinpath(@__DIR__, "..", "spec_files")
    dep(n) = isempty(n.children) ? 1 : 1 + maximum(dep, n.children)
    load(rel) = (local s = CG.parse_spec_from_file(joinpath(root, rel));
                 (s, CEGIS.GrammarBuilding.build_grammar_from_sygus(s), CEGIS.GrammarBuilding.sygus_start_symbol(s)))
    unsat(sp, g, b) = CG.verify_query("(set-logic LIA)\n" *
        join(("(declare-fun $(fv.name) () Int)" for fv in sp.free_vars), "\n") *
        "\n(assert (= $(CG.rulenode_to_smt2(b, g)) 1))\n(check-sat)\n").status === :unsat   # a Bool root renders as (ite b 1 0)
    # the guards along a seed's chain, outermost first
    chain(s, m) = (gs = RuleNode[]; n = s; for _ in 1:m; push!(gs, n.children[1]); n = n.children[3]; end; gs)

    # (spec, items, depth cap, complete coverage)
    for (rel, k, cap, complete) in (("multi_answer/above4.sl", 4, 10, true), ("case_split/array_search4.sl", 5, 12, true),
                                    ("grammar_variants/max6_sygus.sl", 6, 14, true), ("partial_knowledge/tiered3.sl", 6, 12, false))
        sp, g, st = load(rel)
        fname = sp.synth_funs[1].name
        R = GS._Rules(g)
        items = GS.seed_items(sp, g)
        @test length(items) == k
        @test count(it -> it[2] === nothing, items) == (complete ? 0 : 4)     # tiered3: regions C-F answer unknown
        guards = [G for (G, _) in items]
        inert = [GS.inert_guard(G, R) for G in guards]
        @test all(I -> unsat(sp, g, I), inert)                                 # never fires
        @test all(G -> !unsat(sp, g, G), guards)                               # the real guards do
        @test all(i -> length(GS._conj_atoms(inert[i], R)) == max(2, length(GS._conj_atoms(guards[i], R))), 1:k)

        for mode in (:guard, :partial, :full, :inert)
            seeds = GS.spec_seed_programs(sp, g, st, mode, 12; depth_cap = cap, rng_seed = 5)
            @test length(seeds) == 12 && all(s -> dep(s) <= cap, seeds)
            @test seeds == GS.spec_seed_programs(sp, g, st, mode, 12; depth_cap = cap, rng_seed = 5)
            m = mode === :partial ? cld(k, 2) : k
            forms = mode === :inert ? inert : guards
            @test all(s -> (c = chain(s, m); allunique(c) && all(in(forms), c)), seeds)
            @test all(s -> GS.seed_guards_kept(s, sp, g, mode) >= m, seeds)
            if mode in (:partial, :full)       # a recipe's leaf is its answer
                ans = Dict(G => t for (G, t) in items if t !== nothing)
                leaves(s) = (ls = Tuple{RuleNode,RuleNode}[]; n = s;
                             for _ in 1:m; push!(ls, (n.children[1], n.children[2])); n = n.children[3]; end; ls)
                @test all(s -> all(((G, l),) -> !haskey(ans, G) || l == ans[G], leaves(s)), seeds)
            end
            if mode === :full && complete        # every recipe in the chain: the seed solves the spec
                @test all(s -> CG.verify_query(CG.generate_cex_query(sp,
                                   Dict(fname => CG.rulenode_to_smt2(s, g)))).status === :unsat, seeds[1:3])
            end
        end
        @test_throws ArgumentError GS.spec_seed_programs(sp, g, st, :answers, 1; depth_cap = cap, rng_seed = 1)
    end

    # The global RNG stream is untouched by drawing seeds.
    sp, g, st = load("multi_answer/above4.sl")
    state = copy(Random.default_rng())
    GS.spec_seed_programs(sp, g, st, :guard, 5; depth_cap = 10, rng_seed = 9)
    @test rand(copy(state)) == rand(Random.default_rng())

    # A chain deeper than the cap is refused: countpos4.split has 16 guards of depth 4, against cap 12.
    cp, cg, cst = load("case_split/countpos4_split.sl")
    @test_throws ArgumentError GS.spec_seed_programs(cp, cg, cst, :guard, 1; depth_cap = 12, rng_seed = 1)
    @test_throws ArgumentError GS.spec_seed_programs(cp, cg, cst, :full, 1; depth_cap = 16, rng_seed = 1)

    # The hook: seeds take the first slots of the first population, the sampled rest is the unseeded run's, and the
    # hook empties after use.
    ev = GS.CDGPEvaluator(sp, g, st, 4)
    prob = Arborist.GPProblem(ev, GS.RuleNodeGenome; seed = 1)
    alg = Arborist.GeneticProgramming(pop_size = 20, parallel = false)
    seeds = GS.spec_seed_programs(sp, g, st, :guard, 3; depth_cap = 10, rng_seed = 2)
    Random.seed!(77); plain = first(Arborist._initialize_population(prob, alg, Random.MersenneTwister(1)))
    GS._INIT_SEEDS[] = seeds
    Random.seed!(77); seeded = first(Arborist._initialize_population(prob, alg, Random.MersenneTwister(1)))
    @test [x.tree for x in seeded[1:3]] == seeds
    @test [x.tree for x in seeded[4:end]] == [x.tree for x in plain[4:end]]
    @test isempty(GS._INIT_SEEDS[])

    # run_cdgp: off by default; the full chain solves above4 in the first generations; recorded in `completion`.
    p = joinpath(root, "multi_answer/above4.sl")
    kw = (grammar = g, start_symbol = st, fitness = :tests, selection = Arborist.LexicaseSelection(), pop_size = 50,
          max_depth = 4, depth_cap = 10, generations = 2, generations_per_round = 1, max_time = 60.0, verbose = false)
    r = GS.run_cdgp(p; kw...)
    @test !haskey(r.completion, :programs_seeded)
    r = GS.run_cdgp(p; kw..., seed_programs = :full)
    @test r.solved && r.completion.programs_seeded == 5 && r.completion.seed_guards_kept >= 1
    r = GS.run_cdgp(p; kw..., seed_programs = :inert, seed_fraction = 0.2)
    @test r.completion.programs_seeded == 10 && r.completion.seed_size_mean > 0
    @test isempty(GS._INIT_SEEDS[])
    @test_throws ArgumentError GS.run_cdgp(p; kw..., seed_programs = :answers)
    @test_throws ArgumentError GS.run_cdgp(p; kw..., seed_programs = :guard, seed_fraction = 0.0)

    # The inert fallback (confirmatory phase): guards that are not conjunctions of negatable atoms (a disjunction in
    # conditional_sum_hard, an equality in abs/sign) become G ∧ (d ≥ d + 1); every inert guard holds nowhere, and
    # inert seeds fit the registry's raised cap.
    for (rel, cap) in (("confirmatory/abs_value_easy.sl", 12), ("confirmatory/sign_function_easy.sl", 12),
                       ("confirmatory/conditional_sum_hard.sl", 18))
        sp, g, st = load(rel)
        R = GS._Rules(g)
        items = GS.seed_items(sp, g)
        inert = [GS.inert_guard(G, R) for (G, _) in items]
        @test all(I -> unsat(sp, g, I), inert)
        @test any(p -> p[2].ind == R.ops[:and] && p[2].children[1] == p[1][1], zip(items, inert))   # the fallback fired
        s = GS.spec_seed_programs(sp, g, st, :inert, 4; depth_cap = cap, rng_seed = 7)
        @test length(s) == 4 && all(x -> dep(x) <= cap, s)
    end
end
