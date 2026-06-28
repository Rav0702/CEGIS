"""
Tests for CDGP (Counterexample-Driven Genetic Programming).

Covers the `CDGPEvaluator` test-set/verification mechanics directly, and the
full `run_cdgp` loop end-to-end on the max2 benchmark with independent
re-verification of the result.
"""

import Arborist

"""Find the grammar rule index of a variable symbol (e.g. `:x0`)."""
_var_rule(grammar, sym::Symbol) = findfirst(==(sym), grammar.rules)

"""Find the grammar rule index of a call rule by operator (e.g. `:ifelse`, `:>`)."""
_call_rule(grammar, op::Symbol) =
    findfirst(r -> r isa Expr && r.head == :call && r.args[1] == op, grammar.rules)

@testset "CDGP" verbose = true begin

    @testset "CDGPEvaluator mechanics (max2)" begin
        spec_path = find_spec_file("max2_simple")
        spec = CEGIS.CEXGeneration.parse_spec_from_file(spec_path)
        grammar = CEGIS.build_grammar_from_spec(spec_path)
        evaluator = CEGIS.GeneticSearch.CDGPEvaluator(spec, grammar, :Expr, 4)

        ix0 = _var_rule(grammar, :x0)
        ix1 = _var_rule(grammar, :x1)
        igt = _call_rule(grammar, :>)
        iif = _call_rule(grammar, :ifelse)
        @test ix0 !== nothing && ix1 !== nothing && igt !== nothing && iif !== nothing

        # Wrong candidate `x0`: passes the (empty) test set, so it gets
        # verified — Z3 must find a counterexample that becomes the first test.
        wrong = CEGIS.GeneticSearch.RuleNodeGenome(RuleNode(ix0), grammar, :Expr)
        f_wrong = Arborist.evaluate_genome(wrong, evaluator)
        @test f_wrong >= 1.0
        @test length(evaluator.test_cases) == 1
        @test length(evaluator.counterexamples) == 1
        @test evaluator.verifications == 1
        @test evaluator.solved === nothing
        # The counterexample test is spec-consistent: expected output is the max.
        io = evaluator.test_cases[1]
        @test io.out == max(io.in[:x0], io.in[:x1])

        # Re-evaluation hits the cache, no extra Z3 call.
        @test Arborist.evaluate_genome(wrong, evaluator) == f_wrong
        @test evaluator.verifications == 1

        # Correct candidate `ifelse(x0 > x1, x0, x1)`: passes the test, gets
        # verified, and is recorded as solved with fitness 0.
        correct = CEGIS.GeneticSearch.RuleNodeGenome(
            RuleNode(iif, [
                RuleNode(igt, [RuleNode(ix0), RuleNode(ix1)]),
                RuleNode(ix0),
                RuleNode(ix1),
            ]),
            grammar, :Expr)
        f_correct = Arborist.evaluate_genome(correct, evaluator)
        @test f_correct == 0.0
        @test evaluator.solved !== nothing
        @test evaluator.verifications == 2
        @test length(evaluator.test_cases) == 1  # no new test on success
    end

    @testset "evaluate_cases mechanics (max2)" begin
        spec_path = find_spec_file("max2_simple")
        spec = CEGIS.CEXGeneration.parse_spec_from_file(spec_path)
        grammar = CEGIS.build_grammar_from_spec(spec_path)
        evaluator = CEGIS.GeneticSearch.CDGPEvaluator(spec, grammar, :Expr, 4)

        ix0 = _var_rule(grammar, :x0)
        ix1 = _var_rule(grammar, :x1)
        igt = _call_rule(grammar, :>)
        iif = _call_rule(grammar, :ifelse)

        # Empty test set ⇒ empty case vector (lexicase falls back to random).
        wrong = CEGIS.GeneticSearch.RuleNodeGenome(RuleNode(ix0), grammar, :Expr)
        @test Arborist.evaluate_cases(wrong, evaluator) == Float64[]

        # Grow the test set to one counterexample via the scalar path.
        Arborist.evaluate_genome(wrong, evaluator)
        @test length(evaluator.test_cases) == 1
        verifs = evaluator.verifications

        # The wrong genome `x0` fails the max counterexample.
        cv_wrong = Arborist.evaluate_cases(wrong, evaluator)
        @test length(cv_wrong) == length(evaluator.test_cases)
        @test any(==(1.0), cv_wrong)

        # The correct genome passes every accumulated test (all zero losses).
        correct = CEGIS.GeneticSearch.RuleNodeGenome(
            RuleNode(iif, [
                RuleNode(igt, [RuleNode(ix0), RuleNode(ix1)]),
                RuleNode(ix0),
                RuleNode(ix1),
            ]),
            grammar, :Expr)
        cv_correct = Arborist.evaluate_cases(correct, evaluator)
        @test length(cv_correct) == length(evaluator.test_cases)
        @test all(==(0.0), cv_correct)

        # Purity: evaluate_cases must not issue Z3 queries or grow the test set.
        @test evaluator.verifications == verifs
        @test length(evaluator.test_cases) == 1
        @test evaluator.solved === nothing
    end

    @testset "run_cdgp end-to-end with lexicase (max2)" begin
        spec_path = find_spec_file("max2_simple")

        result = CEGIS.GeneticSearch.run_cdgp(
            spec_path;
            seed=1,
            pop_size=100,
            generations=200,
            generations_per_round=10,
            selection=Arborist.LexicaseSelection(),
            verbose=false,
        )

        @test result.solved
        @test result.program !== nothing

        # Independently re-verify the returned program against the spec.
        spec = CEGIS.CEXGeneration.parse_spec_from_file(spec_path)
        grammar = CEGIS.build_grammar_from_spec(spec_path)
        smt = CEGIS.CEXGeneration.rulenode_to_smt2(result.program.tree, grammar)
        query = CEGIS.CEXGeneration.generate_cex_query(spec, Dict("max2" => smt))
        @test CEGIS.CEXGeneration.verify_query(query).status == :unsat
    end

    @testset "run_cdgp end-to-end (max2)" begin
        spec_path = find_spec_file("max2_simple")

        result = CEGIS.GeneticSearch.run_cdgp(
            spec_path;
            seed=1,
            pop_size=100,
            generations=200,
            generations_per_round=10,
            verbose=false,
        )

        @test result.solved
        @test result.program !== nothing
        @test result.verifications >= 1
        @test length(result.test_cases) == length(result.counterexamples)

        # Independently re-verify the returned program against the spec.
        spec = CEGIS.CEXGeneration.parse_spec_from_file(spec_path)
        grammar = CEGIS.build_grammar_from_spec(spec_path)
        smt = CEGIS.CEXGeneration.rulenode_to_smt2(result.program.tree, grammar)
        query = CEGIS.CEXGeneration.generate_cex_query(spec, Dict("max2" => smt))
        @test CEGIS.CEXGeneration.verify_query(query).status == :unsat
    end
end
