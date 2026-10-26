#=
scripts/verify_multi_answer_specs.jl — check the properties the multi-answer
benchmark tier relies on, for every spec in spec_files/multi_answer/:

  1. in scope for both in-process solvers (CexSolver, ConstraintSatSolver), so
     `fitness=:tests` and `fitness=:hybrid` both run on it;
  2. every constraint evaluable pointwise (incomplete tests can be judged);
  3. Z3 proves it is NOT single-answer (the point of the tier), while the
     single-answer controls (max5, countpos3.cdgp) are proven single-answer;
  4. realizable: a known solution verifies (in-process and subprocess Z3), and
     holds pointwise on random inputs;
  5. the spec's own grammar builds;
  6. what a counterexample becomes: the complete/incomplete split over the
     counterexamples of a few wrong candidates.

    julia --project=. scripts/verify_multi_answer_specs.jl
=#
using HerbGrammar   # the grammar builders evaluate @csgrammar in Main
using CEGIS, Random
const CG = CEGIS.CEXGeneration
const GS = CEGIS.GeneticSearch

const ROOT = normpath(joinpath(@__DIR__, ".."))
const DIR = joinpath(ROOT, "spec_files", "multi_answer")

mx(a, b) = "(ite (>= $a $b) $a $b)"
mn(a, b) = "(ite (<= $a $b) $a $b)"
const MAX3 = mx(mx("x", "y"), "z")
const MIN3 = mn(mn("x", "y"), "z")
possum(vs) = "(+ 1 " * join(["(ite (>= $v 0) $v 0)" for v in split(vs)], " ") * ")"

# name => (known solution, wrong candidates whose counterexamples we classify)
const CASES = [
    "max3_slack"   => (MAX3, ["x", "(+ x y)", "(+ $MAX3 2)"]),
    "max4_slack"   => (mx(mx("w", "x"), mx("y", "z")), ["w", "(+ w 1)", mx("w", "x")]),
    "max5_slack"   => (mx(mx(mx("v", "w"), mx("x", "y")), "z"), ["v", "(+ v w)", mx("v", "w")]),
    "above4"       => ("(+ $(mx(mx("w", "x"), mx("y", "z"))) 1)", ["w", "(+ w 1)", "(+ w x)"]),
    "range3_slack" => ("(- $MAX3 $MIN3)", ["x", "(- x y)", MAX3]),
    # above_n family: 1 + the sum of max(v, 0) is strictly above every input.
    "above5"       => (possum("v w x y z"), ["v", "(+ v 1)", "(+ v w)"]),
    "above6"       => (possum("u v w x y z"), ["u", "(+ u 1)", "(+ u v)"]),
    "above7"       => (possum("t u v w x y z"), ["t", "(+ t 1)", "(+ t u)"]),
    "avoid2"       => ("(ite (or (= x 0) (= y 0)) (ite (or (= x 1) (= y 1)) (+ 1 1) 1) 0)",
                       ["0", "1", "(+ x 1)", "(ite (= x 0) 1 0)"]),
]
const CONTROLS = ["spec_files/phase3_benchmarks/max5_simple.sl", "spec_files/paired/cdgp/countpos3.sl"]

"""Evaluate an SMT-LIB Int term at a binding (enough of LIA for the solutions above)."""
function smt_eval(s, b::Dict{String,Any})
    s isa AbstractString && return something(tryparse(Int, s), get(b, s, nothing))
    h, a = s[1], s[2:end]
    ev(i) = smt_eval(a[i], b)
    h == "ite" && return ev(1) ? ev(2) : ev(3)
    h == "+" && return sum(ev(i) for i in eachindex(a))
    h == "-" && return length(a) == 1 ? -ev(1) : ev(1) - sum(ev(i) for i in 2:length(a))
    h == ">=" && return ev(1) >= ev(2)
    h == "<=" && return ev(1) <= ev(2)
    h == "=" && return ev(1) == ev(2)
    h == "or" && return any(ev(i) for i in eachindex(a))
    h == "and" && return all(ev(i) for i in eachindex(a))
    h == "not" && return !ev(1)
    error("smt_eval: $h")
end

ok(c) = c ? "ok  " : "FAIL"
failures = 0
check(c) = (c || (global failures += 1); ok(c))

println("controls (must be single-answer):")
for p in CONTROLS
    spec = CG.parse_spec_from_file(joinpath(ROOT, p))
    sa = CG.spec_single_answer(spec)
    println("  $(check(sa === true)) $(basename(p)): single_answer = $sa")
end

rng = MersenneTwister(1)
for (name, (sol, wrongs)) in CASES
    path = joinpath(DIR, name * ".sl")
    println("\n$name")
    spec = CG.parse_spec_from_file(path)
    fname = spec.synth_funs[1].name
    cs = CG.CexSolver(spec; timeout_ms=5_000, nl_arith=false)
    css = CG.ConstraintSatSolver(spec; timeout_ms=5_000, nl_arith=false)
    println("  $(check(true)) in-process solvers construct ($(length(spec.constraints)) constraints)")

    sexprs = Any[CG.read_sexprs(c)[1] for c in spec.constraints]
    pw = GS._pointwise_ok(sexprs, fname, spec)
    println("  $(check(pw)) pointwise-evaluable")

    sa = CG.spec_single_answer(spec)
    println("  $(check(sa === false)) single_answer = $sa (must be false)")

    r = CG.find_counterexample(cs, fname, sol)
    rs = CG.verify_query(CG.generate_cex_query(spec, Dict(fname => sol)))
    println("  $(check(r.status == :unsat && rs.status == :unsat)) known solution verifies " *
            "(in-process $(r.status), subprocess $(rs.status))")
    solx = CG.read_sexprs(sol)[1]
    holds = all(1:500) do _
        b = Dict{String,Any}(fv.name => rand(rng, -20:20) for fv in spec.free_vars)
        out = smt_eval(solx, b)
        all(s -> CG.eval_constraint_pointwise(s, fname, b, _ -> out), sexprs)
    end
    println("  $(check(holds)) known solution holds pointwise on 500 random inputs")

    g = CEGIS.GrammarBuilding.build_grammar_from_sygus(spec)
    println("  $(check(length(g.rules) > 0)) grammar builds ($(length(g.rules)) rules)")

    kinds = String[]
    for w in wrongs
        cx = CG.find_counterexample(cs, fname, w)
        cx.status == :sat || (push!(kinds, "$w: $(cx.status)"); continue)
        b = GS._cex_binding(spec, cx.model)
        out = cx.model["out_$fname"]
        u = CG.output_is_unique(cs, b, out)
        push!(kinds, "$w ⇒ input $(join(("$k=$v" for (k, v) in sort(collect(b))), ",")) " *
                     "Z3 output $out, " * (u === true ? "COMPLETE (unique)" : "INCOMPLETE (another output valid)"))
    end
    println("  counterexamples of wrong candidates:")
    foreach(k -> println("      ", k), kinds)
end

println(failures == 0 ? "\nALL CHECKS PASSED" : "\n$failures CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
