"""
Soundness of the classic CEGIS oracle path (fixed 2026-10-03, spec_knowledge/EXPERIMENTS.md "Stage 1 fault"):
- the string candidate parsers understand Julia's `&&` / `||` / `!` (what `rulenode2expr` prints for SyGuS
  `and` / `or` / `not`) and agree with the direct `rulenode_to_smt2`;
- `Z3Oracle` reports whether `nothing` was a proof (`candidate_verified`); a conversion error or a solver
  `unknown` is not, and `synth_with_oracle` no longer accepts such a candidate.
"""

struct _ThrowingParser <: CEGIS.CEXGeneration.AbstractCandidateParser end
CEGIS.CEXGeneration.to_smt2(::_ThrowingParser, ::String) = error("conversion failure (test)")

@testset "oracle soundness: candidate parsers and candidate_verified" begin
    CG = CEGIS.CEXGeneration
    root = joinpath(@__DIR__, "..", "spec_files")
    z3 = something(Sys.which("z3"), raw"C:\Users\rafal\tools\z3\z3-4.16.0-x64-win\bin\z3.exe")
    load(rel) = (sp = CG.parse_spec_from_file(joinpath(root, rel)); (sp, CEGIS.GrammarBuilding.build_grammar_from_sygus(sp)))

    # 1. Parsers vs the direct converter, on random programs from grammars with and/or/not (z3 evaluates both).
    for (rel, start) in (("enriched/tiered3_caseguard.sl", :Expr), ("grammar_variants/max6_sygus.sl", :Expr))
        sp, g = load(rel)
        params = [Symbol(p) for (p, _) in sp.synth_funs[1].params]
        progs = [rand(RuleNode, g, start, 5) for _ in 1:40]
        for parser in (CG.SymbolicCandidateParser(), CG.InfixCandidateParser())
            q = IOBuffer(); n = 0
            for t in progs, _ in 1:3
                binds = join(("($k $(v < 0 ? "(- $(-v))" : v))" for (k, v) in Dict(p => rand(-4:4) for p in params)), " ")
                a = CG.to_smt2(parser, string(rulenode2expr(t, g)))
                b = CG.rulenode_to_smt2(t, g)
                println(q, "(simplify (let ($binds) (= $a $b)))"); n += 1
            end
            out = split(strip(read(pipeline(`$z3 -in`; stdin = IOBuffer(take!(q))), String)), '\n')
            @test length(out) == n && all(==("true"), strip.(out))
        end
    end

    # 2. The program the faulty path accepted in E6a stage 1 is refuted once it parses.
    sp, _ = load("partial_knowledge/tiered3.sl")
    bad = "ifelse(x >= 0 && y <= 0 - 1, x, y + ((z - x) + z))"
    smt = CG.to_smt2(CG.SymbolicCandidateParser(), bad)
    @test !occursin("&&", smt)
    @test CG.verify_query(CG.generate_cex_query(sp, Dict(sp.synth_funs[1].name => smt))).status == :sat

    # 3. candidate_verified: a proof, a counterexample, and a conversion error are told apart.
    p3 = joinpath(root, "partial_knowledge/tiered3.sl")
    _, g3 = load("partial_knowledge/tiered3.sl")
    t_bad = rand(RuleNode, g3, :Expr, 2)                      # almost surely wrong on tiered3
    o = CEGIS.Z3Oracle(p3, g3; use_direct_conversion = true)
    cx = redirect_stdout(devnull) do; CEGIS.extract_counterexample(o, nothing, t_bad); end
    @test cx isa CEGIS.Counterexample && o.last_status === :sat
    o2 = CEGIS.Z3Oracle(p3, g3; parser = _ThrowingParser())
    cx2 = redirect_stdout(devnull) do; CEGIS.extract_counterexample(o2, nothing, t_bad); end
    @test cx2 === nothing && !CEGIS.candidate_verified(o2) && o2.last_status === :error

    # 3b. The counterexample query on a relational spec (f applied at x+1 / y+1): the realizability premise must
    # not substitute non-canonical applications (that excluded whole regions from the search; fixed 2026-10-03).
    sr = CG.parse_spec_from_file(joinpath(root, "partial_knowledge/recur3.sl"))
    good = "(ite (< x 0) 0 (ite (< y 0) x (ite (>= z 0) (+ (+ x x) (+ y z)) (- (- x y) z))))"
    bad1 = "(ite (< x 0) 0 (ite (< y 0) x (ite (>= z 0) (+ (+ (+ x x) (+ y z)) (ite (>= x 1) 1 0)) (- (- x y) z))))"
    bad2 = "(ite (< x 0) 0 (ite (< y 0) x (ite (>= z 0) (+ x (+ y z)) (- (- x y) z))))"
    @test CG.verify_query(CG.generate_cex_query(sr, Dict("recur3" => good))).status == :unsat
    @test CG.verify_query(CG.generate_cex_query(sr, Dict("recur3" => bad1))).status == :sat
    @test CG.verify_query(CG.generate_cex_query(sr, Dict("recur3" => bad2))).status == :sat
    @test CG._canonical_calls_only("(>= (f x y) x)", "f", ["x", "y"], 2)
    @test !CG._canonical_calls_only("(= (f x y) (f y x))", "f", ["x", "y"], 2)
    @test !CG._canonical_calls_only("(= (f 1 5) 5)", "f", ["x", "y"], 2)
    # symmetric_max: max still verifies, a non-symmetric wrong program does not
    ss = CG.parse_spec_from_file(joinpath(root, "phase3_benchmarks/symmetric_max.sl"))
    @test CG.verify_query(CG.generate_cex_query(ss, Dict(ss.synth_funs[1].name => "(ite (>= x y) x y)"))).status == :unsat
    @test CG.verify_query(CG.generate_cex_query(ss, Dict(ss.synth_funs[1].name => "(+ x 0)"))).status == :sat

    # 4. End to end: the plain loop on the K1 grammar, default parser path, never reports a wrong program.
    _, gc = load("enriched/tiered3_case.sl")
    r = redirect_stdout(devnull) do
        CEGIS.run_synthesis(CEGIS.CEGISProblem(joinpath(root, "enriched/tiered3_case.sl")),
                            BFSIterator(gc, :Expr; max_depth = 10); max_time = 20.0)
    end
    if r.status == CEGIS.cegis_success
        smt4 = CG.rulenode_to_smt2(r.program, gc)
        @test CG.verify_query(CG.generate_cex_query(sp, Dict(sp.synth_funs[1].name => smt4))).status == :unsat
    else
        @test r.status in (CEGIS.cegis_timeout, CEGIS.cegis_failure)
    end
end
