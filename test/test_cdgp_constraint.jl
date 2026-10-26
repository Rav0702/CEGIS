"""
Tests for constraint-graded CDGP (`CDGPConstraintEvaluator`,
`run_cdgp(...; fitness=:constraints)`).

Covers the evaluator mechanics (scalar fitness = universally violated
constraints, per-constraint case vector for lexicase, cache, solved detection)
and the full loop end-to-end on max2 under both tournament and lexicase
selection, with independent Z3 re-verification.
"""

import Arborist

@testset "Constraint-graded CDGP" verbose = true begin

    @testset "CDGPConstraintEvaluator mechanics (max2)" begin
        spec_path = find_spec_file("max2_simple")
        spec = CEGIS.CEXGeneration.parse_spec_from_file(spec_path)
        grammar = CEGIS.build_grammar_from_spec(spec_path)
        evaluator = CEGIS.GeneticSearch.CDGPConstraintEvaluator(spec, grammar, :Expr, 4)
        @test evaluator.n_constraints == 3

        ix0 = _var_rule(grammar, :x0)
        ix1 = _var_rule(grammar, :x1)
        igt = _call_rule(grammar, :>)
        iif = _call_rule(grammar, :ifelse)
        @test ix0 !== nothing && ix1 !== nothing && igt !== nothing && iif !== nothing

        # `x0` holds constraints 1 and 3 universally, violates constraint 2.
        wrong = CEGIS.GeneticSearch.RuleNodeGenome(RuleNode(ix0), grammar, :Expr)
        @test Arborist.evaluate_genome(wrong, evaluator) == 1.0
        @test Arborist.evaluate_cases(wrong, evaluator) == [0.0, 1.0, 0.0]
        @test evaluator.solved === nothing
        checks = evaluator.z3_checks
        @test checks == evaluator.n_constraints  # one session, served both calls

        # Repeat evaluations hit the status cache — no extra Z3 work.
        Arborist.evaluate_genome(wrong, evaluator)
        Arborist.evaluate_cases(wrong, evaluator)
        @test evaluator.z3_checks == checks

        # Correct candidate: zero violations everywhere, recorded as solved.
        correct = CEGIS.GeneticSearch.RuleNodeGenome(
            RuleNode(iif, [
                RuleNode(igt, [RuleNode(ix0), RuleNode(ix1)]),
                RuleNode(ix0),
                RuleNode(ix1),
            ]),
            grammar, :Expr)
        @test Arborist.evaluate_genome(correct, evaluator) == 0.0
        @test Arborist.evaluate_cases(correct, evaluator) == [0.0, 0.0, 0.0]
        @test evaluator.solved !== nothing
    end

    @testset "run_cdgp fitness=:constraints with tournament (max2)" begin
        spec_path = find_spec_file("max2_simple")

        # Scalar constraint fitness has only n_constraints+1 levels, so under
        # tournament selection the population regularly plateaus (benchmarks:
        # solved max2 sometimes, stalled at fitness 1 other times) — solving is
        # NOT a reliable property of this config. Assert the loop mechanics and
        # result invariants; only verify a solution when one is claimed.
        result = CEGIS.GeneticSearch.run_cdgp(
            spec_path;
            seed=1,
            pop_size=40,
            generations=100,
            generations_per_round=5,
            fitness=:constraints,
            verbose=false,
        )

        @test result isa CEGIS.GeneticSearch.CDGPResult
        @test result.rounds >= 1
        @test result.generations >= result.rounds
        @test result.verifications >= 1
        @test isempty(result.test_cases)      # no test set in constraint mode
        @test isempty(result.counterexamples)
        @test result.program !== nothing

        if result.solved
            spec = CEGIS.CEXGeneration.parse_spec_from_file(spec_path)
            grammar = CEGIS.build_grammar_from_spec(spec_path)
            smt = CEGIS.CEXGeneration.rulenode_to_smt2(result.program.tree, grammar)
            query = CEGIS.CEXGeneration.generate_cex_query(spec, Dict("max2" => smt))
            @test CEGIS.CEXGeneration.verify_query(query).status == :unsat
        end
    end

    @testset "run_cdgp fitness=:constraints with lexicase (max2)" begin
        spec_path = find_spec_file("max2_simple")

        result = CEGIS.GeneticSearch.run_cdgp(
            spec_path;
            seed=1,
            pop_size=40,
            generations=100,
            generations_per_round=5,
            fitness=:constraints,
            selection=Arborist.LexicaseSelection(),
            verbose=false,
        )

        @test result.solved
        @test result.program !== nothing

        spec = CEGIS.CEXGeneration.parse_spec_from_file(spec_path)
        grammar = CEGIS.build_grammar_from_spec(spec_path)
        smt = CEGIS.CEXGeneration.rulenode_to_smt2(result.program.tree, grammar)
        query = CEGIS.CEXGeneration.generate_cex_query(spec, Dict("max2" => smt))
        @test CEGIS.CEXGeneration.verify_query(query).status == :unsat
    end

    @testset "run_cdgp rejects an unknown fitness mode" begin
        spec_path = find_spec_file("max2_simple")
        @test_throws ArgumentError CEGIS.GeneticSearch.run_cdgp(spec_path; fitness=:bogus)
    end
end
