"""
Z3-Guided Genetic Synthesis — POC playground.

Demonstrates a novel way to use a genetic algorithm inside the CEGIS ecosystem:

  • The GA evolves CEGIS-native RuleNode programs (Arborist is the GA engine).
  • Fitness = number of spec constraints the candidate violates UNIVERSALLY,
    each checked independently with Z3. Fitness 0 ⇒ the program is formally
    verified — the fitness function *is* the verifier (no outer CEGIS loop).
  • Mutation is TARGETED by Z3 counterexamples: the witness input that breaks a
    candidate steers mutation to the subtree active at that failure.

Run: julia --project=. ga_cegis_poc.jl
"""

using CEGIS
using CEGIS.GeneticSearch

const SPEC = joinpath(@__DIR__, "spec_files", "phase3_benchmarks", "max2_simple.sl")

function report(label, r::GAResult)
    println("\n", "─"^70)
    println(label)
    println("─"^70)
    println("  solved          : ", r.solved)
    println("  program         : ", r.expr)
    println("  constraints viol: ", r.num_violated)
    println("  best fitness    : ", round(r.best_fitness, digits=4))
    println("  targeted/fallbk : ", r.targeted_hits, " / ", r.fallback_hits, " mutations")
    println("  distinct verified programs (≈Z3 batches): ", r.z3_calls)
end

println("="^70)
println("Z3-Guided Genetic Synthesis on max2  (expected: max(x0, x1))")
println("="^70)

println("\n[1/2] TARGETED mutation (uses Z3 counterexamples)")
targeted = run_ga_cegis(SPEC; pop_size=40, generations=40, max_depth=4,
                        targeted=true, seed=1, verbose=true)
report("TARGETED result", targeted)

println("\n[2/2] BASELINE: uniform mutation (no Z3 targeting)")
baseline = run_ga_cegis(SPEC; pop_size=40, generations=40, max_depth=4,
                        targeted=false, seed=1, verbose=true)
report("BASELINE result", baseline)

println("\n", "="^70)
println("Tip: vary the spec path to try other benchmarks, e.g.")
println("  spec_files/phase3_benchmarks/arith_simple.sl")
println("  spec_files/phase3_benchmarks/guard_simple.sl")
println("="^70)
