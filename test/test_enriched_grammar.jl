"""
Spec-enriched grammars (scripts/gen_enriched_grammars.jl, spec_files/enriched/): the answer recipes as
compound productions `Start → (ite G_t t Start)`. Checks the pipeline end to end on them:
- the SyGuS importer reads the nested productions;
- `rulenode_to_smt2` renders compound rules (children depth-first, as `rulenode2expr` substitutes them):
  fuzzed against the interpreter, with z3 evaluating the SMT at the same inputs;
- a chain of case productions verifies as a solution, and the decoy grammar's chain does not.
"""

@testset "spec-enriched grammars" begin
    GS = CEGIS.GeneticSearch
    CG = CEGIS.CEXGeneration
    root = joinpath(@__DIR__, "..", "spec_files", "enriched")
    z3 = something(Sys.which("z3"), raw"C:\Users\rafal\tools\z3\z3-4.16.0-x64-win\bin\z3.exe")
    load(f) = (sp = CG.parse_spec_from_file(joinpath(root, f)); (sp, CEGIS.GrammarBuilding.build_grammar_from_sygus(sp)))
    compound(g) = [i for i in eachindex(g.rules) if CG._is_compound_rule(g.rules[i], g)]
    inds(t) = vcat(t.ind, (inds(c) for c in t.children)...)

    # Chain every case production over the answer of the last one: ite(G_1, t_1, … ite(G_n-1, t_n-1, t_n)).
    function chain(g, sp)
        cases = compound(g)
        base = GS.spec_answer_recipes(sp, g)[end].term
        return foldr((i, acc) -> RuleNode(i, [acc]), cases[1:end-1]; init = base)
    end

    for stem in ("above4", "array_search4", "countpos4_split", "max6_sygus")
        sp, g = load("$(stem)_case.sl")
        spd, gd = load("$(stem)_decoy.sl")
        n = length(GS.spec_answer_recipes(sp, g))
        @test length(compound(g)) == n == length(compound(gd))   # decoy: same number of productions

        # Interpreter vs z3 on random programs that use the compound rules.
        rng_inputs = [Dict(Symbol(p) => rand(-6:6) for (p, _) in sp.synth_funs[1].params) for _ in 1:8]
        progs = RuleNode[]
        while length(progs) < 25
            t = rand(RuleNode, g, :Expr, 5)
            any(in(compound(g)), inds(t)) || continue                # must use a compound rule
            push!(progs, t)
        end
        st = grammar2symboltable(g)
        q, want = IOBuffer(), Int[]
        for t in progs, x in rng_inputs
            binds = join(("($k $(v < 0 ? "(- $(-v))" : v))" for (k, v) in x), " ")
            println(q, "(simplify (let ($binds) $(CG.rulenode_to_smt2(t, g))))")
            push!(want, Int(HerbInterpret.execute_on_input(st, rulenode2expr(t, g), x)))
        end
        out = read(pipeline(`$z3 -in`; stdin = IOBuffer(take!(q))), String)
        got = [parse(Int, replace(strip(l), r"^\(- (\d+)\)$" => s"-\1")) for l in split(strip(out), '\n')]
        @test got == want

        # The case chain is a solution; the decoy chain is not.
        name = sp.synth_funs[1].name
        verdict(s, gg) = CG.verify_query(CG.generate_cex_query(s, Dict(name => CG.rulenode_to_smt2(chain(gg, s), gg)))).status
        @test verdict(sp, g) == :unsat
        @test verdict(spd, gd) == :sat
    end
end

