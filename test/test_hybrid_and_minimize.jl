"""
Tests for the hybrid tests+constraints evaluator (`HybridCDGPEvaluator`),
solver-information extraction (violation witnesses, `complete_output`), the
NSGA-II Pareto engine wiring, and the verified minimizer (`minimize_program`).
"""

import Arborist

@testset "Hybrid CDGP, witnesses, NSGA-II, minimizer" verbose = true begin
    CG = CEGIS.CEXGeneration

    function _max2_spec()
        s = CG.Spec(); s.logic = "LIA"
        s.synth_funs = [CG.SynthFun("max2", [("x0", "Int"), ("x1", "Int")], "Int")]
        s.free_vars = [CG.FreeVar("x0", "Int"), CG.FreeVar("x1", "Int")]
        s.constraints = [
            "(>= (max2 x0 x1) x0)",
            "(>= (max2 x0 x1) x1)",
            "(or (= x0 (max2 x0 x1)) (= x1 (max2 x0 x1)))",
        ]
        s
    end

    @testset "violation witnesses from ConstraintSatSolver" begin
        css = CG.ConstraintSatSolver(_max2_spec())
        r, ws = CG.check_constraint_satisfaction_witnesses(css, "max2", "x0")
        @test r.satisfied == [true, false, true]
        @test ws[1] === nothing && ws[3] === nothing
        # The witness for constraint 2 is a genuine violating input: x0 < x1,
        # where the candidate `x0` indeed fails (>= (max2 x0 x1) x1).
        @test ws[2] !== nothing
        @test ws[2]["x0"] < ws[2]["x1"]

        # Fully correct candidate: no witnesses at all.
        r2, ws2 = CG.check_constraint_satisfaction_witnesses(
            css, "max2", "(ite (< x0 x1) x1 x0)")
        @test all(r2.satisfied)
        @test all(w === nothing for w in ws2)
    end

    @testset "complete_output pins inputs and reads out_<f>" begin
        cs = CG.CexSolver(_max2_spec())
        @test CG.complete_output(cs, Dict("x0" => 3, "x1" => 7)) == 7
        @test CG.complete_output(cs, Dict("x0" => -2, "x1" => -9)) == -2
        # Solver state is clean afterwards (push/pop isolation).
        @test CG.find_counterexample(cs, "max2", "(ite (< x0 x1) x1 x0)").status == :unsat
    end

    @testset "HybridCDGPEvaluator mechanics (max2)" begin
        spec_path = find_spec_file("max2_simple")
        spec = CG.parse_spec_from_file(spec_path)
        grammar = CEGIS.build_grammar_from_spec(spec_path)
        e = CEGIS.GeneticSearch.HybridCDGPEvaluator(spec, grammar, :Expr, 4)

        ix0 = _var_rule(grammar, :x0)
        ix1 = _var_rule(grammar, :x1)
        igt = _call_rule(grammar, :>)
        iif = _call_rule(grammar, :ifelse)

        # `x0` starts clean on all evidence (no tests, no witnesses) so it is
        # certified; the violation of constraint 2 both banks a witness and is
        # harvested into a test it then fails.
        wrong = CEGIS.GeneticSearch.RuleNodeGenome(RuleNode(ix0), grammar, :Expr)
        f = Arborist.evaluate_genome(wrong, e)
        @test f == 1.0 + 1.0          # 1 failed harvested test + 1 failed witness
        @test length(e.test_cases) == 1
        @test e.harvested == 1
        # Harvested test is spec-consistent.
        io = e.test_cases[1]
        @test io.out == max(io.in[:x0], io.in[:x1])

        # The violated constraint contributed exactly one banked witness, and
        # it is not double-charged as an unproven ∀-verdict on top of that.
        @test length(e.witness_bank) == 1
        @test e.witness_bank[1][1] == 2

        # Case vector = tests ++ witnesses ++ size (parsimony on by default).
        cv = Arborist.evaluate_cases(wrong, e)
        @test e.parsimony
        @test length(cv) == length(e.test_cases) + length(e.witness_bank) + 1
        @test cv[1] == 1.0                   # fails its own harvested test
        @test cv[2] == 1.0                   # fails its own banked witness
        @test cv[end] == Float64(length(wrong.tree))   # size case

        # Multi-objective vector: [failed_tests, constraint_violations] only —
        # complexity is deliberately not a Pareto objective.
        mo = Arborist.evaluate_multi(e, wrong)
        @test mo == [1.0, 1.0]
        @test Arborist.objective_names(e) == ["failed_tests", "constraint_violations"]

        # Gating: a genome failing cheap evidence never reaches Z3, but still
        # gets a graded score from tests + witnesses (no constant filler).
        # Use a constant that provably differs from the harvested test's output.
        @test e.gate_constraints
        bad_const = e.test_cases[1].out == 0 ? 1 : 0
        ibad = findfirst(==(bad_const), grammar.rules)
        @test ibad !== nothing
        gated = CEGIS.GeneticSearch.RuleNodeGenome(RuleNode(ibad), grammar, :Expr)
        checks_before = e.z3_checks
        fg = Arborist.evaluate_genome(gated, e)
        @test fg >= 1.0 && isfinite(fg)
        @test Arborist.evaluate_multi(e, gated)[1] == 1.0   # fails the test
        @test e.z3_checks == checks_before                  # …without Z3

        # Witness cases are defined for gated genomes too — the old neutral
        # filler is gone.
        cv_gated = Arborist.evaluate_cases(gated, e)
        @test length(cv_gated) == length(cv)
        @test all(isfinite, cv_gated)

        # Correct candidate: solved via constraint verdicts alone, no harvest.
        correct = CEGIS.GeneticSearch.RuleNodeGenome(
            RuleNode(iif, [RuleNode(igt, [RuleNode(ix0), RuleNode(ix1)]),
                           RuleNode(ix0), RuleNode(ix1)]), grammar, :Expr)
        @test Arborist.evaluate_genome(correct, e) == 0.0
        @test e.solved !== nothing
        @test length(e.test_cases) == 1
    end

    @testset "run_cdgp fitness=:hybrid with lexicase (max2)" begin
        spec_path = find_spec_file("max2_simple")
        result = CEGIS.GeneticSearch.run_cdgp(
            spec_path; seed=1, pop_size=60, generations=100, generations_per_round=5,
            fitness=:hybrid, selection=Arborist.LexicaseSelection(),
            minimize=true, verbose=false)

        @test result.solved
        @test result.program !== nothing
        # Independent re-verification of the (minimized) program.
        spec = CG.parse_spec_from_file(spec_path)
        grammar = CEGIS.build_grammar_from_spec(spec_path)
        smt = CG.rulenode_to_smt2(result.program.tree, grammar)
        @test CG.verify_query(CG.generate_cex_query(spec, Dict("max2" => smt))).status == :unsat
        # Minimality: max2's smallest ifelse solution has 6 nodes (ifelse, cmp,
        # x0, x1, x0, x1); 1-minimal shapes reachable from odd solutions can be
        # slightly larger, but far below the typical 15–25-node raw GP output.
        @test length(result.program.tree) <= 10
    end

    @testset "run_cdgp engine=:nsga2 (max2)" begin
        spec_path = find_spec_file("max2_simple")
        result = CEGIS.GeneticSearch.run_cdgp(
            spec_path; seed=1, pop_size=60, generations=100, generations_per_round=5,
            fitness=:hybrid, engine=:nsga2, minimize=true, verbose=false)

        @test result.solved
        @test result.program !== nothing
        spec = CG.parse_spec_from_file(spec_path)
        grammar = CEGIS.build_grammar_from_spec(spec_path)
        smt = CG.rulenode_to_smt2(result.program.tree, grammar)
        @test CG.verify_query(CG.generate_cex_query(spec, Dict("max2" => smt))).status == :unsat

        # nsga2 without hybrid fitness is rejected.
        @test_throws ArgumentError CEGIS.GeneticSearch.run_cdgp(
            spec_path; fitness=:tests, engine=:nsga2)
    end

    @testset "minimize_program shrinks a bloated verified program" begin
        spec_path = find_spec_file("max2_simple")
        spec = CG.parse_spec_from_file(spec_path)
        grammar = CEGIS.build_grammar_from_spec(spec_path)
        e = CEGIS.GeneticSearch.CDGPEvaluator(spec, grammar, :Expr, 4)
        verify = CEGIS.GeneticSearch._minimize_verifier(e)

        ix0 = _var_rule(grammar, :x0)
        ix1 = _var_rule(grammar, :x1)
        igt = _call_rule(grammar, :>)
        iif = _call_rule(grammar, :ifelse)
        iplus = _call_rule(grammar, :+)
        imul = _call_rule(grammar, :*)
        i0 = findfirst(==(0), grammar.rules)
        i1 = findfirst(==(1), grammar.rules)
        @test iplus !== nothing && imul !== nothing && i0 !== nothing && i1 !== nothing

        # ifelse(x0 > x1, 0 + x0, x1 * 1) — a real benchmark output shape.
        bloated = RuleNode(iif, [
            RuleNode(igt, [RuleNode(ix0), RuleNode(ix1)]),
            RuleNode(iplus, [RuleNode(i0), RuleNode(ix0)]),
            RuleNode(imul, [RuleNode(ix1), RuleNode(i1)]),
        ])
        @test verify(bloated)

        shrunk = CEGIS.GeneticSearch.minimize_program(bloated, grammar, verify)
        @test verify(shrunk)
        @test length(shrunk) < length(bloated)
        @test length(shrunk) == 6   # ifelse(x0 > x1, x0, x1)
        @test string(rulenode2expr(shrunk, grammar)) ==
              string(rulenode2expr(RuleNode(iif, [
                  RuleNode(igt, [RuleNode(ix0), RuleNode(ix1)]),
                  RuleNode(ix0), RuleNode(ix1)]), grammar))

        # A non-verifying program is returned untouched.
        junk = RuleNode(iplus, [RuleNode(ix0), RuleNode(ix1)])
        @test CEGIS.GeneticSearch.minimize_program(junk, grammar, verify) === junk
    end
end
