"""
Guard-only knowledge (spec_knowledge/PARTIAL_KNOWLEDGE.md, E6a): `spec_region_guards`, the `caseguard`/`decoy`
grammar files it feeds, and the decomposed mode of `RecipeIterator` / `run_recipe_cegis(...; regions = true)`.
"""

@testset "region guards and decomposed CEGIS" begin
    GS = CEGIS.GeneticSearch
    CG = CEGIS.CEXGeneration
    root = joinpath(@__DIR__, "..", "spec_files")
    z3 = something(Sys.which("z3"), raw"C:\Users\rafal\tools\z3\z3-4.16.0-x64-win\bin\z3.exe")
    load(rel) = (sp = CG.parse_spec_from_file(joinpath(root, rel)); (sp, CEGIS.GrammarBuilding.build_grammar_from_sygus(sp)))

    # The compiler: guards only where the spec names a region but does not write its answer.
    for (rel, cons) in (("partial_knowledge/tiered.sl", [3, 4]), ("partial_knowledge/tiered3.sl", [3, 4, 5, 6]),
                        ("case_split/array_search4.sl", Int[]), ("case_split/countpos4_split.sl", Int[]),
                        ("multi_answer/above4.sl", Int[]), ("grammar_variants/max6_sygus.sl", Int[]))
        sp, g = load(rel)
        @test [r.constraint for r in GS.spec_region_guards(sp, g)] == cons
    end

    # On tiered3, recipes and region guards partition the input space: exactly one fires at every input.
    sp, g = load("partial_knowledge/tiered3.sl")
    fname = sp.synth_funs[1].name
    rec, reg = GS.spec_answer_recipes(sp, g), GS.spec_region_guards(sp, g)
    @test length(rec) == 2 && length(reg) == 4
    for _ in 1:300
        x = Dict{Symbol,Any}(:x => rand(-4:4), :y => rand(-4:4), :z => rand(-4:4))
        @test count(r -> GS.recipe_fires(r, fname, x), rec) + count(r -> GS.region_fires(r, fname, x), reg) == 1
    end

    # Grammar files: 2 case + 4 guard productions, same shape in the decoy; interpreter and z3 agree on them.
    compound(gg) = [i for i in eachindex(gg.rules) if CG._is_compound_rule(gg.rules[i], gg)]
    _, gc = load("enriched/tiered3_caseguard.sl")
    _, gd = load("enriched/tiered3_decoy.sl")
    @test sort([length(gc.childtypes[i]) for i in compound(gc)]) == [1, 1, 2, 2, 2, 2]
    @test sort([length(gd.childtypes[i]) for i in compound(gd)]) == [1, 1, 2, 2, 2, 2]
    inds(t) = vcat(t.ind, (inds(c) for c in t.children)...)
    progs = RuleNode[]
    while length(progs) < 25
        t = rand(RuleNode, gc, :Expr, 5)
        any(in(compound(gc)), inds(t)) && push!(progs, t)
    end
    st = grammar2symboltable(gc)
    q, want = IOBuffer(), Int[]
    for t in progs, _ in 1:6
        x = Dict(:x => rand(-5:5), :y => rand(-5:5), :z => rand(-5:5))
        binds = join(("($k $(v < 0 ? "(- $(-v))" : v))" for (k, v) in x), " ")
        println(q, "(simplify (let ($binds) $(CG.rulenode_to_smt2(t, gc))))")
        push!(want, Int(HerbInterpret.execute_on_input(st, rulenode2expr(t, gc), x)))
    end
    out = read(pipeline(`$z3 -in`; stdin = IOBuffer(take!(q))), String)
    @test [parse(Int, replace(strip(l), r"^\(- (\d+)\)$" => s"-\1")) for l in split(strip(out), '\n')] == want

    # Decomposed CEGIS: solves where the plain recipe iterator gets stuck; plain mode unchanged.
    for rel in ("partial_knowledge/tiered.sl", "partial_knowledge/tiered3.sl")
        p = joinpath(root, rel)
        s2, g2 = load(rel)
        plain = CEGIS.run_recipe_cegis(p; grammar = g2, max_time = 60.0)
        @test !plain.solved && plain.guided.no_patch == 1 && plain.verifications == 1
        r = CEGIS.run_recipe_cegis(p; grammar = g2, regions = true, max_time = 120.0)
        @test r.solved && r.guided.mode === :recipes_regions && r.guided.leaf_searches >= length(GS.spec_region_guards(s2, g2))
        smt = CG.rulenode_to_smt2(r.program.tree, g2)
        @test CG.verify_query(CG.generate_cex_query(s2, Dict(s2.synth_funs[1].name => smt))).status == :unsat
    end

    # EUSolver-style rival (leaf_search = :unif): terms + predicates + decision-tree unification per region. Solves a
    # hidden sub-split spec (region answers max / min) that the linear term solver cannot, and still a linear one.
    for rel in ("partial_knowledge/hidden3.sl", "partial_knowledge/tiered3.sl")
        p = joinpath(root, rel)
        s4, g4 = load(rel)
        r = CEGIS.run_recipe_cegis(p; grammar = g4, regions = true, leaf_search = :unif, max_time = 60.0)
        @test r.solved
        smt = CG.rulenode_to_smt2(r.program.tree, g4)
        @test CG.verify_query(CG.generate_cex_query(s4, Dict(s4.synth_funs[1].name => smt))).status == :unsat
    end
    let p = joinpath(root, "partial_knowledge/hidden3.sl"), (s5, g5) = load("partial_knowledge/hidden3.sl")
        @test !CEGIS.run_recipe_cegis(p; grammar = g5, regions = true, leaf_search = :oe, max_time = 20.0).solved
    end

    # The fair enumerative rival (leaf_search = :oe): bottom-up + observational equivalence, regions judged by their
    # constraint. Solves a large-leaf family member and a multi-answer (interval) one, where output-matching BFS fails.
    for rel in ("partial_knowledge/family/pk_n3_m6_k2_s13_seed1.sl", "partial_knowledge/family/pk_n3_m6_k2_s9_w2_seed1.sl")
        p = joinpath(root, rel)
        s3, g3 = load(rel)
        r = CEGIS.run_recipe_cegis(p; grammar = g3, regions = true, leaf_search = :oe, max_time = 60.0)
        @test r.solved
        smt = CG.rulenode_to_smt2(r.program.tree, g3)
        @test CG.verify_query(CG.generate_cex_query(s3, Dict(s3.synth_funs[1].name => smt))).status == :unsat
    end
end
