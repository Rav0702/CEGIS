"""
Tests for Method 2 per-constraint satisfaction checking
(`CEGIS.CEXGeneration.check_constraint_satisfaction`).

Uses the max2 spec, whose three constraints are:
  C1: (>= (max2 x0 x1) x0)
  C2: (>= (max2 x0 x1) x1)
  C3: (or (= x0 (max2 x0 x1)) (= x1 (max2 x0 x1)))
"""

const CXG = CEGIS.CEXGeneration

# Build the max2 spec directly (no file dependency).
function _max2_spec()
    spec = CXG.Spec()
    spec.logic = "LIA"
    spec.synth_funs = [CXG.SynthFun("max2", [("x0", "Int"), ("x1", "Int")], "Int")]
    spec.free_vars = [CXG.FreeVar("x0", "Int"), CXG.FreeVar("x1", "Int")]
    spec.constraints = [
        "(>= (max2 x0 x1) x0)",
        "(>= (max2 x0 x1) x1)",
        "(or (= x0 (max2 x0 x1)) (= x1 (max2 x0 x1)))",
    ]
    return spec
end

@testset "Constraint satisfaction (Method 2)" begin
    spec = _max2_spec()

    @testset "query generation (no solver)" begin
        q = CXG.generate_satisfaction_query(spec, Dict("max2" => "x0"))
        @test occursin("(define-fun max2", q)
        # One isolated check per constraint (digit excludes the comment's _i form).
        @test length(collect(eachmatch(r"\(check-sat-assuming \(csat_assume_\d+\)\)", q))) == 3
        @test length(findall("declare-const csat_assume_", q)) == 3
        # The candidate must be inlined, not replaced by a fresh constant.
        @test occursin("(max2 x0 x1)", q)
    end

    @testset "fully correct candidate satisfies all" begin
        r = CXG.check_constraint_satisfaction(spec, "max2", "(ite (< x0 x1) x1 x0)")
        @test r.satisfied == [true, true, true]
        @test r.status == [:unsat, :unsat, :unsat]
        @test CXG.n_satisfied(r) == 3
        @test CXG.all_satisfied(r)
        @test CXG.violated_indices(r) == Int[]
    end

    @testset "returning x0 satisfies C1 and C3 only" begin
        # C1 (>= x0 x0) ✓, C2 (>= x0 x1) ✗, C3 (or (= x0 x0) ...) ✓
        r = CXG.check_constraint_satisfaction(spec, "max2", "x0")
        @test r.satisfied == [true, false, true]
        @test CXG.n_satisfied(r) == 2
        @test !CXG.all_satisfied(r)
        @test CXG.satisfied_indices(r) == [1, 3]
        @test CXG.violated_indices(r) == [2]
    end

    @testset "returning x1 satisfies C2 and C3 only" begin
        r = CXG.check_constraint_satisfaction(spec, "max2", "x1")
        @test r.satisfied == [false, true, true]
        @test CXG.satisfied_indices(r) == [2, 3]
    end

    @testset "constant 0 satisfies nothing" begin
        r = CXG.check_constraint_satisfaction(spec, "max2", "0")
        @test r.satisfied == [false, false, false]
        @test CXG.n_satisfied(r) == 0
    end

    @testset "(+ x0 x1) violates all three" begin
        # Sum can exceed neither bound for negatives, and is generally not an input.
        r = CXG.check_constraint_satisfaction(spec, "max2", "(+ x0 x1)")
        @test r.satisfied == [false, false, false]
    end

    @testset "matrix of candidates (x0/x1 spec)" begin
        # (candidate body, expected [C1, C2, C3])
        #   C1: (>= f x0)   C2: (>= f x1)   C3: f ∈ {x0, x1}
        cases = [
            ("(ite (> x0 x1) x0 x1)", [true,  true,  true]),   # correct max
            ("(ite (>= x0 x1) x0 x1)", [true, true,  true]),   # correct max
            ("x0",                    [true,  false, true]),
            ("x1",                    [false, true,  true]),
            ("(+ x0 1)",              [true,  false, false]),  # ≥x0, not ≥x1, not an input
            ("(+ x1 1)",              [false, true,  false]),
            ("(- x0 1)",              [false, false, false]),  # below both bounds
            ("(+ x0 x1)",             [false, false, false]),
            ("5",                     [false, false, false]),  # constant
        ]
        for (cand, expected) in cases
            r = CXG.check_constraint_satisfaction(spec, "max2", cand)
            @test r.satisfied == expected
            @test CXG.n_satisfied(r) == count(expected)
        end
    end

    @testset "named x/y spec (params x, y)" begin
        # Same max2 problem, but variables are named x and y.
        xy = CXG.Spec()
        xy.logic = "LIA"
        xy.synth_funs = [CXG.SynthFun("max2", [("x", "Int"), ("y", "Int")], "Int")]
        xy.free_vars = [CXG.FreeVar("x", "Int"), CXG.FreeVar("y", "Int")]
        xy.constraints = [
            "(>= (max2 x y) x)",
            "(>= (max2 x y) y)",
            "(or (= x (max2 x y)) (= y (max2 x y)))",
        ]

        cases = [
            ("x",                  [true,  false, true]),
            ("y",                  [false, true,  true]),
            ("(+ x 1)",            [true,  false, false]),
            ("(- y 1)",            [false, false, false]),
            ("(ite (< x y) y x)",  [true,  true,  true]),   # correct max
        ]
        for (cand, expected) in cases
            r = CXG.check_constraint_satisfaction(xy, "max2", cand)
            @test r.satisfied == expected
        end
    end

    @testset "empty constraint set" begin
        empty_spec = _max2_spec()
        empty_spec.constraints = String[]
        r = CXG.check_constraint_satisfaction(empty_spec, "max2", "x0")
        @test isempty(r.satisfied)
        @test CXG.n_satisfied(r) == 0
        @test !CXG.all_satisfied(r)
    end
end
