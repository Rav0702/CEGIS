#!/usr/bin/env julia
"""
Test script: E-graph–derived constraints (EGraphPruning) on max2 / max3.

Pipeline under test (the research question):
    e-graph equality saturation over small grammar patterns
        → equivalence classes (structural redundancies)
        → compiled into HerbConstraints (Forbidden / Ordered / rule elimination)
        → solver prunes the search space at the syntactic level.

For each benchmark this script reports:
1. The automatically derived constraints (with provenance).
2. Search-space size (number of enumerated candidates) up to a fixed depth,
   with and without the derived constraints.
3. A full CEGIS run with the derived constraints, to confirm the solution is
   still found (completeness-modulo-equivalence sanity check).
"""

CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

using HerbCore, HerbGrammar, HerbSearch, HerbSpecification, HerbInterpret, HerbConstraints
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

const SPEC_DIR = joinpath(CEGIS_ROOT, "spec_files", "phase3_benchmarks")

const BENCHMARKS = [
    # (name = "max2", path = joinpath(SPEC_DIR, "max2_simple.sl"), expected = "ifelse(x0 > x1, x0, x1)"),
    (name = "max3", path = joinpath(SPEC_DIR, "max3_simple.sl"), expected = "ifelse(x > y, ifelse(x > z, x, z), ifelse(y > z, y, z))"),
]

CEGIS.CEXGeneration.set_default_candidate_parser(CEGIS.CEXGeneration.SymbolicCandidateParser())

const COUNT_DEPTH = 3        # depth for search-space counting
const COUNT_CAP = 100_000_000  # safety cap for counting
const SYNTH_DEPTH = 5        # depth for the CEGIS run
const PATTERN_DEPTH = 3      # pattern depth for e-graph derivation

function count_programs(grammar, depth)
    n = 0
    for _ in BFSIterator(grammar, :Expr, max_depth=depth)
        n += 1
        n >= COUNT_CAP && break
    end
    return n
end

results = []
for bench in BENCHMARKS
    println(">"^4, " Benchmark: $(bench.name)")

    # Baseline grammar (no constraints)
    base_grammar = CEGIS.build_grammar_from_spec(bench.path)
    baseline_count = count_programs(base_grammar, COUNT_DEPTH)
    println("      Baseline programs (depth ≤ $COUNT_DEPTH): $baseline_count")

    # Derive constraints via e-graph saturation
    grammar = CEGIS.build_grammar_from_spec(bench.path)
    t_derive = @elapsed derived = CEGIS.EGraphPruning.add_derived_constraints!(grammar; max_depth=PATTERN_DEPTH)
    println("      Derived $(length(derived)) constraints in $(round(t_derive, digits=1))s:")
    for (i, d) in enumerate(derived)
        println("        $(lpad(i, 2)). [$(d.kind)] $(d.description)")
    end

    pruned_count = count_programs(grammar, COUNT_DEPTH)
    reduction = baseline_count > 0 ? round(100 * (1 - pruned_count / baseline_count), digits=1) : 0.0
    println("      Pruned programs   (depth ≤ $COUNT_DEPTH): $pruned_count  (−$reduction%)")

    # Full CEGIS run with derived constraints
    problem = CEGIS.CEGISProblem(bench.path; desired_solution = bench.expected)
    iterator = CEGIS.IteratorConfig.create_iterator(
        CEGIS.IteratorConfig.BFSIteratorConfig(max_depth=SYNTH_DEPTH), grammar, :Expr)
    result = CEGIS.run_synthesis(problem, iterator;
        max_enumerations = 1_000_000, use_direct_conversion = true)

    solution = result.program === nothing ? nothing :
               string(HerbGrammar.rulenode2expr(result.program, grammar))
    push!(results, (
        name = bench.name,
        status = string(result.status),
        iters = result.iterations,
        n_constraints = length(derived),
        baseline = baseline_count,
        pruned = pruned_count,
        reduction = reduction,
        solution = solution,
        expected = bench.expected,
    ))
    println()
end

println("\n", "="^72)
println("SUMMARY (e-graph derived constraints)")
println("="^72)
for r in results
    ok = r.status == "cegis_success" ? "✓" : "✗"
    println("  $ok $(r.name): status=$(r.status), iters=$(r.iters), constraints=$(r.n_constraints)")
    println("      Search space (depth ≤ $COUNT_DEPTH): $(r.baseline) → $(r.pruned)  (−$(r.reduction)%)")
    println("      Found:    $(r.solution)")
    println("      Expected: $(r.expected)")
end
println("="^72)
