"""
Tests for the per-constraint counterexample mode of `CDGPEvaluator`
(`cex_mode=:per_constraint`): one verification checks every constraint
separately and turns each violated constraint's witness into a test.

What must hold for the mode to mean anything, and for `CexHarvest` to be a
faithful record of it:
  - one verification of a genome that violates k constraints yields k witnesses,
    and every test added from them fails that genome;
  - the counters add up (added + dup + capped = witnesses) and match the Z3 calls
    actually made;
  - multi-answer specs get incomplete tests through the same policy as `:single`;
  - a correct program is still accepted, and specs outside the in-process scope
    fall back to `:single` visibly.
"""

import Arborist
using HerbGrammar: expr2rulenode

const _PC_GS = CEGIS.GeneticSearch
const _PC_CG = CEGIS.CEXGeneration

function _pc_generated(name)
    spec_path = find_spec_file(name)
    return spec_path, _PC_CG.parse_spec_from_file(spec_path), CEGIS.build_grammar_from_spec(spec_path)
end

_pc_var(grammar, s) = _PC_GS.RuleNodeGenome(RuleNode(findfirst(==(s), grammar.rules)), grammar, :Expr)

@testset "Per-constraint counterexamples" verbose = true begin

    @testset "one verification, one test per violated constraint (max5)" begin
        _, spec, grammar = _pc_generated("max5_simple")
        e = _PC_GS.CDGPEvaluator(spec, grammar, :Expr, 4; cex_mode=:per_constraint)
        @test e.cex_mode === :per_constraint && e.css !== nothing

        z0 = _PC_CG.z3_stats()
        f = Arborist.evaluate_genome(_pc_var(grammar, :x0), e)
        d = _PC_CG.z3_stats_diff(_PC_CG.z3_stats(), z0)
        h = _PC_GS.harvest_stats(e.harvest)

        # `x0` violates `max5 ≥ x_i` for i = 1..4 and satisfies the `or` constraint.
        @test e.verifications == 1
        @test h.events == 1 && h.witnesses == 4
        @test h.added + h.dup + h.capped == h.witnesses
        @test h.added >= 2 && h.multi_events == 1 && h.max_per_event == h.added
        # Single-answer spec: every harvested test is complete and correct.
        @test length(e.test_cases) == h.added && isempty(e.incomplete)
        @test all(io -> io.out == maximum(values(io.in)), e.test_cases)
        # Every added test fails the genome that produced it.
        @test f == Float64(h.added)
        # Z3 work: one check per constraint, one completion per new input, no
        # whole-spec counterexample query.
        @test d.constraint_checks == length(spec.constraints)
        @test d.complete_output == h.witnesses - h.dup - h.capped
        @test d.cex_queries == 0
    end

    @testset "correct program accepted; default mode untouched (max2)" begin
        _, spec, grammar = _pc_generated("max2_simple")
        e = _PC_GS.CDGPEvaluator(spec, grammar, :Expr, 4; cex_mode=:per_constraint)
        Arborist.evaluate_genome(_pc_var(grammar, :x0), e)
        @test !isempty(e.test_cases) && e.solved === nothing
        correct = _PC_GS.RuleNodeGenome(expr2rulenode(:(ifelse(x0 > x1, x0, x1)), grammar, :Expr),
                                        grammar, :Expr)
        @test Arborist.evaluate_genome(correct, e) == 0.0
        @test e.solved !== nothing

        d = _PC_GS.CDGPEvaluator(spec, grammar, :Expr, 4)
        @test d.cex_mode === :single && d.css === nothing
        @test_throws ArgumentError _PC_GS.CDGPEvaluator(spec, grammar, :Expr, 4; cex_mode=:bogus)
    end

    @testset "max_new_tests caps the harvest" begin
        _, spec, grammar = _pc_generated("max5_simple")
        e = _PC_GS.CDGPEvaluator(spec, grammar, :Expr, 4; cex_mode=:per_constraint, max_new_tests=1)
        Arborist.evaluate_genome(_pc_var(grammar, :x0), e)
        h = _PC_GS.harvest_stats(e.harvest)
        @test h.added == 1 && length(e.test_cases) == 1
        @test h.capped + h.dup == h.witnesses - 1 && h.multi_events == 0
    end

    @testset "multi-answer spec: harvested tests are incomplete" begin
        spec = _PC_CG.parse_spec_from_file(joinpath(@__DIR__, "..", "spec_files", "multi_answer", "max4_slack.sl"))
        grammar = CEGIS.GrammarBuilding.build_grammar_from_sygus(spec)
        e = _PC_GS.CDGPEvaluator(spec, grammar, :Expr, 4; cex_mode=:per_constraint)
        g = _PC_GS.RuleNodeGenome(expr2rulenode(:w, grammar, :Expr), grammar, :Expr)
        Arborist.evaluate_genome(g, e)
        h = _PC_GS.harvest_stats(e.harvest)
        # `w` violates `≥ x`, `≥ y`, `≥ z`; the [max, max+1] window holds for it.
        @test h.witnesses == 3
        @test isempty(e.test_cases) && length(e.incomplete) == h.added >= 2
        @test e.completion.incomplete == h.added
        # Both correct answers pass every harvested test.
        mx = :(ifelse(ifelse(w >= x, w, x) >= ifelse(y >= z, y, z), ifelse(w >= x, w, x), ifelse(y >= z, y, z)))
        for ex in (mx, :($mx + 1))
            cases = Arborist.evaluate_cases(_PC_GS.RuleNodeGenome(expr2rulenode(ex, grammar, :Expr), grammar, :Expr), e)
            @test all(==(0.0), cases[1:end-1])
        end
    end

    @testset "out-of-scope spec falls back to :single, visibly" begin
        # A preamble helper (define-fun) puts the spec outside the in-process solvers.
        spec_path, spec, grammar = _pc_generated("simple_define_sum")
        e = _PC_GS.CDGPEvaluator(spec, grammar, :Expr, 4; cex_mode=:per_constraint)
        h = _PC_GS.harvest_stats(e.harvest)
        @test e.cex_mode === :single && e.css === nothing
        @test h.requested === :per_constraint && h.mode === :single && h.fallback
    end

    @testset "run_cdgp end-to-end (max3)" begin
        spec_path, spec, grammar = _pc_generated("max3_simple")
        for seed in 1:2
            res = _PC_GS.run_cdgp(spec_path; cex_mode=:per_constraint, seed=seed, verbose=false,
                                   pop_size=200, generations=300, max_depth=5, depth_cap=8,
                                   selection=Arborist.LexicaseSelection())
            @test res.solved
            @test res.harvest.mode === :per_constraint && !res.harvest.fallback
            @test res.harvest.events >= 1
            @test res.harvest.added == length(res.test_cases) + length(res.incomplete_tests)
            smt = _PC_CG.rulenode_to_smt2(res.program.tree, grammar)
            q = _PC_CG.generate_cex_query(spec, Dict(spec.synth_funs[1].name => smt))
            @test _PC_CG.verify_query(q).status == :unsat
        end
        @test_throws ArgumentError _PC_GS.run_cdgp(spec_path; fitness=:hybrid, cex_mode=:per_constraint,
                                                   verbose=false, generations=10)
    end
end
