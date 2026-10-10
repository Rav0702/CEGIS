#!/usr/bin/env julia
#
# Turn the per-problem CSVs written by run_suite.jl into the suite's results table.
# Reading the table off the CSVs rather than transcribing it from logs keeps the
# reported numbers tied to what actually ran.
#
# Usage: julia --project scripts/summarise_suite.jl [results/suite]

const DIR = length(ARGS) >= 1 ? ARGS[1] : joinpath(dirname(@__DIR__), "results", "suite")

struct Row
    family::String; tier::String; granularity::String; regime::String
    equiv::String; round_enum::String; n::Int; solved::Bool
    rounds::Int; time_s::Float64; best::Int; n_constraints::Int; size::Int
end

function read_rows(path)
    rows = Row[]
    for (i, line) in enumerate(eachline(path))
        i == 1 && continue                      # header
        isempty(strip(line)) && continue
        f = split(line, ",")
        length(f) == 13 || continue
        push!(rows, Row(f[1], f[2], f[3], f[4], f[5], f[6], parse(Int, f[7]),
                        parse(Bool, f[8]), parse(Int, f[9]), parse(Float64, f[10]),
                        parse(Int, f[11]), parse(Int, f[12]), parse(Int, f[13])))
    end
    rows
end

cells = Dict{String,Vector{Row}}()
for file in sort(readdir(DIR))
    endswith(file, ".csv") || continue
    rows = read_rows(joinpath(DIR, file))
    isempty(rows) || (cells[file] = rows)
end

isempty(cells) && (println("no CSVs in $DIR"); exit(0))

println("| family | granularity | equiv | regime | highest solved | per-problem (N: time) | first failure |")
println("|---|---|---|---|---|---|---|")
for file in sort(collect(keys(cells)))
    rows = cells[file]
    r1 = rows[1]
    solved = [r for r in rows if r.solved]
    failed = [r for r in rows if !r.solved]
    highest = isempty(solved) ? "none" : "**$(r1.family)_$(maximum(r.n for r in solved))**"
    times = join(["$(r.n): $(round(r.time_s, digits=1))s" for r in solved], ", ")
    firstfail = isempty(failed) ? "—" :
        "$(r1.family)_$(failed[1].n) at $(failed[1].best)/$(failed[1].n_constraints)"
    println("| $(r1.family) | $(r1.granularity) | $(r1.equiv) | $(r1.regime) | $highest | $times | $firstfail |")
end

println()
total = sum(length(v) for v in values(cells))
solved_total = sum(count(r -> r.solved, v) for v in values(cells))
println("$solved_total of $total problem attempts solved, across $(length(cells)) cell(s).")
