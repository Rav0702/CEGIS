#!/usr/bin/env julia
#
# Family-agnostic driver for the scalable benchmark suite.
# =======================================================
# Climbs N within one family, reporting the highest N solved. Reuses the search from
# `iterative_seeded_max.jl` (`solve_spec`, scoring, the bank, round structure) and adds
# what is needed to run more than one family:
#
#   * grammars come from the benchmark file. The specs emitted by
#     `benchmarks/generate_suite.jl` declare their own grammar in the `synth-fun` body,
#     so there is no per-family grammar hardcoded here — `solve_spec(path; grammar=nothing)`
#     routes through `build_grammar_from_spec`, which now honours that body.
#   * seeds transfer between problems by *expression matching*
#     (`GrammarBuilding.remap_rulenode_by_expression`), not by the rule-index shift that
#     only ever held for the two max_N grammars.
#   * rounds are bounded by enumeration count, not wall clock. Earlier max_N runs showed
#     outcomes at N >= 8 flipping between identical commands, and the cause was isolated
#     to *where the timer cut the round* — rounds that end by finding a solution are
#     byte-identical across runs, rounds that end on the cap are not. Wall clock is kept
#     only as a safety net; see results/max_n_climbs/README.md.
#   * `--regime independent` disables seed transfer, because chained climbs couple
#     adjacent problems: in one 600 s run max8 *solving* caused max10 to *fail*, since
#     max8 exited early and max9 inherited a thinner bank.
#
# Usage:
#   julia --project scripts/run_suite.jl --family array_search
#   julia --project scripts/run_suite.jl --family max --granularity witness --from 3 --to 12
#   julia --project scripts/run_suite.jl --family piecewise --regime independent --equiv constraint
#
# Options (env vars from iterative_seeded_max.jl — EQUIV, USE_EGRAPH, ROUND_ENUM,
# MAX_DEPTH, MAX_SIZE, MAX_COST, ROUNDS, PROBLEM_TIME — still apply; the flags below
# set them per run):
#   --family      array_search | piecewise | max      (required)
#   --tier        d0 | d1 | d2                        (default d0)
#   --granularity conj | split | witness              (max only, default split)
#   --from / --to N range                             (default: the family's full range)
#   --regime      chained | independent               (default chained)
#   --equiv       observational | constraint | both   (default constraint)
#   --round-enum  enumerations per round              (default 200000)
#   --problem-time per-problem wall-clock safety net, seconds (default 600)
#   --round-time  wall-clock per round, seconds (default: the whole problem budget).
#                 Smaller values force several rounds inside one problem, and a round
#                 boundary is where the bank re-seeds the next round — the climbs
#                 recorded in results/max_n_climbs/ used ROUND_TIME=120 inside a 300 s
#                 problem cap, so reproducing them needs this set.
#   --stop-after  consecutive failures before giving up (default 2)
#   --csv         path for the per-problem summary CSV

CEGIS_ROOT = dirname(@__DIR__)
include(joinpath(CEGIS_ROOT, "scripts", "iterative_seeded_max.jl"))

using Printf

const GB = CEGIS.GrammarBuilding

# ─────────────────────────────────────────────────────────────────────────────
# Family descriptors
# ─────────────────────────────────────────────────────────────────────────────
#
# `size_estimate` is the node count of the family's reference solution, used only to
# size the search bounds; `depth_estimate` likewise. Both are deliberately generous —
# a bound below the solution makes the problem unsolvable for reasons that have nothing
# to do with the search.

struct Family
    name           :: String
    range          :: UnitRange{Int}
    path           :: Function   # (n, tier, granularity) -> spec path
    size_estimate  :: Function   # n -> node count of the reference solution
    depth_estimate :: Function   # n -> depth of the reference solution
end

const FAMILIES = Dict{String,Family}(
    # ite chain of length N: 5 nodes per branch plus the final literal.
    "array_search" => Family("array_search", 2:15,
        (n, tier, _) -> joinpath(CEGIS_ROOT, "benchmarks", "array_search_n", tier, "array_search$n.sl"),
        n -> 5n + 1,
        n -> n + 4),
    # ite chain of length N-1 over a single input.
    "piecewise" => Family("piecewise", 2:12,
        (n, tier, _) -> joinpath(CEGIS_ROOT, "benchmarks", "piecewise_n", tier, "piecewise$n.sl"),
        n -> max(5n - 4, 6),
        n -> n + 4),
    # Nested maximum: each solution embeds the previous one twice, so size doubles.
    "max" => Family("max", 3:16,
        (n, tier, gran) -> joinpath(CEGIS_ROOT, "benchmarks", "max_n", gran, tier, "max$n.sl"),
        solution_size,
        n -> 2n + 3),
)

