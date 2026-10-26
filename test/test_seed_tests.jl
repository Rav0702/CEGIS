"""
Seeded starting tests (src/GeneticSearch/seed_tests.jl, E3): one point per satisfiable implication premise, the
random control of the same size, and `run_cdgp(...; seed_tests)` adding them before generation 0.
"""

@testset "seeded starting tests (E3)" begin
    GS = CEGIS.GeneticSearch
    CG = CEGIS.CEXGeneration
    root = joinpath(@__DIR__, "..", "spec_files")

    # One point per region premise; none for a bound spec.
    for (rel, n) in (("case_split/array_search4.sl", 5), ("case_split/countpos4_split.sl", 16),
                     ("partial_knowledge/tiered3.sl", 6), ("multi_answer/above4.sl", 0))
        sp = CG.parse_spec_from_file(joinpath(root, rel))
        pts = GS.spec_region_points(sp)
        @test length(pts) == n
        @test all(p -> Set(keys(p)) == Set(fv.name for fv in sp.free_vars), pts)
    end

    # Each array_search4 point satisfies its own premise: k lands in a distinct region of a sorted array.
    sp = CG.parse_spec_from_file(joinpath(root, "case_split/array_search4.sl"))
    pts = GS.spec_region_points(sp)
    @test all(p -> p["x1"] < p["x2"] < p["x3"] < p["x4"], pts)
    @test length(unique(count(x -> p["k"] > p[x], ("x1", "x2", "x3", "x4")) for p in pts)) == 5

    # The random control: same size, own RNG (the global stream is untouched), values in range.
    rng_state = copy(Random.default_rng())
    rp = GS.random_points(sp, 5, Random.MersenneTwister(1); lo = -3, hi = 3)
    @test length(rp) == 5 && all(p -> all(v -> -3 <= v <= 3, values(p)), rp)
    @test rand(copy(rng_state)) == rand(Random.default_rng())

    # E3b, interior points: one per region, inside its own premise, in range, no z3 fallback; reproducible from the
    # caller's RNG, which is the only stream consumed.
    for (rel, n) in (("case_split/array_search4.sl", 5), ("case_split/countpos4_split.sl", 16),
                     ("partial_knowledge/tiered3.sl", 6), ("multi_answer/above4.sl", 0))
        s = CG.parse_spec_from_file(joinpath(root, rel))
        r = GS.spec_region_inner_points(s, Random.MersenneTwister(3))
        @test length(r.points) == n && r.fallbacks == 0
        @test all(p -> all(v -> -10 <= v <= 10, values(p)), r.points)
    end
    rng_state = copy(Random.default_rng())
    inner = GS.spec_region_inner_points(sp, Random.MersenneTwister(3)).points
    @test rand(copy(rng_state)) == rand(Random.default_rng())
    @test inner == GS.spec_region_inner_points(sp, Random.MersenneTwister(3)).points
    @test all(p -> p["x1"] < p["x2"] < p["x3"] < p["x4"], inner)
    @test sort([count(x -> p["k"] > p[x], ("x1", "x2", "x3", "x4")) for p in inner]) == 0:4
    @test inner != pts                                                   # not z3's boundary models
    cp = CG.parse_spec_from_file(joinpath(root, "case_split/countpos4_split.sl"))
    @test any(p -> any(v -> !(v in (0, 1)), values(p)), GS.spec_region_inner_points(cp, Random.MersenneTwister(3)).points)

    # run_cdgp: tests exist before generation 0 and are counted; off by default.
    p = joinpath(root, "case_split/array_search4.sl")
    g = CEGIS.GrammarBuilding.build_grammar_from_sygus(sp)
    for (mode, n) in ((:none, 0), (:regions, 5), (:regions_inner, 5), (:random, 5))
        r = GS.run_cdgp(p; grammar = g, fitness = :tests, seed_tests = mode, pop_size = 50, max_depth = 4,
                        depth_cap = 8, generations = 1, generations_per_round = 1, max_time = 30.0, verbose = false)
        @test r.completion.seeded == n
        @test length(r.test_cases) + length(r.incomplete_tests) >= n
    end
    @test_throws ArgumentError GS.run_cdgp(p; grammar = g, fitness = :hybrid, seed_tests = :regions, verbose = false)
end
