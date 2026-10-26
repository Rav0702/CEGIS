"""
Tests for the in-process persistent `CexSolver` — the warm Z3.jl counterpart to
`generate_cex_query` + `verify_query`. It must agree with the subprocess path on
status, produce spec-consistent counterexample models under the same key scheme
(free-var names + `out_<f>`), and stay isolated across candidates (push/pop).
"""

@testset "In-process CexSolver (warm Z3.Solver counterexample queries)" verbose = true begin
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

    @testset "correct candidate is :unsat" begin
        cs = CG.CexSolver(_max2_spec())
        @test CG.find_counterexample(cs, "max2", "(ite (< x0 x1) x1 x0)").status == :unsat
        @test CG.find_counterexample(cs, "max2", "(ite (>= x0 x1) x0 x1)").status == :unsat
    end

    @testset "wrong candidate yields a spec-consistent model" begin
        cs = CG.CexSolver(_max2_spec())
        for cand in ("x0", "x1", "(+ x0 x1)", "0")
            r = CG.find_counterexample(cs, "max2", cand)
            @test r.status == :sat
            @test haskey(r.model, "x0") && haskey(r.model, "x1")
            @test haskey(r.model, "out_max2")
            # out_max2 is a spec-valid output at the counterexample input: the max.
            @test r.model["out_max2"] == max(r.model["x0"], r.model["x1"])
        end
    end

    @testset "status parity with the subprocess path" begin
        spec = _max2_spec()
        cs = CG.CexSolver(spec)
        for cand in ("(ite (> x0 x1) x0 x1)", "(ite (>= x0 x1) x0 x1)", "x0", "x1",
                     "(+ x0 1)", "(- x0 1)", "(+ x0 x1)", "5")
            ip = CG.find_counterexample(cs, "max2", cand)
            sub = CG.verify_query(CG.generate_cex_query(spec, Dict("max2" => cand)))
            @test ip.status == sub.status
            if ip.status == :sat
                # The in-process model must be a genuine counterexample: the
                # candidate disagrees with every spec-valid output. For max2 the
                # valid output is unique (the max), so candidate(input) ≠ out.
                x0, x1 = ip.model["x0"], ip.model["x1"]
                cand_val = cand == "x0" ? x0 : cand == "x1" ? x1 :
                           cand == "(+ x0 1)" ? x0 + 1 : cand == "(- x0 1)" ? x0 - 1 :
                           cand == "(+ x0 x1)" ? x0 + x1 : cand == "5" ? 5 : nothing
                cand_val === nothing || @test cand_val != max(x0, x1)
            end
        end
    end

    @testset "push/pop isolation across candidates" begin
        cs = CG.CexSolver(_max2_spec())
        @test CG.find_counterexample(cs, "max2", "x0").status == :sat
        @test CG.find_counterexample(cs, "max2", "(ite (< x0 x1) x1 x0)").status == :unsat
        @test CG.find_counterexample(cs, "max2", "x1").status == :sat
        @test CG.find_counterexample(cs, "max2", "(ite (< x0 x1) x1 x0)").status == :unsat
    end

    @testset "ill-typed candidate is :unknown" begin
        cs = CG.CexSolver(_max2_spec())
        @test CG.find_counterexample(cs, "max2", "(foo x0)").status == :unknown
    end

    @testset "param names differ from free-var names (fnd_sum-style)" begin
        # Regression: candidates arrive in *param* names (y1, y2) and must be
        # renamed to the *free-var* consts (x1, x2) when inlined — the reverse
        # of the subprocess define-fun direction. With the direction swapped,
        # every variable-bearing candidate failed to build (⇒ :unknown).
        s = CG.Spec(); s.logic = "LIA"
        s.synth_funs = [CG.SynthFun("add2", [("y1", "Int"), ("y2", "Int")], "Int")]
        s.free_vars = [CG.FreeVar("x1", "Int"), CG.FreeVar("x2", "Int")]
        s.constraints = ["(= (add2 x1 x2) (+ x1 x2))"]

        cs = CG.CexSolver(s)
        @test CG.find_counterexample(cs, "add2", "(+ y1 y2)").status == :unsat
        r = CG.find_counterexample(cs, "add2", "y1")
        @test r.status == :sat
        @test r.model["out_add2"] == r.model["x1"] + r.model["x2"]

        css = CG.ConstraintSatSolver(s)
        @test CG.check_constraint_satisfaction(css, "add2", "(+ y1 y2)").satisfied == [true]
        @test CG.check_constraint_satisfaction(css, "add2", "y1").satisfied == [false]
        # Parity with the subprocess path on the same candidates.
        for cand in ("(+ y1 y2)", "y1", "(+ y1 1)")
            @test CG.check_constraint_satisfaction(css, "add2", cand).satisfied ==
                  CG.check_constraint_satisfaction(s, "add2", cand).satisfied
        end
    end

    @testset "out-of-scope specs raise at construction" begin
        # Non-canonical application (swapped args) — callers fall back to subprocess.
        spec = _max2_spec()
        spec.constraints = ["(>= (max2 x1 x0) x0)"]
        @test_throws Exception CG.CexSolver(spec)
    end

    @testset "Bool-sorted synth-fun" begin
        # is_pos(x): constraint (= (is_pos x) (> x 0)).
        s = CG.Spec(); s.logic = "LIA"
        s.synth_funs = [CG.SynthFun("is_pos", [("x", "Int")], "Bool")]
        s.free_vars = [CG.FreeVar("x", "Int")]
        s.constraints = ["(= (is_pos x) (> x 0))"]
        cs = CG.CexSolver(s)
        @test CG.find_counterexample(cs, "is_pos", "(> x 0)").status == :unsat
        r = CG.find_counterexample(cs, "is_pos", "(< x 0)")
        @test r.status == :sat
        @test haskey(r.model, "x")
        # Bool model values are reported as 1/0, matching the subprocess parser.
        @test r.model["out_is_pos"] == (r.model["x"] > 0 ? 1 : 0)
    end
end