# ─────────────────────────────────────────────────────────────────────────────
# Seed transfer
# ─────────────────────────────────────────────────────────────────────────────

"""
    suite_seeds(prev, grammar; top_k) :: Vector{RuleNode}

Seeds to carry from the previous problem into the next: its best program plus the top
building blocks from its bank, each remapped into the next problem's grammar by
expression. Blocks that cannot be expressed in the new grammar are skipped rather than
mangled — `try_remap_rulenode` returns `nothing` for them.
"""
function suite_seeds(prev, grammar::AbstractGrammar; top_k::Int = 12)::Vector{RuleNode}
    prev === nothing && return RuleNode[]
    out = RuleNode[]
    if prev.node isa RuleNode
        m = GB.try_remap_rulenode(prev.node, prev.grammar, grammar)
        m === nothing || push!(out, m)
    end
    for e in PS.building_blocks(prev.bank)
        length(out) >= top_k + 1 && break
        (e.size > 1 && e.program isa RuleNode) || continue
        m = GB.try_remap_rulenode(e.program, prev.grammar, grammar)
        (m === nothing || m in out) && continue
        push!(out, m)
    end
    return out
end

# ─────────────────────────────────────────────────────────────────────────────
# Climb
# ─────────────────────────────────────────────────────────────────────────────

function run_problem(fam::Family, n::Int, opts)
    path = fam.path(n, opts.tier, opts.granularity)
    isfile(path) || error("missing spec $path — run benchmarks/generate_suite.jl first")

    println("\n" * "="^72)
    println("$(fam.name)_$n   —   $path")
    println("="^72)
    flush(stdout)

    # The spec declares its grammar, so build it here (rather than letting solve_spec
    # do it) to have it on hand for remapping the incoming seeds.
    grammar = CEGIS.build_grammar_from_spec(path)
    seeds = suite_seeds(opts.prev, grammar; top_k = opts.top_k)
    isempty(seeds) || println("   carried over $(length(seeds)) seed(s) from the previous problem")

    return solve_spec(path;
        rounds        = opts.rounds,
        round_enum    = opts.round_enum,
        # By default the whole problem budget goes to one round and ROUND_ENUM is what
        # ends it; --round-time cuts rounds shorter, which re-seeds more often.
        round_time    = opts.round_time === nothing ? opts.problem_time : opts.round_time,
        max_total_time = opts.problem_time,
        grammar       = grammar,
        initial_seeds = seeds,
        max_depth     = fam.depth_estimate(n),
        max_size      = round(Int, 1.5 * fam.size_estimate(n)),
        max_cost      = opts.max_cost)
end

"""Header and one row per problem, appended as each problem finishes."""
csv_header() = "family,tier,granularity,regime,equiv,round_enum,n,solved,rounds,time_s,best_score,n_constraints,size"

function csv_row(fam::Family, opts, n::Int, r)
    best = isempty(r.history) ? nothing : r.history[end]
    join([fam.name, opts.tier, opts.granularity, opts.regime,
          get(ENV, "EQUIV", "constraint"), opts.round_enum, n,
          r.solved, r.round, round(r.time, digits = 2),
          best === nothing ? 0 : best.score,
          best === nothing ? 0 : best.n_total,
          best === nothing ? 0 : best.size], ",")
end

function climb(fam::Family, opts)
    results = Tuple{Int,Any}[]
    prev = nothing
    consecutive_failures = 0
    # The CSV is appended per problem rather than written at the end: a cell that is
    # killed mid-climb (a wedged problem, an out-of-memory) otherwise loses every
    # result it had already earned, which is exactly when the data matters most.
    if opts.csv !== nothing
        mkpath(dirname(opts.csv))
        open(opts.csv, "w") do io
            println(io, csv_header())
        end
    end
    for n in opts.from:opts.to
        opts = merge(opts, (; prev))
        r = run_problem(fam, n, opts)
        push!(results, (n, r))
        if opts.csv !== nothing
            open(opts.csv, "a") do io
                println(io, csv_row(fam, opts, n, r))
            end
            flush(stdout)
        end
        if r.solved
            println(">>> $(fam.name)_$n SOLVED in round $(r.round), $(round(r.time, digits=1))s")
            consecutive_failures = 0
        else
            println(">>> $(fam.name)_$n NOT solved after $(r.round) round(s), $(round(r.time, digits=1))s")
            consecutive_failures += 1
        end
        # Carry forward from the last problem that produced anything at all: a strong
        # partial program is still a useful building block.
        if opts.regime == "chained" && r.node !== nothing
            prev = r
        end
        if consecutive_failures >= opts.stop_after
            println("\n-- stopping: $consecutive_failures consecutive failure(s) --")
            break
        end
    end
    return results
