"""
`rulenode_to_smt2` on grammars built from a SyGuS grammar block, where `and` / `or`
become Julia's `&&` / `||` (Expr heads, not calls) and `not` becomes `!`.

Until 2026-09-27 these three were unhandled: conversion threw, so any program using
them could never be verified. Checked here against the interpreter: the converted
program must agree with it on random inputs (via Z3 evaluation of the SMT term).
"""

using HerbGrammar: expr2rulenode
using Random

@testset "rulenode_to_smt2 on SyGuS-grammar and/or/not" begin
    CG = CEGIS.CEXGeneration
    spec = CG.parse_spec_from_file(joinpath(@__DIR__, "..", "spec_files", "case_split", "array_search4.sl"))
    g = CEGIS.GrammarBuilding.build_grammar_from_sygus(spec)
    st = grammar2symboltable(g, Main)

    # Build RuleNodes by rule index (expr2rulenode does not accept && / ||).
    r(e) = findfirst(==(e), g.rules)
    AND, OR, NOT = r(:(BoolExpr && BoolExpr)), r(:(BoolExpr || BoolExpr)), r(:(!BoolExpr))
    LE, ITE = r(:(Expr <= Expr)), r(:(ifelse(BoolExpr, Expr, Expr)))
    v(s) = RuleNode(r(s))
    one, zero = RuleNode(r(1)), RuleNode(r(0))
    @test all(!isnothing, (AND, OR, NOT, LE, ITE))

    # ifelse(!(k <= x1) && (k <= x2 || x3 <= k), 1, 0)
    cond = RuleNode(AND, [RuleNode(NOT, [RuleNode(LE, [v(:k), v(:x1)])]),
                          RuleNode(OR, [RuleNode(LE, [v(:k), v(:x2)]), RuleNode(LE, [v(:x3), v(:k)])])])
    tree = RuleNode(ITE, [cond, one, zero])
    smt = CG.rulenode_to_smt2(tree, g)
    @test occursin("(not ", smt) && occursin("(and ", smt) && occursin("(or ", smt)

    # Agreement with the interpreter: the SMT term, with the inputs substituted, is
    # checked by the in-process solver as `(= term expected)`.
    expr = rulenode2expr(tree, g)
    rng = Random.MersenneTwister(7)
    for _ in 1:25
        inp = Dict{Symbol,Any}(s => rand(rng, -5:5) for s in (:x1, :x2, :x3, :x4, :k))
        want = execute_on_input(st, expr, inp)
        q = "(declare-const out Int)\n" *
            "(assert (= out (let ($(join(["($(s) $(inp[s] < 0 ? "(- $(-inp[s]))" : inp[s]))" for s in (:x1, :x2, :x3, :x4, :k)], " "))) $smt)))\n" *
            "(assert (not (= out $want)))\n(check-sat)\n"
        @test CG.verify_query(q).status == :unsat
    end

    # And the program is now verifiable end to end (no conversion error → no :unknown).
    css = CG.ConstraintSatSolver(spec; timeout_ms = 5_000, nl_arith = false)
    res = CG.check_constraint_satisfaction(css, spec.synth_funs[1].name, smt)
    @test all(s -> s in (:sat, :unsat), res.status)
end
