"""
Tests for complete vs incomplete tests (`src/GeneticSearch/incomplete_tests.jl`).

A counterexample's output may only be demanded of later candidates when it is
the one output the spec accepts at that input. These tests pin down the three
things that must hold for the multi-answer benchmark tier to mean anything:

  - the Z3 primitives tell single-answer from multi-answer, per spec and per input;
  - on a multi-answer spec both evaluators keep the input only, and EVERY correct
    program — not just the one Z3 happened to describe — passes those tests and
    is accepted;
  - on a single-answer spec nothing changes: no per-test query, no incomplete
    test, and a run is identical to the legacy behaviour.
"""

import Arborist
using HerbGrammar: expr2rulenode

const _MA = joinpath(@__DIR__, "..", "spec_files", "multi_answer")
const _CG = CEGIS.CEXGeneration
const _GS = CEGIS.GeneticSearch

"""Parse a multi-answer spec and build its own (SyGuS) grammar."""
function _ma_setup(name)
    spec = _CG.parse_spec_from_file(joinpath(_MA, name * ".sl"))
    grammar = CEGIS.GrammarBuilding.build_grammar_from_sygus(spec)
    return spec, grammar
end

_ma_genome(ex, grammar) = _GS.RuleNodeGenome(
    ex isa Number ? expr2rulenode(ex, grammar) : expr2rulenode(ex, grammar, :Expr), grammar, :Expr)

const _MAX3 = :(ifelse(x >= y, ifelse(x >= z, x, z), ifelse(y >= z, y, z)))

"""A spec written inline to a temp file (don't-care region control)."""
function _inline_spec(body)
    p = tempname() * ".sl"
    write(p, body)
    return _CG.parse_spec_from_file(p)
end