# E5a variants (spec_knowledge/E5A_DESIGN.md, scripts/gen_enriched_grammars.jl), one production per recipe guard:
# - `guard`: (ite G Start Start). Filling the branches with the recipe answers gives a verified solution.
# - `inert`: (ite ⊥ Start Start). Every ⊥ is unsatisfiable.
# - `guarddecoy`: (ite G̃ Start Start). Each G̃ fires on the care set (the recipe guards' union), lies inside no real
#   region and is not the union of the regions it contains (z3, exactly). Not written for array_search4 and
#   countpos4.split, whose region boundaries are the guard atoms themselves: every scrambled conjunction is, on the
#   care set, empty or a union of real regions.
# Herb drops duplicate rules, so each variant must keep all k productions (same rule count as the case grammar).
@testset "E5a grammar variants (guard, inert, guarddecoy)" begin
    GS = CEGIS.GeneticSearch
    CG = CEGIS.CEXGeneration
    root = joinpath(@__DIR__, "..", "spec_files", "enriched")
    load(f) = (sp = CG.parse_spec_from_file(joinpath(root, f)); (sp, CEGIS.GrammarBuilding.build_grammar_from_sygus(sp)))
    compound(g) = [i for i in eachindex(g.rules) if CG._is_compound_rule(g.rules[i], g)]
    lit(g, v) = RuleNode(findfirst(j -> g.rules[j] == v && g.types[j] == :Expr, eachindex(g.rules)))
    # A two-branch compound rule (ite G Start Start) with branches 1 and 0: its guard as an Int term.
    guard01(g, i) = CG.rulenode_to_smt2(RuleNode(i, [lit(g, 1), lit(g, 0)]), g)
    function status(sp, asserts...)
        decl = join(("(declare-fun $p () Int)" for (p, _) in sp.synth_funs[1].params), "\n")
        return CG.verify_query("(set-logic LIA)\n$decl\n" * join(("(assert $a)" for a in asserts), "\n") * "\n(check-sat)\n").status
    end

    for stem in ("above4", "array_search4", "max6_sygus", "countpos4_split")
        sp, g = load("$(stem)_guard.sl")
        _, gi = load("$(stem)_inert.sl")
        _, gc = load("$(stem)_case.sl")
        recipes = GS.spec_answer_recipes(sp, g)
        k = length(recipes)
        @test length(compound(g)) == length(compound(gi)) == k
        @test length(g.rules) == length(gi.rules) == length(gc.rules)

        # guard: ite(G_1, t_1, ite(G_2, t_2, … t_k)) over the guard productions verifies.
        cs = compound(g)
        prog = foldr((i, acc) -> RuleNode(cs[i], [recipes[i].term, acc]), 1:k-1; init = recipes[k].term)
        name = sp.synth_funs[1].name
        @test CG.verify_query(CG.generate_cex_query(sp, Dict(name => CG.rulenode_to_smt2(prog, g)))).status == :unsat

        # inert: no guard fires anywhere (while the real guards, rendered the same way, do).
        @test all(i -> status(sp, "(= $(guard01(g, i)) 1)") == :sat, cs)
        @test all(i -> status(sp, "(= $(guard01(gi, i)) 1)") == :unsat, compound(gi))

        file = "$(stem)_guarddecoy.sl"
        if stem in ("array_search4", "countpos4_split")
            @test !isfile(joinpath(root, file))
            continue
        end
        _, gd = load(file)
        @test length(compound(gd)) == k && length(gd.rules) == length(gc.rules)
        real = ["(= $(guard01(g, i)) 1)" for i in cs]
        care = "(or " * join(real, " ") * ")"
        for i in compound(gd)
            D = "(= $(guard01(gd, i)) 1)"
            @test status(sp, D, care) == :sat                                         # fires where tests arise
            @test all(R -> status(sp, D, care, "(not $R)") == :sat, real)             # inside no region
            contained = filter(R -> status(sp, R, "(not $D)") == :unsat, real)
            @test status(sp, D, care, ("(not $R)" for R in contained)...) == :sat     # not a union of regions
        end
    end
end

