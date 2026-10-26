"""
Tests for benchmark instrumentation: process-wide Z3 call accounting
(`z3_stats`), the per-generation `CDGPTrace`, and the `ValidationBattery` used
for fitness-over-generations plots.
"""

import Arborist

@testset "Instrumentation: Z3 accounting, CDGPTrace, ValidationBattery" verbose = true begin
    CG = CEGIS.CEXGeneration
    GS = CEGIS.GeneticSearch

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

    @testset "z3_stats counts every call site, by kind" begin
        spec = _max2_spec()
        css = CG.ConstraintSatSolver(spec; timeout_ms=2_000, nl_arith=false)
        cs = CG.CexSolver(spec; timeout_ms=2_000, nl_arith=false)

        before = CG.z3_stats()
        CG.check_constraint_satisfaction(css, "max2", "x0")
        d = CG.z3_stats_diff(CG.z3_stats(), before)
        @test d.constraint_checks == 3          # one check-sat-assuming per constraint
        @test d.cex_queries == 0 && d.complete_output == 0 && d.subprocess == 0

        before = CG.z3_stats()
        CG.find_counterexample(cs, Dict("max2" => "x0"))
        d = CG.z3_stats_diff(CG.z3_stats(), before)
        @test d.cex_queries == 1 && d.constraint_checks == 0

        before = CG.z3_stats()
        CG.complete_output(cs, Dict{String,Any}("x0" => 3, "x1" => 9))
        d = CG.z3_stats_diff(CG.z3_stats(), before)
        @test d.complete_output == 1

        before = CG.z3_stats()
        CG.verify_query(CG.generate_cex_query(spec, Dict("max2" => "x0")))
        d = CG.z3_stats_diff(CG.z3_stats(), before)
        @test d.subprocess == 1

        @test d.total == d.constraint_checks + d.cex_queries + d.complete_output + d.subprocess
        @test d.time_s >= 0.0
    end

    @testset "ValidationBattery is deterministic and scores against the spec" begin
        spec = CG.parse_spec_from_file(find_spec_file("max2_simple"))
        grammar = CEGIS.build_grammar_from_spec(find_spec_file("max2_simple"))

        vb1 = GS.ValidationBattery(spec, grammar; n=64, seed=7)
        vb2 = GS.ValidationBattery(spec, grammar; n=64, seed=7)
        vb3 = GS.ValidationBattery(spec, grammar; n=64, seed=8)
        @test vb1.inputs == vb2.inputs            # same seed ⇒ identical battery
        @test vb1.inputs != vb3.inputs
        @test length(vb1) == 64
        # First half dense in ties/sign changes, second half wide.
        @test all(abs(v) <= 3 for w in vb1.inputs[1:32] for v in values(w))

        # A correct program scores 1.0 on both measures; a partial one does not.
        genome(expr) = GS.RuleNodeGenome(
            HerbGrammar.expr2rulenode(expr, grammar, :Expr), grammar, :Expr)
        correct = genome(:(ifelse(x0 >= x1, x0, x1)))
        partial = genome(:x0)
        sc = GS.validation_scores(vb1, correct)
        sp = GS.validation_scores(vb1, partial)
        @test sc.acc == 1.0 && sc.pairs == 1.0
        @test 0.0 < sp.acc < 1.0                  # right exactly where x0 is the max
        # `x0` always satisfies bound 1 and the disjunction, so pairs sits well above acc.
        @test sp.pairs > sp.acc
    end

    @testset "acc is invariant to specification style; pairs is not" begin
        paired_ours = joinpath(CEGIS_ROOT, "spec_files", "paired", "ours", "median3.sl")
        paired_cdgp = joinpath(CEGIS_ROOT, "spec_files", "paired", "cdgp", "median3.sl")
        if !(isfile(paired_ours) && isfile(paired_cdgp))
            @test_skip "paired median3 specs not present"
        else
            so = CG.parse_spec_from_file(paired_ours)
            sc = CG.parse_spec_from_file(paired_cdgp)
            g = CEGIS.GrammarBuilding.build_grammar_from_sygus(so)
            vo = GS.ValidationBattery(so, g; n=128, seed=11)
            vc = GS.ValidationBattery(sc, g; n=128, seed=11)
            @test vo.inputs == vc.inputs          # same free vars ⇒ same battery
            wrong = GS.RuleNodeGenome(HerbGrammar.expr2rulenode(:x, g, :Expr), g, :Expr)
            a = GS.validation_scores(vo, wrong)
            b = GS.validation_scores(vc, wrong)
            @test a.acc == b.acc                  # pointwise-equivalent specs agree per input
            # The six-way split floors `pairs` near 5/6: guards that are false hold vacuously.
            @test b.pairs > 0.8 && b.pairs > a.pairs
        end
    end

    @testset "run_cdgp records a consistent per-generation trace" begin
        spec_path = find_spec_file("max2_simple")
        tr = GS.CDGPTrace()
        z0 = CG.z3_stats()
        wall = @elapsed res = GS.run_cdgp(spec_path; seed=3, verbose=false, pop_size=60,
                          generations=200, generations_per_round=10,
                          max_depth=4, depth_cap=6, fitness=:hybrid,
                          selection=Arborist.LexicaseSelection(), trace=tr)
        zrun = CG.z3_stats_diff(CG.z3_stats(), z0)
        n = length(tr)

        @test n == res.generations                # one entry per generation actually run
        @test tr.gen == collect(1:n)              # global numbering across rounds
        @test issorted(tr.elapsed_s)
        # A run that stops at a solve mid-round has no result for that round, so
        # it has no population-stats entry and its generations keep NaN means.
        @test length(tr.round_end_gen) == res.rounds - tr.stopped_early
        @test tr.stopped_early || tr.round_end_gen[end] == n
        completed = isempty(tr.round_end_gen) ? 0 : tr.round_end_gen[end]
        @test all(!isnan, tr.mean_fitness[1:completed])   # every completed round's means
        @test all(k -> haskey(tr.genomes, k), tr.best_key)

        # Cumulative counters never decrease, and stay within what the run spent.
        for f in (:z3_constraint_checks, :z3_cex_queries, :z3_complete_output, :z3_subprocess)
            @test issorted(getfield(tr, f))
        end
        @test tr.z3_constraint_checks[end] <= zrun.constraint_checks
        @test tr.z3_constraint_checks[end] > 0

        # The solve flag is monotone and agrees with the result.
        @test issorted(tr.solved)
        @test (tr.solve_gen > 0) == res.solved
        if res.solved
            # The run ends AT the solve, not at the end of the round: the solving
            # generation is the last one recorded.
            @test tr.solve_gen == n == res.generations
            # A verified program scores 0 on the evaluator, so its fitness is the
            # bloat term alone (default bloat_penalty = 1e-3).
            @test res.best_fitness ≈ 1e-3 * length(res.program.tree)
            @test tr.solved[tr.solve_gen] && (tr.solve_gen == 1 || !tr.solved[tr.solve_gen-1])
            # A solve found by the round's final offspring is caught at round end,
            # after that generation's callback — so it is at or after that
            # generation's timestamp, never before, and inside the run.
            @test tr.solve_elapsed_s >= tr.elapsed_s[tr.solve_gen]
            @test tr.solve_elapsed_s <= wall

            # Integrity check: a formally verified program must score 1.0 on the
            # battery. Anything less means the pointwise evaluator and the SMT
            # encoding disagree about the spec's semantics.
            spec = CG.parse_spec_from_file(spec_path)
            grammar = CEGIS.build_grammar_from_spec(spec_path)
            vb = GS.ValidationBattery(spec, grammar; n=128)
            @test GS.validation_scores(vb, res.program).acc == 1.0
            vals = GS.trace_validation(tr, vb)
            @test length(vals) == length(tr.genomes)
            @test all(0.0 <= v.acc <= 1.0 for v in values(vals))
        end
    end

    @testset "run_cdgp stops at the solving generation" begin
        # A solve found mid-round must end the run at that generation; before this
        # the round ran on, wasting up to generations_per_round - 1 generations.
        spec_path = find_spec_file("max2_simple")
        stopped = 0
        solved = 0
        for seed in 1:8
            tr = GS.CDGPTrace()
            res = GS.run_cdgp(spec_path; seed=seed, verbose=false, pop_size=60,
                              generations=200, generations_per_round=10,
                              max_depth=4, depth_cap=6, fitness=:hybrid,
                              selection=Arborist.LexicaseSelection(), trace=tr)
            res.solved || continue
            solved += 1
            stopped += tr.stopped_early
            @test tr.solve_gen == length(tr) == res.generations
            # A run that did not stop early completed its last round. (The converse
            # does not hold: a stop at a round's 10th-generation callback is
            # mid-round yet lands on a multiple of 10.)
            @test tr.stopped_early || res.generations % 10 == 0
        end
        @test solved >= 4
        @test stopped >= 1        # the mid-round stop path was actually exercised
    end

    @testset "trace is observation only" begin
        spec_path = find_spec_file("max2_simple")
        kw = (seed=5, verbose=false, pop_size=60, generations=60,
              generations_per_round=10, max_depth=4, depth_cap=6, fitness=:tests)
        a = GS.run_cdgp(spec_path; kw...)
        b = GS.run_cdgp(spec_path; kw..., trace=GS.CDGPTrace())
        @test a.solved == b.solved
        @test a.generations == b.generations
        @test a.expr == b.expr
    end
end
