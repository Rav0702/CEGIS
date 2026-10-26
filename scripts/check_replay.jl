#=
scripts/check_replay.jl — R12 replay regression check (BENCHMARK_METHODOLOGY.md §7): re-run stored
seeds of a run for a fixed number of generations under the current code and compare the per-generation
trajectory (tests, best fitness, best size) with the stored one. Decisions never read the clock, so
identical code paths replay identically (except where a Z3 check sits near its wall-clock timeout).

    julia --project=. scripts/check_replay.jl
=#
using HerbCore, HerbGrammar, CEGIS, Arborist
const GS = CEGIS.GeneticSearch
const ROOT = normpath(joinpath(@__DIR__, ".."))

const SPECS = Dict(  # registry settings
    "countpos4.split" => ("spec_files/case_split/countpos4_split.sl", 12),
    "array_search4"   => ("spec_files/case_split/array_search4.sl", 12),
    "above4"          => ("spec_files/multi_answer/above4.sl", 10),
    "max6"            => ("spec_files/phase3_benchmarks/max6_simple.sl", 14),
)
const V3 = (; guided = :patch, guided_rate = 0.3, guided_budget = 8, guided_min_pass = 8,
            guided_sites = :l3_sampled, guided_candidates = 6, guided_extra = 2, guided_max_pass = 32,
            guided_keep_cache = true, guided_shapes = :spec)
const CASES = [("main-lex", (;), ["array_search4", "max6"], [1, 2]),
               ("main-guided-v3", V3, ["max6", "array_search4"], [1, 2])]

function stored(run, spec, seed)
    rows = Dict{Int,Tuple{Int,Float64,Int}}()
    dir = joinpath(ROOT, "results", "runs", run, "generations")
    for f in filter(f -> startswith(f, spec * ".s"), readdir(dir))
        lines = readlines(joinpath(dir, f))
        hdr = split(lines[1], ",")
        ix(k) = findfirst(==(k), hdr)
        for l in lines[2:end]
            c = split(l, ",")
            parse(Int, c[ix("seed")]) == seed || continue
            rows[parse(Int, c[ix("gen")])] = (parse(Int, c[ix("tests")]), parse(Float64, c[ix("best_fitness")]),
                                              parse(Int, c[ix("best_size")]))
        end
    end
    return rows
end

bad = 0
for (run, kw, specs, seeds) in CASES, spec in specs, seed in seeds
    path, cap = SPECS[spec]
    p = joinpath(ROOT, path)
    sp = CEGIS.CEXGeneration.parse_spec_from_file(p)
    g = sp.synth_funs[1].grammar !== nothing ? CEGIS.GrammarBuilding.build_grammar_from_sygus(sp) : CEGIS.build_grammar_from_spec(p)
    ref = stored(run, spec, seed)
    isempty(ref) && (println("$run $spec seed $seed: no stored rows"); continue)
    G = min(40, maximum(keys(ref)))
    tr = GS.CDGPTrace()
    GS.run_cdgp(p; fitness = :tests, grammar = g, selection = Arborist.LexicaseSelection(), pop_size = 400,
                max_depth = 6, depth_cap = cap, generations = G, generations_per_round = 10, seed = seed,
                verbose = false, trace = tr, kw...)
    mism = [(tr.gen[i], (tr.tests[i], tr.best_fitness[i], tr.best_size[i]), ref[tr.gen[i]])
            for i in 1:length(tr) if haskey(ref, tr.gen[i]) &&
                (tr.tests[i], tr.best_fitness[i], tr.best_size[i]) != ref[tr.gen[i]]]
    n = count(i -> haskey(ref, tr.gen[i]), 1:length(tr))
    global bad += !isempty(mism)
    println("$run $spec seed $seed: $n generations compared, ",
            isempty(mism) ? "IDENTICAL" : "$(length(mism)) differ, first $(first(mism))")
end
println(bad == 0 ? "ALL REPLAYED" : "$bad seed(s) differ")