@testset "Incomplete tests" verbose = true begin

    @testset "Z3 primitives: single-answer per spec and per input" begin
        # Single-answer controls.
        for p in (find_spec_file("max2_simple"), find_spec_file("max5_simple"))
            @test _CG.spec_single_answer(_CG.parse_spec_from_file(p)) === true
        end

        spec, _ = _ma_setup("max3_slack")
        cs = _CG.CexSolver(spec; timeout_ms=5_000, nl_arith=false)
        @test _CG.spec_single_answer(spec) === false
        b = Dict{String,Any}("x" => 3, "y" => 7, "z" => -1)
        # Both 7 (the max) and 8 (max + 1) are valid at this input…
        @test _CG.output_is_unique(cs, b, 7) === false
        @test _CG.output_is_unique(cs, b, 8) === false
        v = _CG.complete_output(cs, b)
        @test v in (7, 8)

        # avoid2 is mixed: at (0, 1) only 2 is valid, at (5, 9) three values are.
        spec, _ = _ma_setup("avoid2")
        cs = _CG.CexSolver(spec; timeout_ms=5_000, nl_arith=false)
        @test _CG.output_is_unique(cs, Dict{String,Any}("x" => 0, "y" => 1), 2) === true
        @test _CG.output_is_unique(cs, Dict{String,Any}("x" => 5, "y" => 9), 0) === false

        # Counted as their own kind of Z3 work.
        z0 = _CG.z3_stats()
        _CG.output_is_unique(cs, Dict{String,Any}("x" => 0, "y" => 1), 2)
        d = _CG.z3_stats_diff(_CG.z3_stats(), z0)
        @test d.output_unique == 1 && d.total == 1
    end

    @testset "CDGPEvaluator: multi-answer counterexamples become incomplete tests" begin
        spec, grammar = _ma_setup("max3_slack")
        e = _GS.CDGPEvaluator(spec, grammar, :Expr, 4)
        @test e.completion.single_answer === false
        @test e.completion.pointwise

        wrong = _ma_genome(:x, grammar)
        @test Arborist.evaluate_genome(wrong, e) >= 1.0
        @test isempty(e.test_cases)
        @test length(e.incomplete) == 1
        @test e.counterexamples[1].expected_output === nothing
        st = _GS.completion_stats(e.completion)
        @test st.incomplete == 1 && st.complete == 0 && st.unique_checks == 1 && st.unchecked == 0

        # Lexicase cases: one per incomplete test, then the parsimony case.
        cases = Arborist.evaluate_cases(wrong, e)
        @test length(cases) == 2 && cases[1] == 1.0

        # Two DIFFERENT correct programs — the max and max + 1 — both pass the
        # incomplete test; a complete test could only ever admit one of them.
        for ex in (_MAX3, :($_MAX3 + 1))
            g = _ma_genome(ex, grammar)
            @test Arborist.evaluate_cases(g, e)[1] == 0.0
        end
        # …and a verified one is accepted.
        e2 = _GS.CDGPEvaluator(spec, grammar, :Expr, 4)
        Arborist.evaluate_genome(wrong, e2)
        plus1 = _ma_genome(:($_MAX3 + 1), grammar)
        @test Arborist.evaluate_genome(plus1, e2) == 0.0
        @test e2.solved !== nothing
    end

    @testset "CDGPEvaluator: legacy mode keeps the solver's output (ablation)" begin
        spec, grammar = _ma_setup("max3_slack")
        e = _GS.CDGPEvaluator(spec, grammar, :Expr, 4; incomplete_tests=false)
        @test e.completion.single_answer === nothing   # not even checked
        Arborist.evaluate_genome(_ma_genome(:x, grammar), e)
        @test length(e.test_cases) == 1 && isempty(e.incomplete)
        @test e.completion.unchecked == 1
        # The legacy test demands one specific output, so exactly one of the two
        # correct programs fails it — the unsoundness incomplete tests remove.
        io = e.test_cases[1]
        outs = [execute_on_input(e.symboltable,
                    rulenode2expr(_ma_genome(ex, grammar).tree, grammar), io.in)
                for ex in (_MAX3, :($_MAX3 + 1))]
        @test count(==(io.out), outs) == 1
    end

    @testset "CDGPEvaluator: mixed spec gives both kinds" begin
        spec, grammar = _ma_setup("avoid2")
        # Each candidate on a fresh evaluator, so each is verified against an
        # empty test set. The verification script records `ifelse(x == 0, 1, 0)`
        # refuted at (0, 1), where only 2 is valid, and `1` at (1, 3), where 0
        # and 2 both are.
        kinds = Symbol[]
        for ex in (:(ifelse(x == 0, 1, 0)), :(1), :(x + 1), :(0))
            e = _GS.CDGPEvaluator(spec, grammar, :Expr, 4)
            Arborist.evaluate_genome(_ma_genome(ex, grammar), e)
            cs = e.cex_solver
            # Every test is of the kind its input warrants.
            for io in e.test_cases
                b = Dict{String,Any}(String(k) => v for (k, v) in io.in)
                @test _CG.output_is_unique(cs, b, io.out) === true
                push!(kinds, :complete)
            end
            for b in e.incomplete
                v = _CG.complete_output(cs, b)
                @test v !== nothing && _CG.output_is_unique(cs, b, v) === false
                push!(kinds, :incomplete)
            end
        end
        @test :complete in kinds && :incomplete in kinds
    end

    @testset "don't-care region: not single-answer, yet every test stays complete" begin
        spec = _inline_spec("""
            (set-logic LIA)
            (synth-fun f ((x Int) (y Int)) Int)
            (declare-var x Int)
            (declare-var y Int)
            (constraint (=> (>= x 0) (= (f x y) (+ x y))))
            (check-synth)
            """)
        cs = _CG.CexSolver(spec; timeout_ms=5_000, nl_arith=false)
        @test _CG.spec_single_answer(spec) === false
        # Counterexamples only arise where x ≥ 0, and there the output is forced.
        @test _CG.output_is_unique(cs, Dict{String,Any}("x" => 2, "y" => 3), 5) === true
        @test _CG.output_is_unique(cs, Dict{String,Any}("x" => -2, "y" => 3), 1) === false
    end

    @testset "single-answer spec: behaviour identical to legacy" begin
        spec_path = find_spec_file("max2_simple")
        spec = _CG.parse_spec_from_file(spec_path)
        grammar = CEGIS.build_grammar_from_spec(spec_path)
        e = _GS.CDGPEvaluator(spec, grammar, :Expr, 4)
        @test e.completion.single_answer === true
        Arborist.evaluate_genome(_GS.RuleNodeGenome(RuleNode(findfirst(==(:x0), grammar.rules)), grammar, :Expr), e)
        @test length(e.test_cases) == 1 && isempty(e.incomplete)
        @test e.completion.unique_checks == 0 && e.completion.unchecked == 0

        # A whole run, both ways: same tests, same program, same generation.
        kw = (pop_size=100, generations=60, verbose=false, selection=Arborist.LexicaseSelection())
        for seed in 1:3
            a = _GS.run_cdgp(spec_path; kw..., seed=seed)
            b = _GS.run_cdgp(spec_path; kw..., seed=seed, incomplete_tests=false)
            @test a.solved == b.solved && a.expr == b.expr && a.generations == b.generations
            @test [(t.in, t.out) for t in a.test_cases] == [(t.in, t.out) for t in b.test_cases]
            @test isempty(a.incomplete_tests) && a.completion.single_answer === true
        end
    end

    @testset "HybridCDGPEvaluator: harvest respects uniqueness" begin
        spec, grammar = _ma_setup("max3_slack")
        e = _GS.HybridCDGPEvaluator(spec, grammar, :Expr, 4)
        @test e.completion.single_answer === false
        # A test-perfect (the set is empty) violating genome is checked and its
        # witness harvested — as an incomplete test.
        Arborist.evaluate_genome(_ma_genome(:x, grammar), e)
        @test isempty(e.test_cases)
        @test length(e.incomplete) == 1
        @test e.harvested == 1
        # Case vector: incomplete test, then witnesses, then parsimony.
        g = _ma_genome(_MAX3, grammar)
        cases = Arborist.evaluate_cases(g, e)
        @test length(cases) == 1 + length(e.witness_bank) + 1
        @test all(==(0.0), cases[1:end-1])
        @test Arborist.evaluate_genome(_ma_genome(:($_MAX3 + 1), grammar), e) == 0.0
        @test e.solved !== nothing
    end

    @testset "run_cdgp end-to-end on a multi-answer spec" begin
        path = joinpath(_MA, "max3_slack.sl")
        spec, grammar = _ma_setup("max3_slack")
        for fit in (:tests, :hybrid)
            tr = _GS.CDGPTrace()
            res = _GS.run_cdgp(path; fitness=fit, grammar=grammar, start_symbol=:Expr,
                           pop_size=200, generations=300, max_depth=5, depth_cap=8,
                           selection=Arborist.LexicaseSelection(), seed=1,
                           verbose=false, trace=tr)
            @test res.solved
            @test isempty(res.test_cases)                 # every test incomplete
            @test res.completion.incomplete == length(res.incomplete_tests) > 0
            @test res.completion.single_answer === false
            # The trace sees them: tests counts both kinds, incomplete the subset.
            @test tr.tests[end] == tr.incomplete_tests[end] > 0
            @test tr.incomplete_tests[end] <= length(res.incomplete_tests)
            # The spec-level query runs at evaluator construction, before the
            # trace's Z3 baseline; the per-test queries are all in the trace.
            @test 0 < tr.z3_output_unique[end] <= res.completion.unique_checks
            # Independent verification of the answer.
            smt = _CG.rulenode_to_smt2(res.program.tree, grammar)
            q = _CG.generate_cex_query(spec, Dict(spec.synth_funs[1].name => smt))
            @test _CG.verify_query(q).status == :unsat
        end
    end
end
