"""
Tests for the in-process persistent `ConstraintSatSolver` — the warm `Z3.Solver`
counterpart to the subprocess `check_constraint_satisfaction`. It must produce the
same `ConstraintSatResult` (satisfied bits + status), and the `CEGIS_CSAT_INPROCESS`
flag must route the stateless API through it while staying backwards compatible.
"""

@testset "In-process ConstraintSatSolver (Method 2, warm Z3.Solver)" verbose = true begin
    CG = CEGIS.CEXGeneration

    function _max2(; names=("x0", "x1"))
        a, b = names
        s = CG.Spec(); s.logic = "LIA"
        s.synth_funs = [CG.SynthFun("max2", [(a, "Int"), (b, "Int")], "Int")]
        s.free_vars = [CG.FreeVar(a, "Int"), CG.FreeVar(b, "Int")]
        s.constraints = [
            "(>= (max2 $a $b) $a)",
            "(>= (max2 $a $b) $b)",
            "(or (= $a (max2 $a $b)) (= $b (max2 $a $b)))",
        ]
        s
    end

    function _max4()
        s = CG.Spec(); s.logic = "LIA"
        s.synth_funs = [CG.SynthFun("max4", [("x0","Int"),("x1","Int"),("x2","Int"),("x3","Int")], "Int")]
        s.free_vars = [CG.FreeVar("x$i", "Int") for i in 0:3]
        ap = "(max4 x0 x1 x2 x3)"
        s.constraints = [
            "(>= $ap x0)", "(>= $ap x1)", "(>= $ap x2)", "(>= $ap x3)",
            "(or (= x0 $ap) (or (= x1 $ap) (or (= x2 $ap) (= x3 $ap))))",
        ]
        s
    end

    function with_env(f, key, val)
        had = haskey(ENV, key); old = get(ENV, key, "")
        ENV[key] = val
        try f() finally; had ? (ENV[key] = old) : delete!(ENV, key); end
    end

    @testset "known universal values (max2 / max4)" begin
        css2 = CG.ConstraintSatSolver(_max2())
        @test CG.check_constraint_satisfaction(css2, "max2", "(ite (< x0 x1) x1 x0)").satisfied == [true, true, true]
        @test CG.check_constraint_satisfaction(css2, "max2", "x0").satisfied == [true, false, true]
        @test CG.check_constraint_satisfaction(css2, "max2", "0").satisfied == [false, false, false]

        css4 = CG.ConstraintSatSolver(_max4())
        @test CG.violated_indices(CG.check_constraint_satisfaction(css4, "max4", "x0")) == [2, 3, 4]
        @test CG.all_satisfied(CG.check_constraint_satisfaction(css4, "max4",
            "(ite (>= (ite (>= x0 x1) x0 x1) (ite (>= x2 x3) x2 x3)) (ite (>= x0 x1) x0 x1) (ite (>= x2 x3) x2 x3))"))
    end

    @testset "parity with subprocess path" begin
        max2_cands = ["(ite (> x0 x1) x0 x1)", "(ite (>= x0 x1) x0 x1)", "x0", "x1",
                      "(+ x0 1)", "(+ x1 1)", "(- x0 1)", "(+ x0 x1)", "5"]
        for (spec, cands) in ((_max2(), max2_cands),
                              (_max4(), ["x0", "x1", "(+ (+ x0 x1) (+ x2 x3))",
                                         "(ite (>= x0 x1) x0 x1)", "0"]))
            css = CG.ConstraintSatSolver(spec)
            fn = spec.synth_funs[1].name
            for c in cands
                sub = CG.check_constraint_satisfaction(spec, fn, c)
                ip  = CG.check_constraint_satisfaction(css, fn, c)
                @test ip.satisfied == sub.satisfied
                @test ip.status == sub.status
            end
        end
    end

    @testset "param names ≠ free-var names" begin
        # Same as default but synth-fun params renamed; candidate uses param names.
        spec = _max2(names=("x", "y"))
        css = CG.ConstraintSatSolver(spec)
        for c in ("x", "y", "(ite (< x y) y x)", "(+ x 1)")
            @test CG.check_constraint_satisfaction(css, "max2", c).satisfied ==
                  CG.check_constraint_satisfaction(spec, "max2", c).satisfied
        end
    end

    @testset "CEGIS_CSAT_INPROCESS flag routes the stateless API" begin
        spec = _max2()
        for c in ("x0", "(ite (< x0 x1) x1 x0)", "(+ x0 x1)")
            sub = with_env("CEGIS_CSAT_INPROCESS", "0") do
                CG.check_constraint_satisfaction(spec, "max2", c)
            end
            ip = with_env("CEGIS_CSAT_INPROCESS", "1") do
                CG.check_constraint_satisfaction(spec, "max2", c)
            end
            @test ip.satisfied == sub.satisfied
        end
    end

    @testset "flag falls back to subprocess on out-of-scope specs" begin
        # Non-canonical application (swapped args) is outside the in-process scope;
        # with the flag on it must fall back to the subprocess path and stay correct.
        spec = _max2()
        spec.constraints = ["(>= (max2 x1 x0) x0)", "(>= (max2 x0 x1) x1)",
                            "(or (= x0 (max2 x0 x1)) (= x1 (max2 x0 x1)))"]
        @test_throws Exception CG.ConstraintSatSolver(spec)   # constructor rejects it
        flagged = with_env("CEGIS_CSAT_INPROCESS", "1") do
            CG.check_constraint_satisfaction(spec, "max2", "x0")
        end
        baseline = with_env("CEGIS_CSAT_INPROCESS", "0") do
            CG.check_constraint_satisfaction(spec, "max2", "x0")
        end
        @test flagged.satisfied == baseline.satisfied
    end
end
