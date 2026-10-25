#!/usr/bin/env julia
#
# Run iterative seeded synthesis on a set of SIMPLE FORMAL-SPEC problems
# (universally-quantified constraints, not I/O examples). Reuses solve_spec and
# the helpers from iterative_seeded_max.jl.
#
# Usage: julia --project scripts/run_formal_problems.jl [name ...]
#   names: min2 abs clamp01 min3   (default: all)

include(joinpath(@__DIR__, "iterative_seeded_max.jl"))

# name => (spec path, bounds). Bounds are sized to each problem's solution shape;
# small single/two-var problems solve in round 1, min3 needs recombination.
const FORMAL = joinpath(CEGIS_ROOT, "benchmarks", "formal")
const PROBLEMS = [
    ("min2",     (path = joinpath(FORMAL, "min2.sl"),     rounds = 3, max_depth = 6, max_size = 20, max_cost = 6.0)),
    ("abs",      (path = joinpath(FORMAL, "abs.sl"),      rounds = 3, max_depth = 6, max_size = 20, max_cost = 6.0)),
    ("clamp01",  (path = joinpath(FORMAL, "clamp01.sl"),  rounds = 4, max_depth = 8, max_size = 24, max_cost = 7.0)),
    ("relu",     (path = joinpath(FORMAL, "relu.sl"),     rounds = 3, max_depth = 6, max_size = 20, max_cost = 6.0)),
    ("abs_diff", (path = joinpath(FORMAL, "abs_diff.sl"), rounds = 4, max_depth = 7, max_size = 22, max_cost = 7.0)),
    ("sign",     (path = joinpath(FORMAL, "sign.sl"),     rounds = 5, max_depth = 8, max_size = 24, max_cost = 7.0)),
    ("min3",     (path = joinpath(FORMAL, "min3.sl"),     rounds = 6, max_depth = 9, max_size = 24, max_cost = 7.0)),
]

round_enum = _envi("ROUND_ENUM", 60_000)
round_time = _envf("ROUND_TIME", 120.0)
problem_time = _envf("PROBLEM_TIME", 180.0)   # hard wall-clock cap per problem

wanted = isempty(ARGS) ? first.(PROBLEMS) : ARGS
results = Tuple{String,Any}[]

for (name, cfg) in PROBLEMS
    name in wanted || continue
    println("\n" * "="^72)
    println("$name   ($(name)) — formal spec: $(cfg.path)")
    println("="^72)
    flush(stdout)
    r = solve_spec(cfg.path; rounds = cfg.rounds, round_enum = round_enum,
        round_time = round_time, max_depth = cfg.max_depth,
        max_size = cfg.max_size, max_cost = cfg.max_cost,
        max_total_time = problem_time)
    if r.solved
        println(">>> $name SOLVED in round $(r.round), $(round(r.time, digits=1))s: $(r.program)")
    else
        println(">>> $name NOT solved after $(r.round) rounds, $(round(r.time, digits=1))s. Best: $(r.program)")
    end
    push!(results, (name, r))
    flush(stdout)
end

println("\n" * "="^72)
println("SUMMARY (formal-spec problems)")
for (name, r) in results
    status = r.solved ? "SOLVED (round $(r.round), $(round(r.time, digits=1))s)" : "unsolved"
    println("  $name: $status $(r.program === nothing ? "" : "— $(r.program)")")
end
