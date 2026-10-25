#!/usr/bin/env julia
#
# Observational vs. constraint-based equivalence in the bottom-up bank.
# =====================================================================
# Runs each max_N problem twice — once with each equivalence relation — and
# reports how many candidate programs each relation admits to the bank and how
# many it discards as equivalent.
#
#   observational : two programs are equivalent if they agree on a fixed sample
#                   of concrete inputs (32 points, seeded RNG).
#   constraint    : two programs are equivalent if they satisfy the same subset
#                   of the specification's constraints, each proved universally
#                   by Z3.
#
# ## Experimental controls
#
# The two relations cost very different amounts per candidate (constraint mode
# calls Z3; observational mode evaluates 32 points), so a wall-clock budget would
# hand observational mode several times more candidates and confound the
# comparison. Rounds are therefore bounded by ENUMERATION COUNT, and the time
# caps are disabled. This also makes the whole experiment deterministic — no
# round is ever cut mid-enumeration by a timer — which matters because the
# time-capped runs were not reproducible for N >= 8.
#
# By default each problem starts from the grammar terminals with NO seeds carried
# from the previous problem (CHAIN=0). That keeps the two arms comparable: both
# modes see identical starting conditions for every N, so a difference in `kept`
# is attributable to the relation and nothing else. CHAIN=1 instead reproduces
# the seeded pipeline, where problem N is seeded from N-1 — more realistic, but
# the arms diverge after the first problem where they disagree, and their gate
# statistics are then measured on different search spaces.
#
# Usage:
#   julia --project scripts/compare_equivalence.jl [Nmin Nmax]     (default 3 10)
#
# Env:
#   ROUND_ENUM   candidates per round, the binding budget   (default 15000)
#   ROUNDS       rounds per problem                         (default 3)
#   MAX_COST     cost bound                                 (default 6.0)
#   CHAIN        1 = seed problem N from N-1, 0 = independent (default 0)
#   OUT          CSV output path        (default /tmp/equivalence_comparison.csv)
#
# Output: a per-problem comparison table on stdout, plus a per-round CSV.

using Printf
include(joinpath(@__DIR__, "iterative_seeded_max.jl"))

const MODES = (:observational, :constraint)

_envs(k, d) = get(ENV, k, d)

"""
Run one (problem, mode) cell. Returns the result named tuple from `solve_spec`,
which carries `history` — one entry per round, including that round's gate
counters (reached / dropped / kept / signature time).
"""
function run_cell(n::Int, mode::Symbol; rounds::Int, round_enum::Int,
                  max_cost::Float64, seeds::Vector{RuleNode})
    path = joinpath(CEGIS_ROOT, "benchmarks", "max_n", "max$n.sl")
    isfile(path) || error("missing spec: $path")
    ENV["EQUIV"] = String(mode)
    println("\n" * "="^74)
    println("max$n  |  equivalence = $mode  |  seeds carried in = $(length(seeds))")
    println("="^74)
    flush(stdout)
    return solve_spec(path;
        rounds, round_enum,
        round_time = Inf,              # enumeration count is the only budget
        max_total_time = Inf,
        grammar = max_n_grammar(n),
        initial_seeds = seeds,
        max_depth = _envi("MAX_DEPTH", 2n + 3),
        max_size = _envi("MAX_SIZE", round(Int, 1.5 * solution_size(n))),
        max_cost = max_cost)
end

