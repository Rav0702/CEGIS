#!/usr/bin/env julia
#
# Guided Search through Partial Specification Satisfaction
# ========================================================
# Demonstrates CEGIS.PartialSat:
#   A) score a candidate by HOW MANY spec constraints it satisfies (a Z3 query
#      per constraint), and
#   B) guided search — enumerate, score, bank the partial programs ("building
#      blocks"), surface a complementary cover, and stop at a full solution.

CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

using HerbCore, HerbGrammar, HerbSearch, HerbSpecification, HerbInterpret
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

const PS = CEGIS.PartialSat
const CEX = CEGIS.CEXGeneration
const SPEC_DIR = joinpath(CEGIS_ROOT, "spec_files", "phase3_benchmarks")

# Cost-biased bottom-up iterator so conditional solutions surface quickly.
function rule_costs_with_bias(grammar)
    costs = fill(1.0, length(grammar.rules))
    for (i, rule) in enumerate(grammar.rules)
        (rule isa Expr && rule.head === :call) || continue
        op = rule.args[1]
        op === :ifelse && (costs[i] = 0.2)
        op in (:<, :>, :<=, :>=, :(==)) && (costs[i] = 0.5)
    end
    costs
end

# ─────────────────────────────────────────────────────────────────────────────
println("="^70)
println("A) Per-constraint satisfaction (one Z3 query per constraint)")
println("="^70)

for (specname, candidates) in [
    ("max2_simple.sl",     ["x0", "x1", "(+ x0 x1)", "(ite (< x0 x1) x1 x0)"]),
    # ("symmetric_max.sl",   ["x", "y", "(ite (< x y) y x)"]),
    ("max3_simple.sl",     ["x", "y", "z",
                            "(ite (< x y) y x)",                                  # max(x,y): misses z
                            "(ite (< x y) (ite (< y z) z y) (ite (< x z) z x))"]), # full max3
]
    spec = CEX.parse_spec_from_file(joinpath(SPEC_DIR, specname))
    func = spec.synth_funs[1].name
    println("\n# $specname  ($(length(spec.constraints)) constraints, synth-fun `$func`)")
    for cand in candidates
        println("\n  candidate: $cand")
        r = PS.evaluate_partial_satisfaction(spec, Dict(func => cand); verbose = true)
        println("    => $(r.n_satisfied)/$(r.n_total)  ",
                "satisfied=$(findall(r.satisfied))  score=$(round(r.score, digits=2))")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
function run_guided(specname; max_enumerations, max_depth = 6)
    println("\n" * "="^70)
    println("B) Guided search: enumerate, score, bank building blocks ($specname)")
    println("="^70)

    path = joinpath(SPEC_DIR, specname)
    spec = CEX.parse_spec_from_file(path)
    grammar = CEGIS.build_grammar_from_spec(path)

    iterator = CostBasedBottomUpIterator(
        grammar, :Expr;
        max_depth = max_depth, max_size = 30, max_cost = Inf,
        current_costs = rule_costs_with_bias(grammar),
    )

    res = PS.guided_partial_search(spec, grammar, iterator;
        max_enumerations = max_enumerations, verbose = true, log_every = 50)

    println("\n--- Building-block bank (one representative per satisfied-subset) ---")
    for e in PS.building_blocks(res.bank)
        println("    $(e.result.n_satisfied)/$(e.result.n_total)  constraints $(findall(e.result.satisfied))  size=$(e.size)  $(e.expr)")
    end

    cover = PS.complementary_cover(res.bank)
    println("\n--- Complementary cover (blocks whose satisfied-sets union to all) ---")
    if cover === nothing
        println("    (banked blocks cannot jointly cover all constraints)")
    else
        for e in cover
            println("    covers $(findall(e.result.satisfied))  =>  $(e.expr)")
        end
    end

    println("\n--- Result ---")
    if res.full === nothing
        println("    No full solution within $(res.enumerated) enumerations.")
        println("    Best partial: $(res.bank.best.result.n_satisfied)/$(res.bank.best.result.n_total)  $(res.bank.best.expr)")
    else
        println("    FULL solution found: $(res.full.expr)  ($(res.full.result.n_satisfied)/$(res.full.result.n_total))")
    end
    return (; res, spec, grammar)