end

# ─────────────────────────────────────────────────────────────────────────────
# Reporting
# ─────────────────────────────────────────────────────────────────────────────

function report(fam::Family, opts, results)
    println("\n" * "="^72)
    println("SUMMARY — family=$(fam.name) tier=$(opts.tier)" *
            (fam.name == "max" ? " granularity=$(opts.granularity)" : "") *
            " regime=$(opts.regime) equiv=$(get(ENV, "EQUIV", "constraint")) " *
            "round_enum=$(opts.round_enum)")
    println("="^72)
    solved = [n for (n, r) in results if r.solved]
    for (n, r) in results
        rounds_used = r.round
        best = isempty(r.history) ? nothing : r.history[end]
        score = best === nothing ? "-" : "$(best.score)/$(best.n_total)"
        @printf("  %-18s %-9s rounds=%-3d time=%7.1fs best=%-8s size=%d\n",
                "$(fam.name)_$n", r.solved ? "SOLVED" : "unsolved",
                rounds_used, r.time, score, best === nothing ? 0 : best.size)
    end
    println("\n  highest solved: ", isempty(solved) ? "none" : "$(fam.name)_$(maximum(solved))")

    opts.csv === nothing || println("  CSV: $(opts.csv)  (written per problem as the climb ran)")
    return results
end

# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

function parse_opts(args::Vector{String})
    family = nothing; tier = "d0"; granularity = "split"
    from = nothing; to = nothing
    regime = "chained"; equiv = "constraint"
    round_enum = 200_000; problem_time = 600.0; round_time = nothing
    stop_after = 2; csv = nothing; rounds = nothing; max_cost = 6.0; top_k = 12
    i = 1
    while i <= length(args)
        a = args[i]
        if     a == "--family";       family = args[i+1]; i += 2
        elseif a == "--tier";         tier = args[i+1]; i += 2
        elseif a == "--granularity";  granularity = args[i+1]; i += 2
        elseif a == "--from";         from = parse(Int, args[i+1]); i += 2
        elseif a == "--to";           to = parse(Int, args[i+1]); i += 2
        elseif a == "--regime";       regime = args[i+1]; i += 2
        elseif a == "--equiv";        equiv = args[i+1]; i += 2
        elseif a == "--round-enum";   round_enum = parse(Int, args[i+1]); i += 2
        elseif a == "--problem-time"; problem_time = parse(Float64, args[i+1]); i += 2
        elseif a == "--round-time";   round_time = parse(Float64, args[i+1]); i += 2
        elseif a == "--stop-after";   stop_after = parse(Int, args[i+1]); i += 2
        elseif a == "--rounds";       rounds = parse(Int, args[i+1]); i += 2
        elseif a == "--max-cost";     max_cost = parse(Float64, args[i+1]); i += 2
        elseif a == "--csv";          csv = args[i+1]; i += 2
        else error("unknown argument $a")
        end
    end
    family === nothing && error("--family is required (one of $(join(sort(collect(keys(FAMILIES))), ", ")))")
    haskey(FAMILIES, family) || error("unknown family $family")
    regime in ("chained", "independent") || error("--regime must be chained or independent")
    fam = FAMILIES[family]
    from = from === nothing ? first(fam.range) : from
    to   = to   === nothing ? last(fam.range)  : to
    ENV["EQUIV"] = equiv
    return fam, (; tier, granularity, from, to, regime, round_enum, problem_time, round_time,
                   stop_after, csv, max_cost, top_k, prev = nothing,
                   # One round per problem by default: with an enumeration bound rather
                   # than a timer, extra rounds only help when the bank gained seeds.
                   rounds = rounds === nothing ? 2 * max(to, 3) : rounds)
end

if abspath(PROGRAM_FILE) == @__FILE__
    fam, opts = parse_opts(copy(ARGS))
    report(fam, opts, climb(fam, opts))
end
