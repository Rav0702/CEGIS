"""
Tests for `eval_constraint_pointwise` — concrete-input evaluation of SyGuS
constraints, the interpreter half of the witness-battery signal.
"""

@testset "Pointwise constraint evaluation" verbose = true begin
    CG = CEGIS.CEXGeneration

    # `apply` for a max2-like candidate over two params.
    max_apply = args -> max(args[1], args[2])
    fst_apply = args -> args[1]

    ev(src, vars, apply; f="f") =
        CG.eval_constraint_pointwise(CG.read_sexprs(src)[1], f, vars, apply)

    @testset "synth-fun application and comparisons" begin
        c = "(>= (f x0 x1) x1)"
        @test ev(c, Dict("x0" => 3, "x1" => 7), max_apply)
        @test !ev(c, Dict("x0" => 3, "x1" => 7), fst_apply)
        @test ev(c, Dict("x0" => 9, "x1" => 7), fst_apply)
    end

    @testset "connectives short-circuit and nest" begin
        c = "(or (= x0 (f x0 x1)) (= x1 (f x0 x1)))"
        @test ev(c, Dict("x0" => 3, "x1" => 7), max_apply)
        @test !ev(c, Dict("x0" => 3, "x1" => 7), args -> 99)

        @test ev("(=> (> x0 0) (> (f x0 x1) 0))", Dict("x0" => -1, "x1" => 0), args -> 0)
        @test !ev("(=> (> x0 0) (> (f x0 x1) 0))", Dict("x0" => 1, "x1" => 0), args -> 0)
        @test ev("(not (and true false))", Dict{String,Any}(), fst_apply)
        @test ev("(xor true false)", Dict{String,Any}(), fst_apply)
    end

    @testset "arithmetic, ite, let" begin
        @test ev("(= (f x x) (+ x (- 0 x)))", Dict("x" => 5), args -> 0)
        @test ev("(= (ite (< x 0) (- x) x) (abs x))", Dict("x" => -4), args -> 0)
        @test ev("(= (* 3 x) 12)", Dict("x" => 4), args -> 0)
        @test ev("(let ((y (+ x 1))) (= y 6))", Dict("x" => 5), args -> 0)
        # `let` bindings evaluate in the outer scope (no sequential shadowing).
        @test ev("(let ((x (+ x 1))) (= x 6))", Dict("x" => 5), args -> 0)
    end

    @testset "SMT-LIB div/mod are Euclidean" begin
        # Remainder is non-negative regardless of sign, unlike Julia's `div`.
        @test ev("(= (div x 3) (- 3))", Dict("x" => -7), args -> 0)
        @test ev("(= (mod x 3) 2)", Dict("x" => -7), args -> 0)
        @test ev("(= (div x 3) 2)", Dict("x" => 7), args -> 0)
        @test ev("(= (mod x 3) 1)", Dict("x" => 7), args -> 0)
    end

    @testset "multi-invocation constraints evaluate correctly" begin
        # A relational spec the ∀-solvers reject but pointwise handles: `f` is
        # applied twice, at swapped arguments.
        c = "(= (f x0 x1) (f x1 x0))"
        @test ev(c, Dict("x0" => 2, "x1" => 5), max_apply)
        @test !ev(c, Dict("x0" => 2, "x1" => 5), fst_apply)
        # Nested application.
        @test ev("(= (f (f x0 x0) x0) x0)", Dict("x0" => 4), max_apply)
    end

    @testset "unsupported / malformed input raises PointwiseError" begin
        @test_throws CG.PointwiseError ev("(bvadd x x)", Dict("x" => 1), fst_apply)
        @test_throws CG.PointwiseError ev("(= y 1)", Dict("x" => 1), fst_apply)
        @test_throws CG.PointwiseError ev("(+ x 1)", Dict("x" => 1), fst_apply)  # not Bool
        @test_throws CG.PointwiseError ev("(div x 0)", Dict("x" => 1), fst_apply)
        @test_throws CG.PointwiseError ev("(not 1)", Dict{String,Any}(), fst_apply)
    end

    @testset "agrees with the solver on real spec constraints" begin
        # Every banked witness must genuinely falsify its constraint: take the
        # witnesses Z3 produces for a wrong candidate and re-check pointwise.
        spec_path = find_spec_file("max3_simple")
        spec = CG.parse_spec_from_file(spec_path)
        css = CG.ConstraintSatSolver(spec)
        fname = spec.synth_funs[1].name
        pnames = [p for (p, _) in spec.synth_funs[1].params]

        r, ws = CG.check_constraint_satisfaction_witnesses(css, fname, pnames[1])
        @test any(!, r.satisfied)

        for (i, w) in enumerate(ws)
            w === nothing && continue
            sexpr = CG.read_sexprs(spec.constraints[i])[1]
            # Candidate is `x0` — i.e. the first argument of each application.
            @test !CG.eval_constraint_pointwise(sexpr, fname, w, args -> args[1])
        end
    end
end