@testset "E5 grammar variants (atoms, blocks and their inert placebos)" begin
    GS = CEGIS.GeneticSearch
    CG = CEGIS.CEXGeneration
    root = joinpath(@__DIR__, "..", "spec_files", "enriched")
    load(f) = (local s = CG.parse_spec_from_file(joinpath(root, f)); (s, CEGIS.GrammarBuilding.build_grammar_from_sygus(s)))
    compound(g, T) = [i for i in eachindex(g.rules) if CG._is_compound_rule(g.rules[i], g) && g.types[i] == T]
    rule(g, e, T) = findfirst(j -> g.rules[j] == e && g.types[j] == T, eachindex(g.rules))
    lit(g, v) = RuleNode(rule(g, v, :Expr))
    function status(sp, asserts...)
        decl = join(("(declare-fun $p () Int)" for (p, _) in sp.synth_funs[1].params), "\n")
        return CG.verify_query("(set-logic LIA)\n$decl\n" * join(("(assert $a)" for a in asserts), "\n") * "\n(check-sat)\n").status
    end
    holds(sp, g, i) = "(= $(CG.rulenode_to_smt2(RuleNode(GS._Rules(g).ops[:ite], [RuleNode(i), lit(g, 1), lit(g, 0)]), g)) 1)"
    verifies(sp, g, prog) = CG.verify_query(CG.generate_cex_query(sp, Dict(sp.synth_funs[1].name => CG.rulenode_to_smt2(prog, g)))).status == :unsat

    # (stem, distinct atoms, new answer terms)
    for (stem, na, nt) in (("above4", 12, 4), ("array_search4", 11, 3), ("max6_sygus", 6 * 5, 0))
        sp, ga = load("$(stem)_atoms.sl")
        _, gai = load("$(stem)_atomsinert.sl")
        _, gb = load("$(stem)_blocks.sl")
        _, gbi = load("$(stem)_blocksinert.sl")
        k = length(GS.spec_answer_recipes(sp, gb))
        @test length(compound(ga, :BoolExpr)) == length(compound(gai, :BoolExpr)) == na
        @test length(compound(gb, :BoolExpr)) == length(compound(gbi, :BoolExpr)) == k
        @test length(compound(ga, :Expr)) == length(compound(gai, :Expr)) == length(compound(gb, :Expr)) ==
              length(compound(gbi, :Expr)) == nt
        @test length(ga.rules) == length(gai.rules) && length(gb.rules) == length(gbi.rules)

        # blocks: ite(G_1, t_1, ite(G_2, t_2, … t_k)) from the block and term productions verifies.
        for (g, atoms) in ((gb, false), (ga, true))
            R = GS._Rules(g)
            rs = GS.spec_answer_recipes(sp, g)
            term(r) = RuleNode(rule(g, rulenode2expr(r.term, g), :Expr))     # a new term production, or a terminal
            # atoms: rebuild each guard over the atom productions (its and-structure kept)
            over_atoms(n) = n.ind in GS._cmp_rules(R) ? RuleNode(rule(g, rulenode2expr(n, g), :BoolExpr)) :
                            RuleNode(n.ind, [over_atoms(c) for c in n.children])
            guard(r) = atoms ? over_atoms(r.guard) : RuleNode(rule(g, rulenode2expr(r.guard, g), :BoolExpr))
            @test all(r -> length(term(r)) == 1, rs)
            prog = foldr((r, acc) -> RuleNode(R.ops[:ite], [guard(r), term(r), acc]), rs[1:end-1]; init = term(rs[end]))
            @test verifies(sp, g, prog)
        end

        # inert: no inert atom or block ever holds, while the real ones do; inert terms equal 0 or a variable.
        for (g, gi) in ((ga, gai), (gb, gbi))
            @test all(i -> status(sp, holds(sp, g, i)) == :sat, compound(g, :BoolExpr))
            @test all(i -> status(sp, holds(sp, gi, i)) == :unsat, compound(gi, :BoolExpr))
            vals = vcat(["0"], [String(p) for (p, _) in sp.synth_funs[1].params])
            @test all(i -> any(v -> status(sp, "(distinct $(CG.rulenode_to_smt2(RuleNode(i), gi)) $v)") == :unsat, vals),
                      compound(gi, :Expr))
        end
    end
end
