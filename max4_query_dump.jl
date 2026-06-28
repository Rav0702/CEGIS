"""
max4_query_dump.jl

Generates per-constraint Z3 queries for the `max4_simple` spec exactly the way
the genetic evaluator does (`CEXGeneration.generate_constraint_check_query`,
one query per constraint with the candidate inlined as a `define-fun`), dumps
every query to disk, and then runs Z3 on each via `CEXGeneration.verify_query`.

Candidates here are hand-written SMT-LIB2 bodies (the same string a RuleNode is
converted to by `rulenode_to_smt2`), so this exercises the verification path
with no GA involved.

Per constraint:
  :unsat ⇒ candidate satisfies it for ALL inputs
  :sat   ⇒ candidate violates it; the model is a concrete counterexample input

Run:  julia --project=. max4_query_dump.jl
"""

using CEGIS
using CEGIS.CEXGeneration
const CG = CEGIS.CEXGeneration

const SPEC_PATH = joinpath(@__DIR__, "spec_files", "phase3_benchmarks", "max4_simple.sl")
const OUT_DIR   = joinpath(@__DIR__, "z3_query_dump", "max4")

# ── Dummy candidate programs (SMT-LIB2 bodies over params x0,x1,x2,x3) ─────────
# Keyed by a human label; each maps to the body for synth-fun `max4`.
pairmax(a, b) = "(ite (>= $a $b) $a $b)"

const CANDIDATES = Dict(
    # Correct: max(max(x0,x1), max(x2,x3)) as nested ite.
    "correct_nested_max" =>
        pairmax(pairmax("x0", "x1"), pairmax("x2", "x3")),

    # Wrong: returns the first argument only.
    "just_x0" => "x0",

    # Wrong: sum of all arguments.
    "sum_all" => "(+ (+ x0 x1) (+ x2 x3))",

    # Partially wrong: max of the first three only (ignores x3).
    "max_of_first_three" =>
        pairmax(pairmax("x0", "x1"), "x2"),
)

# ── Driver ────────────────────────────────────────────────────────────────────
function main()
    println("Parsing spec: ", SPEC_PATH)
    spec = CG.parse_spec_from_file(SPEC_PATH)
    func = spec.synth_funs[1].name
    nconstr = length(spec.constraints)
    println("  synth-fun   : ", func, "  params=", spec.synth_funs[1].params)
    println("  constraints : ", nconstr)
    for (i, c) in enumerate(spec.constraints)
        println("    [$i] ", c)
    end

    isdir(OUT_DIR) && rm(OUT_DIR; recursive=true)
    mkpath(OUT_DIR)

    summary = String[]
    push!(summary, "max4 per-constraint Z3 verification")
    push!(summary, "spec: $SPEC_PATH\n")

    for label in sort(collect(keys(CANDIDATES)))
        body = CANDIDATES[label]
        cands = Dict(func => body)
        cdir = joinpath(OUT_DIR, label)
        mkpath(cdir)

        println("\n", "="^72)
        println("CANDIDATE: ", label)
        println("  body = ", body)
        println("="^72)
        push!(summary, "="^60)
        push!(summary, "CANDIDATE: $label")
        push!(summary, "  body = $body")

        nviol = 0
        for i in 1:nconstr
            query = CG.generate_constraint_check_query(spec, cands, i)

            qpath = joinpath(cdir, "constraint_$(i).smt2")
            write(qpath, query)

            r = CG.verify_query(query)
            violated = r.status == :sat
            nviol += violated ? 1 : 0

            wit = ""
            if violated && !isempty(r.model)
                pairs = ["$k=$(r.model[k])" for k in sort(collect(keys(r.model)))]
                wit = "  witness: " * join(pairs, " ")
            end
            verdict = violated ? "VIOLATED (sat)" : (r.status == :unsat ? "ok (unsat)" : "unknown")
            line = "  constraint $i: $verdict$wit"
            println(line, "   [query -> $(relpath(qpath, @__DIR__))]")
            push!(summary, line)
        end
        result = nviol == 0 ? "CORRECT (0 violations)" : "$nviol/$nconstr constraints violated"
        println("  => ", result)
        push!(summary, "  => $result\n")
    end

    sumpath = joinpath(OUT_DIR, "results.txt")
    write(sumpath, join(summary, "\n") * "\n")
    println("\nQueries + summary written under: ", relpath(OUT_DIR, @__DIR__))
    println("Summary: ", relpath(sumpath, @__DIR__))
end

main()