function main()
    nmin = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 3
    nmax = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 10
    rounds = _envi("ROUNDS", 3)
    round_enum = _envi("ROUND_ENUM", 15_000)
    max_cost = _envf("MAX_COST", 6.0)
    chain = _envs("CHAIN", "0") != "0"
    out = _envs("OUT", "/tmp/equivalence_comparison.csv")

    println("Equivalence comparison: observational vs. constraint")
    println("  problems      max$nmin .. max$nmax")
    println("  budget        $round_enum candidates/round, $rounds round(s)/problem, no time cap")
    println("  cost bound    $max_cost")
    println("  seeding       ", chain ? "CHAINED (problem N seeded from N-1, per mode)" :
                                       "INDEPENDENT (every problem starts from terminals)")
    println("  csv           $out")

    results = Dict{Tuple{Int,Symbol},Any}()
    prev = Dict{Symbol,Any}(m => nothing for m in MODES)

    for n in nmin:nmax, mode in MODES
        seeds = RuleNode[]
        if chain && prev[mode] !== nothing
            seeds = carry_over_seeds(prev[mode], n - 1, n)
        end
        r = run_cell(n, mode; rounds, round_enum, max_cost, seeds)
        results[(n, mode)] = r
        chain && r.node !== nothing && (prev[mode] = r)
    end

    # ---------------------------------------------------------------- CSV
    open(out, "w") do io
        println(io, "N,mode,round,reached,dropped,kept,drop_pct,sig_time_s," *
                    "enumerated,scored,subsets,best_score,n_total,best_size,elapsed_s,solved")
        for n in nmin:nmax, mode in MODES
            r = results[(n, mode)]
            for h in r.history
                pct = h.reached == 0 ? 0.0 : round(100 * h.dropped / h.reached, digits=2)
                println(io, join([n, mode, h.round, h.reached, h.dropped, h.kept, pct,
                                  round(h.sigtime, digits=2), h.enumerated, h.scored,
                                  h.subsets, h.score, h.n_total, h.size,
                                  round(h.elapsed, digits=2), r.solved], ","))
            end
        end
    end

    # -------------------------------------------------------------- summary
    tot(h, f) = sum(getfield(x, f) for x in h; init = 0)
    println("\n" * "="^100)
    println("KEPT-PROGRAM COMPARISON  (per problem, summed over rounds)")
    println("="^100)
    @printf("%-6s | %-28s | %-28s | %s\n", "", "observational", "constraint", "ratio")
    @printf("%-6s | %8s %8s %6s | %8s %8s %6s | %s\n",
            "prob", "reached", "dropped", "kept", "reached", "dropped", "kept", "kept obs/con")
    println("-"^100)
    for n in nmin:nmax
        o = results[(n, :observational)]; c = results[(n, :constraint)]
        ok, ck = tot(o.history, :kept), tot(c.history, :kept)
        @printf("max%-3d | %8d %8d %6d | %8d %8d %6d | %5.1fx\n", n,
                tot(o.history, :reached), tot(o.history, :dropped), ok,
                tot(c.history, :reached), tot(c.history, :dropped), ck,
                ck == 0 ? NaN : ok / ck)
    end

    println("\nDROP RATE, SIGNATURE COST, AND OUTCOME")
    @printf("%-6s | %-24s | %-24s\n", "", "observational", "constraint")
    @printf("%-6s | %7s %8s %7s | %7s %8s %7s\n",
            "prob", "drop%", "sig-time", "outcome", "drop%", "sig-time", "outcome")
    println("-"^72)
    for n in nmin:nmax
        row = String[]
        for mode in MODES
            r = results[(n, mode)]
            re_, dr = tot(r.history, :reached), tot(r.history, :dropped)
            best = isempty(r.history) ? nothing : r.history[end]
            outcome = r.solved ? "solved r$(r.round)" :
                      (best === nothing ? "-" : "$(best.score)/$(best.n_total)")
            push!(row, @sprintf("%6.1f%% %7.1fs %7s",
                                re_ == 0 ? 0.0 : 100 * dr / re_,
                                tot(r.history, :sigtime), outcome))
        end
        @printf("max%-3d | %s | %s\n", n, row[1], row[2])
    end

    # Saturation: rounds where the relation admitted nothing at all.
    println("\nSATURATED ROUNDS (kept = 0 — no candidate could enter the bank)")
    any_sat = false
    for n in nmin:nmax, mode in MODES
        for h in results[(n, mode)].history
            if h.kept == 0
                println("  max$n $mode round $(h.round): reached=$(h.reached), kept=0")
                any_sat = true
            end
        end
    end
    any_sat || println("  none")

    println("\nCSV written to $out")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
