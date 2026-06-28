#!/usr/bin/env julia
"""
    scripts/run_cdgp_benchmarks.jl

Runs Counterexample-Driven Genetic Programming (`CEGIS.GeneticSearch.run_cdgp`)
across the max-family SyGuS benchmarks (max2 … max5, with max4 as the headline
case) and prints a results table. Each program that CDGP reports as solved is
independently re-verified against its spec with Z3 (`rulenode_to_smt2` →
`generate_cex_query` → `verify_query`); only an `:unsat` result counts as a
confirmed solution.

The harder specs need a bigger population, a deeper `depth_cap`, and a
wall-clock budget, so CDGP knobs are configured per benchmark below.

Run:  julia --project=. scripts/run_cdgp_benchmarks.jl
"""

CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

# HerbGrammar must be visible in Main: build_grammar_from_spec eval's the
# generated `@csgrammar` block in Main, and fails with `@csgrammar not defined`
# otherwise.
using HerbCore, HerbGrammar, HerbConstraints, HerbInterpret, HerbSearch, HerbSpecification
include(joinpath(CEGIS_SRC, "CEGIS.jl"))
import Arborist

const CG = CEGIS.CEXGeneration

# Selection strategies to compare. Thunks so each run gets a fresh strategy
# object; `nothing` ⇒ run_cdgp's default (TournamentSelection(tournament_size)).
const SELECTIONS = [
    ("tournament", () -> nothing),
    ("lexicase",   () -> Arborist.LexicaseSelection()),
]
const BENCHMARK_DIR = joinpath(CEGIS_ROOT, "spec_files", "phase3_benchmarks")

# Bool→Int coercion handled automatically.
CG.set_default_candidate_parser(CG.SymbolicCandidateParser())

# Per-benchmark CDGP configuration. `params` is splatted into `run_cdgp`; larger
# arities need more population, deeper trees, and a longer budget.
const BENCHMARKS = [
    (name = "max2", path = joinpath(BENCHMARK_DIR, "max2_simple.sl"),
     params = (pop_size = 100, generations = 200,  max_depth = 4, depth_cap = 6,  max_time = 60.0)),
    (name = "max3", path = joinpath(BENCHMARK_DIR, "max3_simple.sl"),
     params = (pop_size = 200, generations = 500,  max_depth = 5, depth_cap = 8,  max_time = 120.0)),
    (name = "max4", path = joinpath(BENCHMARK_DIR, "max4_simple.sl"),
     params = (pop_size = 300, generations = 2000, max_depth = 6, depth_cap = 10, max_time = 240.0)),
    (name = "max5", path = joinpath(BENCHMARK_DIR, "max5_simple.sl"),
     params = (pop_size = 400, generations = 3000, max_depth = 6, depth_cap = 12, max_time = 360.0)),
]

# Filter via CLI args, e.g. `julia ... run_cdgp_benchmarks.jl max4 max5`.
const SELECTED = isempty(ARGS) ? BENCHMARKS : filter(b -> b.name in ARGS, BENCHMARKS)

"""Independently confirm a CDGP-reported solution: re-derive grammar + spec and
run one full Z3 counterexample query. `:unsat` ⇒ correct for all inputs."""
function reverify(spec_path, genome)
    spec = CG.parse_spec_from_file(spec_path)
    grammar = CEGIS.build_grammar_from_spec(spec_path)
    func = spec.synth_funs[1].name
    smt = CG.rulenode_to_smt2(genome.tree, grammar)
    query = CG.generate_cex_query(spec, Dict(func => smt))
    return CG.verify_query(query).status
end

results = []
for b in SELECTED
    println("="^72)
    println(">>>> CDGP on $(b.name)   ($(relpath(b.path, CEGIS_ROOT)))")
    println("     params: ", b.params)
    if !isfile(b.path)
        println("     SKIP: spec file not found\n")
        for (sel_name, _) in SELECTIONS
            push!(results, (name = b.name, sel = sel_name, solved = false, verified = :missing,
                            expr = "", gens = 0, rounds = 0, tests = 0, z3 = 0, secs = 0.0))
        end
        continue
    end

    for (sel_name, mk) in SELECTIONS
        println("  -- selection: $sel_name")
        local res, secs
        try
            # Same seed across selections so the comparison is controlled.
            secs = @elapsed res = CEGIS.GeneticSearch.run_cdgp(
                b.path; seed = 1, verbose = false, selection = mk(), b.params...)
        catch e
            println("     ERROR: ", e, "\n")
            push!(results, (name = b.name, sel = sel_name, solved = false, verified = :error,
                            expr = "", gens = 0, rounds = 0, tests = 0, z3 = 0, secs = 0.0))
            continue
        end

        verified = :not_solved
        if res.solved && res.program !== nothing
            verified = try
                reverify(b.path, res.program)
            catch e
                println("     re-verify ERROR: ", e)
                :error
            end
        end

        println("     solved=$(res.solved)  re-verify=$(verified)  " *
                "gens=$(res.generations) rounds=$(res.rounds) z3=$(res.verifications)  " *
                "time=$(round(secs, digits = 1))s")
        res.program !== nothing && println("     program: $(res.expr)")
        push!(results, (name = b.name, sel = sel_name, solved = res.solved, verified = verified,
                        expr = res.expr, gens = res.generations, rounds = res.rounds,
                        tests = length(res.test_cases), z3 = res.verifications, secs = secs))
    end
    println()
end

println("="^72)
println("SUMMARY (CDGP: tournament vs lexicase)")
println("="^72)
println("  " * rpad("spec", 6) * rpad("selection", 12) * rpad("solved", 8) *
        rpad("verify", 12) * rpad("gens", 7) * rpad("rounds", 8) *
        rpad("tests", 7) * rpad("z3", 6) * "time")
for b in SELECTED
    for r in filter(x -> x.name == b.name, results)
        ok = r.solved && r.verified == :unsat
        mark = ok ? "✓" : "✗"
        println("  $(rpad(r.name, 4))$mark " * rpad(r.sel, 12) * rpad(string(r.solved), 8) *
                rpad(string(r.verified), 12) * rpad(string(r.gens), 7) *
                rpad(string(r.rounds), 8) * rpad(string(r.tests), 7) *
                rpad(string(r.z3), 6) * "$(round(r.secs, digits = 1))s")
    end
end
confirmed = count(r -> r.solved && r.verified == :unsat, results)
println("\nConfirmed solutions: $confirmed / $(length(results)) " *
        "($(length(SELECTED)) specs × $(length(SELECTIONS)) selections)")
