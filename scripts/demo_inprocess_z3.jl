"""
demo_inprocess_z3.jl

Demonstrates the in-process Z3 backend inside CEGIS. The same constructed SMT-LIB2
query strings are run through `Z3_eval_smtlib2_string` (in-process) instead of the
`z3` subprocess — no temp files, no process spawns — while the public verification
API (`verify_query`, `verify_graded_query`) and its results are unchanged.

It verifies a correct and a wrong candidate, prints verdicts / witnesses / the
per-constraint graded breakdown, and times in-process vs subprocess over a batch.

Run:  julia --project=. scripts/demo_inprocess_z3.jl
"""

const ROOT = dirname(@__DIR__)
push!(LOAD_PATH, joinpath(ROOT, "src"))
include(joinpath(ROOT, "src", "CEGIS.jl"))
const CG = CEGIS.CEXGeneration

const SPEC2 = joinpath(ROOT, "spec_files", "phase3_benchmarks", "max2_simple.sl")
const SPEC4 = joinpath(ROOT, "spec_files", "phase3_benchmarks", "max4_simple.sl")

# Correct nested-max body for max4 (SMT-LIB2).
pairmax(a, b) = "(ite (>= $a $b) $a $b)"
const MAX4_CORRECT = pairmax(pairmax("x0", "x1"), pairmax("x2", "x3"))

function show_verify(spec, fn, body)
    r = CG.verify_query(CG.generate_query(spec, Dict(fn => body)))
    print("  $fn = $body\n    => $(r.status)")
    if r.status == :sat
        wit = join(["$k=$(r.model[k])" for k in sort(collect(keys(r.model))) if !occursin("(", k)], " ")
        print("  (counterexample: $wit; violated constraints $(r.violated_constraints))")
    else
        print("  (verified correct for all inputs)")
    end
    println()
end

function show_graded(spec, fn, body)
    g = CG.verify_graded_query(CG.generate_graded_query(spec, Dict(fn => body)))
    viol = [i for (i, c) in enumerate(g) if c.status == :sat]
    println("  $fn = $body")
    println("    universal violated constraints = $viol  (empty ⇒ correct)")
end

function timed(label, n, f)
    f()                                   # warm up (JIT)
    t = @elapsed for _ in 1:n; f(); end
    println("  $label: $(round(t; digits=3))s for $n calls ($(round(1000t/n; digits=2)) ms/call)")
end

function main()
    spec2 = CG.parse_spec_from_file(SPEC2)
    spec4 = CG.parse_spec_from_file(SPEC4)

    println("="^72)
    println("verify_query (in-process Z3) — max2")
    show_verify(spec2, "max2", "x0")                       # wrong
    show_verify(spec2, "max2", "(ite (>= x0 x1) x0 x1)")   # correct

    println("\nverify_graded_query (in-process Z3) — max4 (universal per-constraint)")
    show_graded(spec4, "max4", "x0")                       # wrong
    show_graded(spec4, "max4", MAX4_CORRECT)               # correct

    println("\n", "="^72)
    println("Backend timing (max4 graded check of a wrong candidate)")
    gq = CG.generate_graded_query(spec4, Dict("max4" => "x0"))
    haskey(ENV, "CEGIS_Z3_SUBPROCESS") && delete!(ENV, "CEGIS_Z3_SUBPROCESS")
    timed("in-process ", 25, () -> CG.verify_graded_query(gq))
    ENV["CEGIS_Z3_SUBPROCESS"] = "1"
    timed("subprocess ", 25, () -> CG.verify_graded_query(gq))
    delete!(ENV, "CEGIS_Z3_SUBPROCESS")
    println("="^72)
end

main()
