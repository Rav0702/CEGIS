"""
Tests for the in-process Z3 backend (`_z3_eval` / `_z3_solve`).

`verify_query` and `verify_graded_query` run Z3 in-process via
`Z3_eval_smtlib2_string` by default, falling back to the `z3` subprocess when
`CEGIS_Z3_SUBPROCESS=1`. These tests check the in-process path directly and confirm
both backends produce identical verdicts.
"""

"""Run `f()` with `CEGIS_Z3_SUBPROCESS` forced to `val`, then restore the env."""
function with_subprocess_env(f, val::String)
    had = haskey(ENV, "CEGIS_Z3_SUBPROCESS")
    old = get(ENV, "CEGIS_Z3_SUBPROCESS", "")
    ENV["CEGIS_Z3_SUBPROCESS"] = val
    try
        return f()
    finally
        had ? (ENV["CEGIS_Z3_SUBPROCESS"] = old) : delete!(ENV, "CEGIS_Z3_SUBPROCESS")
    end
end

@testset "In-process Z3 backend" verbose = true begin
    CG = CEGIS.CEXGeneration

    @testset "_z3_eval returns binary-format output" begin
        sat = CG._z3_eval("(set-logic LIA)(declare-const x Int)(assert (> x 5))(check-sat)(get-value (x))")
        @test startswith(sat, "sat")
        @test occursin("(x 6)", sat)

        # get-value after unsat must NOT abort the process; result still starts "unsat".
        unsat = CG._z3_eval("(set-logic LIA)(declare-const x Int)(assert (and (> x 0)(< x 0)))(check-sat)(get-value (x))")
        @test startswith(unsat, "unsat")

        # multi check-sat push/pop script returns one verdict per check-sat, in order.
        multi = CG._z3_eval("(declare-const y Int)(push 1)(assert (> y 0))(check-sat)(pop 1)(push 1)(assert (and (> y 0)(< y 0)))(check-sat)(pop 1)")
        verdicts = [l for l in strip.(split(multi, '\n')) if l in ("sat", "unsat")]
        @test verdicts == ["sat", "unsat"]
    end

    @testset "verify_query in-process (max2)" begin
        spec = CG.parse_spec_from_file(find_spec_file("max2_simple"))
        wrong = CG.verify_query(CG.generate_query(spec, Dict("max2" => "x0")))
        @test wrong.status == :sat
        @test !isempty(wrong.model)
        @test wrong.violated_constraints == [2]

        ok = CG.verify_query(CG.generate_query(spec, Dict("max2" => "(ite (>= x0 x1) x0 x1)")))
        @test ok.status == :unsat   # correct candidate: model error caught, reported correct
    end

    @testset "verify_graded_query in-process (max4)" begin
        spec = CG.parse_spec_from_file(find_spec_file("max4_simple"))
        g = CG.verify_graded_query(CG.generate_graded_query(spec, Dict("max4" => "x0")))
        @test [i for (i, c) in enumerate(g) if c.status == :sat] == [2, 3, 4]

        gok = CG.verify_graded_query(CG.generate_graded_query(spec, Dict("max4" =>
            "(ite (>= (ite (>= x0 x1) x0 x1) (ite (>= x2 x3) x2 x3)) (ite (>= x0 x1) x0 x1) (ite (>= x2 x3) x2 x3))")))
        @test all(c -> c.status == :unsat, gok)
    end

    @testset "backends agree (in-process vs subprocess)" begin
        spec = CG.parse_spec_from_file(find_spec_file("max2_simple"))
        q = CG.generate_query(spec, Dict("max2" => "x0"))
        gq = CG.generate_graded_query(spec, Dict("max2" => "x0"))

        inproc      = with_subprocess_env("0") do; CG.verify_query(q) end
        subproc     = with_subprocess_env("1") do; CG.verify_query(q) end
        @test inproc.status == subproc.status
        @test inproc.violated_constraints == subproc.violated_constraints

        g_inproc  = with_subprocess_env("0") do; CG.verify_graded_query(gq) end
        g_subproc = with_subprocess_env("1") do; CG.verify_graded_query(gq) end
        @test [c.status for c in g_inproc] == [c.status for c in g_subproc]
    end
end
