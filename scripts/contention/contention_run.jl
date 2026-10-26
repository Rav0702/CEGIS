#=
scripts/contention/contention_run.jl — one process of the contention measurement
(scripts/contention/run_contention.sh). Does an arm slow down more than others when 4
workers share the machine (the harness's --jobs 4)?

    julia --project=. scripts/contention/contention_run.jl ARM SPEC GENS MODE ID NPROC SYNCDIR OUT

MODE `solo`: runs seeds 1..NPROC one after another, alone. MODE `conc`: runs seed ID while
NPROC-1 other processes run theirs. Barrier before the measured run (every process has
compiled), and after it the process keeps running filler work until all are done, so every
measured run sees the full load. Fixed generation count + seed ⇒ identical work in both modes.
Appends `arm,spec,mode,seed,gens,elapsed_s` rows to OUT.
=#
using HerbCore, HerbGrammar, CEGIS, Arborist
const GS = CEGIS.GeneticSearch

const ARM, SPECNAME, GENS, MODE, ID, NPROC, SYNC, OUT =
    ARGS[1], ARGS[2], parse(Int, ARGS[3]), ARGS[4], parse(Int, ARGS[5]), parse(Int, ARGS[6]), ARGS[7], ARGS[8]

const SPECS = Dict(  # path, depth_cap — harness registry settings (pop 400, max_depth 6)
    "array_search4" => ("spec_files/case_split/array_search4.sl", 12),
    "max6"          => ("spec_files/phase3_benchmarks/max6_simple.sl", 14),
)
const ARMS = Dict(   # as in bench/common.jl ARMS (selection = lexicase for all four)
    "baseline-lex" => (; fitness = :tests),
    "lex-guided"   => (; fitness = :tests, guided = :patch, guided_rate = 0.3, guided_budget = 8, guided_min_pass = 8),
    "lex-percon"   => (; fitness = :tests, cex_mode = :per_constraint),
    "hybrid-ratio" => (; fitness = :hybrid, witness_cases = true, witness_policy = :ratio, witness_test_ratio = 0.5),
)

path, cap = SPECS[SPECNAME]
spec = CEGIS.CEXGeneration.parse_spec_from_file(path)
g = spec.synth_funs[1].grammar !== nothing ? CEGIS.GrammarBuilding.build_grammar_from_sygus(spec) :
    CEGIS.build_grammar_from_spec(path)
go(seed, gens) = GS.run_cdgp(path; ARMS[ARM]..., grammar = g, selection = Arborist.LexicaseSelection(),
                             pop_size = 400, max_depth = 6, depth_cap = cap, generations = gens,
                             generations_per_round = 10, seed = seed, verbose = false,
                             trace = GS.CDGPTrace())

go(99, 20)                                             # compile
record(seed, r, dt) = open(io -> println(io, join((ARM, SPECNAME, MODE, seed, r.generations, round(dt; digits = 3)), ",")), OUT, "a")

function main()
    if MODE == "solo"
        for seed in 1:NPROC
            t = time(); r = go(seed, GENS); record(seed, r, time() - t)
        end
    else
        touch(joinpath(SYNC, "ready_$ID"))
        while count(f -> startswith(f, "ready_"), readdir(SYNC)) < NPROC; sleep(0.05); end
        t = time(); r = go(ID, GENS); dt = time() - t
        touch(joinpath(SYNC, "done_$ID"))
        record(ID, r, dt)
        k = 0
        while count(f -> startswith(f, "done_"), readdir(SYNC)) < NPROC   # keep the load on
            go(1000 + k, 10); k += 1
        end
    end
end
main()