end

# Phase 2: once phase 1 (the 1500-enumeration partial-sat guided search) is done
# and did NOT find a full solution, collect the programs that satisfy >= half the
# constraints, SEED them into a bottom-up iterator, and run the iterator through
# the standard full-spec Z3 CEGIS loop (exactly like test_phase3_e2e_synthesis.jl:
# one regular Z3 verification per candidate, all-or-nothing), up to a very large
# enumeration budget. The seeds let the BU `combine` reach the full solution by
# building on the partial programs instead of from scratch.
# `max_depth` / `max_size` are bounded to the KNOWN max3 solution so the
# bottom-up space stays small (avoids the `combine` blow-up that comes with loose
# bounds). Bound is matched to the SEEDED solution `max(max(x,y), z)` =
# `ifelse(max(x,y) < z, z, max(x,y))` = depth 5, size 16 — one level deeper than
# the depth-4 hand form because the seed `max(x,y)` is itself depth 3. At depth 5
# this seeded form (cost ~4.7) is reachable and far cheaper than the non-seeded
# depth-4 form (cost ~12), so cost-ordered search reaches it first.
function seed_and_resume(specname, prior; expected, max_enumerations, max_depth = 5, max_size = 16)
    prior.res.full === nothing || return  # already solved in phase 1
    spec, grammar = prior.spec, prior.grammar
    path = joinpath(SPEC_DIR, specname)

    seeds = PS.collect_satisfying(prior.res.bank; threshold = 0.5)
    println("\n" * "="^70)
    println("C) Seed BU iterator with >=50%-satisfying blocks, verify via Z3 CEGIS ($specname)")
    println("="^70)
    println("    bounds: max_depth=$max_depth max_size=$max_size (matched to the depth-5/size-16 seeded solution)")
    println("    seeds ($(length(seeds))): ", [string(rulenode2expr(s, grammar)) for s in seeds])
    isempty(seeds) && (println("    no composite building blocks to seed."); return)

    problem = CEGIS.CEGISProblem(path; desired_solution = expected)
    iterator = PS.SeededCostBUIterator(
        grammar, :Expr;
        max_depth = max_depth, max_size = max_size, max_cost = Inf,
        current_costs = rule_costs_with_bias(grammar),
        seed_programs = seeds, seed_cost = 1.0,
    )

    result = CEGIS.run_synthesis(
        problem, iterator;
        max_enumerations = max_enumerations,
        use_direct_conversion = true,   # regular RuleNode→SMT-LIB2 Z3 calls, like test_phase3
        log_every = 10,             # progress line every 10 enumerations
    )

    status_str = "$(result.status)"
    println("\n--- Result (seeded + Z3 CEGIS) ---")
    if result.program !== nothing
        sol = string(HerbGrammar.rulenode2expr(result.program, grammar))
        match = (status_str == "cegis_success" && expected !== nothing) ?
            (sol == expected ? "MATCH" : "MISMATCH") : ""
        verified = status_str == "cegis_success" ? "✓" : "✗"
        println("  $verified status=$status_str  iters=$(result.iterations)")
        println("  Candidate: $sol  $match")
        expected !== nothing && println("  Expected:  $expected")
    else
        println("  ✗ status=$status_str  iters=$(result.iterations)  Candidate: NONE")
    end
    return result
end

run_guided("max2_simple.sl"; max_enumerations = 500)

max3 = run_guided("max3_simple.sl"; max_enumerations = 1500)
seed_and_resume("max3_simple.sl", max3;
    expected = "ifelse(x > y, ifelse(x > z, x, z), ifelse(y > z, y, z))",
    max_enumerations = 1_000_000)
