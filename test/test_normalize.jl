"""
Tests for `normalize_program` — semantic normalization of RuleNode candidates
(the directed-rewrite reimplementation of the e-graph reduction rules).

The central property is **semantics preservation**: a normalized program must
agree with the original on every input. That is checked by brute force over a
grid of inputs, which is a much stronger test than checking individual rewrites.
"""

@testset "RuleNode normalization" verbose = true begin
    GS = CEGIS.GeneticSearch

    spec_path = find_spec_file("max2_simple")
    grammar = CEGIS.build_grammar_from_spec(spec_path)
    ops = GS.GrammarOps(grammar)
    st = HerbInterpret.grammar2symboltable(grammar, Main)

    ix0 = _var_rule(grammar, :x0)
    ix1 = _var_rule(grammar, :x1)
    iplus = _call_rule(grammar, :+)
    iminus = _call_rule(grammar, :-)
    imul = _call_rule(grammar, :*)
    ilt = _call_rule(grammar, :<)
    igt = _call_rule(grammar, :>)
    ile = _call_rule(grammar, :<=)
    ige = _call_rule(grammar, :>=)
    ieq = _call_rule(grammar, :(==))
    iif = _call_rule(grammar, :ifelse)
    i0 = findfirst(==(0), grammar.rules)
    i1 = findfirst(==(1), grammar.rules)
    i2 = findfirst(==(2), grammar.rules)

    nz(n) = GS.normalize_program(n, grammar, ops)
    x0() = RuleNode(ix0)
    x1() = RuleNode(ix1)
    lit(i) = RuleNode(i)

    @testset "identity and absorbing elements" begin
        @test nz(RuleNode(iplus, [lit(i0), x0()])).ind == ix0   # 0 + x0 → x0
        @test nz(RuleNode(iplus, [x0(), lit(i0)])).ind == ix0   # x0 + 0 → x0
        @test nz(RuleNode(iminus, [x0(), lit(i0)])).ind == ix0  # x0 - 0 → x0
        @test nz(RuleNode(imul, [x0(), lit(i1)])).ind == ix0    # x0 * 1 → x0
        @test nz(RuleNode(imul, [lit(i1), x0()])).ind == ix0    # 1 * x0 → x0
        @test nz(RuleNode(imul, [x0(), lit(i0)])).ind == i0     # x0 * 0 → 0
        @test nz(RuleNode(imul, [lit(i0), x0()])).ind == i0     # 0 * x0 → 0
        @test nz(RuleNode(iminus, [x0(), x0()])).ind == i0      # x0 - x0 → 0
    end

    @testset "constant folding within the grammar's literals" begin
        # The generated grammar's literals are 0 and 1 plus the integers the spec mentions, so max2's grammar has no
        # 2 (there, 1 + 1 must survive). arith_simple (2*x + y) contributes the literal 2.
        @test i2 === nothing
        @test length(nz(RuleNode(iplus, [lit(i1), lit(i1)]))) == 3        # 1 + 1 survives: no literal 2
        ga = CEGIS.build_grammar_from_spec(find_spec_file("arith_simple"))
        opsa = GS.GrammarOps(ga)
        nza(n) = GS.normalize_program(n, ga, opsa)
        a0, a1, a2 = (findfirst(==(k), ga.rules) for k in (0, 1, 2))
        aplus, aminus, amul = (_call_rule(ga, op) for op in (:+, :-, :*))
        @test nza(RuleNode(aplus, [RuleNode(a1), RuleNode(a1)])).ind == a2   # 1 + 1 → 2
        @test nza(RuleNode(aminus, [RuleNode(a1), RuleNode(a1)])).ind == a0  # 1 - 1 → 0
        @test nza(RuleNode(amul, [RuleNode(a2), RuleNode(a1)])).ind == a2    # 2 * 1 → 2
        # 2 + 2 = 4 has no literal rule, so the node must survive unchanged.
        four = RuleNode(aplus, [RuleNode(a2), RuleNode(a2)])
        @test length(nza(four)) == length(four)
    end

    @testset "reflexive and constant comparisons" begin
        # Canonical Booleans are `0 < 0` (false) and `0 <= 0` (true): the
        # generated grammar has no Bool literals.
        @test GS._rn_eq(nz(RuleNode(ilt, [x0(), x0()])), ops.false_node)
        @test GS._rn_eq(nz(RuleNode(igt, [x0(), x0()])), ops.false_node)
        @test GS._rn_eq(nz(RuleNode(ile, [x0(), x0()])), ops.true_node)
        @test GS._rn_eq(nz(RuleNode(ige, [x0(), x0()])), ops.true_node)
        @test GS._rn_eq(nz(RuleNode(ieq, [x0(), x0()])), ops.true_node)
        @test GS._rn_eq(nz(RuleNode(ilt, [lit(i1), lit(i0)])), ops.false_node)
        @test GS._rn_eq(nz(RuleNode(ilt, [lit(i0), lit(i1)])), ops.true_node)

        # A reflexive comparison over a large subtree collapses to size 3.
        big = RuleNode(iplus, [x0(), x1()])
        @test length(nz(RuleNode(ige, [big, deepcopy(big)]))) == 3
    end

    @testset "ifelse simplification" begin
        # identical branches
        @test nz(RuleNode(iif, [RuleNode(ilt, [x0(), x1()]), x0(), x0()])).ind == ix0
        # constant condition
        @test nz(RuleNode(iif, [deepcopy(ops.true_node), x0(), x1()])).ind == ix0
        @test nz(RuleNode(iif, [deepcopy(ops.false_node), x0(), x1()])).ind == ix1
        # a reflexive condition becomes constant, then selects a branch
        @test nz(RuleNode(iif, [RuleNode(ige, [x1(), x1()]), x0(), x1()])).ind == ix0
    end

    @testset "mirror elimination and commutative ordering" begin
        # x0 > x1  →  x1 < x0
        m = nz(RuleNode(igt, [x0(), x1()]))
        @test m.ind == ilt
        @test m.children[1].ind == ix1 && m.children[2].ind == ix0
        # x0 >= x1 →  x1 <= x0
        m2 = nz(RuleNode(ige, [x0(), x1()]))
        @test m2.ind == ile
        # `>` and `>=` never survive normalization
        @test nz(RuleNode(igt, [x1(), x0()])).ind == ilt

        # Commutative operands share one representative.
        a = nz(RuleNode(iplus, [x1(), x0()]))
        b = nz(RuleNode(iplus, [x0(), x1()]))
        @test GS._rn_eq(a, b)
        @test GS._rn_eq(nz(RuleNode(ieq, [x1(), x0()])), nz(RuleNode(ieq, [x0(), x1()])))
        # `-` is NOT commutative and must not be reordered.
        s = nz(RuleNode(iminus, [x0(), x1()]))
        @test s.children[1].ind == ix0 && s.children[2].ind == ix1
    end

    @testset "nested redexes reach a fixpoint" begin
        # (x0 - x0) * 1  →  0 * 1  →  0
        @test nz(RuleNode(imul, [RuleNode(iminus, [x0(), x0()]), lit(i1)])).ind == i0
        # ifelse(x0 > x1, 0 + x0, x1 * 1)  →  ifelse(x1 < x0, x0, x1)
        bloated = RuleNode(iif, [
            RuleNode(igt, [x0(), x1()]),
            RuleNode(iplus, [lit(i0), x0()]),
            RuleNode(imul, [x1(), lit(i1)]),
        ])
        r = nz(bloated)
        @test length(r) == 6
        @test r.ind == iif && r.children[1].ind == ilt
        # Normalization is idempotent.
        @test GS._rn_eq(nz(r), r)
    end

    @testset "never grows a program" begin
        for _ in 1:200
            t = rand(RuleNode, grammar, :Expr, 4)
            n = nz(t)
            @test length(n) <= length(t)
            @test depth(n) <= depth(t)
        end
    end

    @testset "semantics preserved on random programs (the key property)" begin
        inputs = [Dict{Symbol,Any}(:x0 => a, :x1 => b)
                  for a in -3:3 for b in -3:3]
        checked = 0
        for _ in 1:300
            t = rand(RuleNode, grammar, :Expr, 4)
            n = nz(t)
            GS._rn_eq(n, t) && continue      # unchanged trees prove nothing
            et = rulenode2expr(t, grammar)
            en = rulenode2expr(n, grammar)
            for input in inputs
                vt = try execute_on_input(st, et, input) catch; :err end
                vn = try execute_on_input(st, en, input) catch; :err end
                @test vt == vn
            end
            checked += 1
        end
        # The corpus must actually exercise the rewriter.
        @test checked > 20
    end

    @testset "run_cdgp normalize=true stays sound end-to-end (max2)" begin
        result = CEGIS.GeneticSearch.run_cdgp(
            spec_path; seed=1, pop_size=60, generations=100, generations_per_round=5,
            fitness=:hybrid, selection=Arborist.LexicaseSelection(),
            normalize=true, verbose=false)

        @test result.solved
        @test result.program !== nothing
        # Independently re-verify the program the normalizing run produced.
        spec = CEGIS.CEXGeneration.parse_spec_from_file(spec_path)
        smt = CEGIS.CEXGeneration.rulenode_to_smt2(result.program.tree, grammar)
        @test CEGIS.CEXGeneration.verify_query(
            CEGIS.CEXGeneration.generate_cex_query(spec, Dict("max2" => smt))).status == :unsat
        # No `>`/`>=` can survive in a fully normalized program.
        inds = Int[]
        _walk(n) = (push!(inds, n.ind); foreach(_walk, n.children))
        _walk(result.program.tree)
        @test !(igt in inds) && !(ige in inds)
    end
end
