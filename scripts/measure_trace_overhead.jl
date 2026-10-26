#=
scripts/measure_trace_overhead.jl — how much of the timed search the harness's own
instrumentation costs. The worker runs `run_cdgp(...; trace=CDGPTrace())` inside the clock
(everything else — validation, CSV rows, artifacts, re-verification — runs after it). With a
fixed generation count and seed the search is deterministic, so running it with and without
the trace does identical work and the time difference is the trace's cost.

    julia --project=. scripts/measure_trace_overhead.jl
=#
using HerbCore, HerbGrammar, CEGIS, Arborist, Printf, Statistics
const GS = CEGIS.GeneticSearch

grammar_for(p, spec) = spec.synth_funs[1].grammar !== nothing ?
    CEGIS.GrammarBuilding.build_grammar_from_sygus(spec) : CEGIS.build_grammar_from_spec(p)

const CASES = [  # (spec, generations, depth_cap) — harness settings, pop 400, max_depth 6
    ("spec_files/case_split/array_search4.sl", 150, 12),
    ("spec_files/phase3_benchmarks/max6_simple.sl", 150, 14),
]
const REPS = 2

for (p, gens, cap) in CASES
    spec = CEGIS.CEXGeneration.parse_spec_from_file(p)
    g = grammar_for(p, spec)
    for guided in (:none, :patch)
        ng = guided === :patch && occursin("max6", p) ? 50 : gens   # guided max6 generations cost ~1 s
        run(tr, seed) = GS.run_cdgp(p; grammar = g, selection = Arborist.LexicaseSelection(),
                                    pop_size = 400, max_depth = 6, depth_cap = cap,
                                    generations = ng, generations_per_round = 10, seed = seed,
                                    verbose = false, guided = guided, trace = tr)
        run(GS.CDGPTrace(), 99); run(nothing, 99)            # compile both paths first
        with = Float64[]; without = Float64[]; same = true
        for rep in 1:REPS, seed in (1, 2)
            # alternate the order so drift (thermal, background) hits both sides equally
            order = isodd(rep) ? (:with, :without) : (:without, :with)
            local gw, go
            for o in order
                t = time()
                r = o === :with ? run(GS.CDGPTrace(), seed) : run(nothing, seed)
                dt = time() - t
                o === :with ? (push!(with, dt); gw = r.generations) : (push!(without, dt); go = r.generations)
            end
            same &= gw == go
        end
        d = (with .- without) ./ without
        @printf("%-18s %-6s gens %d: with trace %.2f s, without %.2f s (medians over %d); overhead median %+.1f%% (range %+.1f%% .. %+.1f%%)%s\n",
                basename(p), guided, ng, median(with), median(without), length(with),
                100median(d), 100minimum(d), 100maximum(d), same ? "" : "  [generation counts differ!]")
    end
end
