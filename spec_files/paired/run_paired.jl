#!/usr/bin/env julia
# run_paired.jl — specification STYLE as the only variable.
#
#   ours        spec_files/paired/ours/<problem>.sl   our single-constraint style
#   cdgp-split  spec_files/paired/cdgp/<problem>.sl   CDGP's case-split style
#
# The two sides of a pair carry an identical synth-fun signature and grammar
# block, and `build_pairs.py` proves with Z3 that they admit the same function,
# so any gap is attributable to how the specification decomposes into fitness
# cases -- not to the search space or the target.
#
#   julia --project=. spec_files/paired/run_paired.jl --problem median3
#   julia --project=. spec_files/paired/run_paired.jl --problem issorted4 #         --seeds 1:10 --time 60 --configs tests+tour,hybrid+lex-nowit

const PAIRED = @__DIR__
ROOT = normpath(joinpath(PAIRED, "..", ".."))
push!(LOAD_PATH, joinpath(ROOT, "src"))
using HerbCore, HerbGrammar, HerbConstraints, HerbInterpret, HerbSearch, HerbSpecification
using Printf, Statistics
include(joinpath(ROOT, "src", "CEGIS.jl"))
import Arborist
const CG = CEGIS.CEXGeneration
CG.set_default_candidate_parser(CG.SymbolicCandidateParser())

opts = Dict("seeds" => "1:10", "time" => "60", "problem" => "median3",
            "arms" => "ours,cdgp-split", "configs" => "tests+tour,hybrid+lex-nowit")
let i = 1
    while i <= length(ARGS); opts[ARGS[i][3:end]] = ARGS[i+1]; i += 2; end
end
SEEDS = occursin(':', opts["seeds"]) ?
    (p = split(opts["seeds"], ':'); collect(parse(Int, p[1]):parse(Int, p[2]))) :
    [parse(Int, s) for s in split(opts["seeds"], ",")]
BUDGET = parse(Float64, opts["time"])

PROBLEM = opts["problem"]
ARMS = Dict(
    "ours"       => joinpath(PAIRED, "ours", PROBLEM * ".sl"),
    "cdgp-split" => joinpath(PAIRED, "cdgp", PROBLEM * ".sl"),
)
CONFIGS = Dict(
    "tests+tour"       => (fitness = :tests,  sel = () -> nothing, extra = (;)),
    "hybrid+lex-nowit" => (fitness = :hybrid, sel = () -> Arborist.LexicaseSelection(),
                           extra = (witness_cases = false,)),
)
# GP knobs scale with arity: the correct program grows roughly linearly in the
# number of arguments. Identical across both arms, so the comparison stays fair.
gp_params(arity::Int) = (pop_size = arity <= 3 ? 200 : 400,
                         generations = 100_000,          # wall-clock is the real limit
                         generations_per_round = 10,
                         max_depth = arity <= 3 ? 5 : 6,
                         depth_cap = arity <= 4 ? 10 : 14)

function reverify(spec_path, grammar, tree)
    try
        spec = CG.parse_spec_from_file(spec_path)
        sf = spec.synth_funs[1]
        smt = CG.rulenode_to_smt2(tree, grammar; context_type = sf.sort == "Bool" ? :bool : :int)
        return CG.verify_query(CG.generate_cex_query(spec, Dict(sf.name => smt))).status
    catch e
        @warn "reverify failed" exception = e
        return :error
    end
end

function one_run(path, grammar, cfg, seed, start_symbol, arity)
    local res, secs
    try
        secs = @elapsed res = CEGIS.GeneticSearch.run_cdgp(
            path; seed = seed, verbose = false, grammar = grammar,
            start_symbol = start_symbol,
            fitness = cfg.fitness, engine = :ga, selection = cfg.sel(),
            max_time = BUDGET, gp_params(arity)..., cfg.extra...)
    catch e
        return (solved = false, claimed = false, secs = 0.0, gens = 0, tests = 0,
                z3 = 0, size = 0, expr = "", err = sprint(showerror, e))
    end
    claimed = res.solved && res.program !== nothing
    ok = claimed && reverify(path, grammar, res.program.tree) == :unsat
    return (solved = ok, claimed = claimed, secs = secs, gens = res.generations,
            tests = length(res.test_cases), z3 = res.verifications,
            size = res.program === nothing ? 0 : length(res.program.tree),
            expr = res.expr, err = "")
end

armnames  = String.(split(opts["arms"], ","))
confnames = String.(split(opts["configs"], ","))

println("$(PROBLEM) — specification style × config")
println("  seeds  : $(SEEDS)   budget $(BUDGET)s/run")
println("  paired : ", PAIRED)
prepped = Dict{String,Any}()
for a in armnames
    spec = CG.parse_spec_from_file(ARMS[a])
    g = CEGIS.GrammarBuilding.build_grammar_from_sygus(spec)
    ss = CEGIS.GrammarBuilding.sygus_start_symbol(spec)
    prepped[a] = (path = ARMS[a], grammar = g, start = ss,
                  nc = length(spec.constraints), arity = length(spec.synth_funs[1].params))
    @printf("  arm %-9s %2d constraints  %2d grammar rules  start=%s\n", a, length(spec.constraints), length(g.rules), ss)
end
println()

rows = NamedTuple[]
for a in armnames, cname in confnames
    arm, cfg = prepped[a], CONFIGS[cname]
    outs = [begin
                o = one_run(arm.path, arm.grammar, cfg, s, arm.start, arm.arity)
                print(o.solved ? "." : (isempty(o.err) ? "x" : "E")); flush(stdout); o
            end for s in SEEDS]
    println()
    won = filter(o -> o.solved, outs)
    @printf("  %-9s %-18s  %d/%d", a, cname, length(won), length(SEEDS))
    if !isempty(won)
        @printf("  median %5.1fs  %4d gens  %3d tests  %4d z3  size %2d",
                median([o.secs for o in won]), round(Int, median([o.gens for o in won])),
                round(Int, median([o.tests for o in won])),
                round(Int, median([o.z3 for o in won])),
                round(Int, median([o.size for o in won])))
    end
    nerr = count(o -> !isempty(o.err), outs)
    nunver = count(o -> o.claimed, outs) - length(won)
    nunver == 0 || @printf("  !! %d unverified", nunver)
    nerr == 0 || @printf("  !! %d errored (%s)", nerr, first(filter(o -> !isempty(o.err), outs)).err)
    println()
    isempty(won) || println("      e.g. ", won[1].expr)
    push!(rows, (arm = a, nc = arm.nc, config = cname, solved = length(won), runs = length(SEEDS),
                 secs = isempty(won) ? NaN : median([o.secs for o in won]),
                 gens = isempty(won) ? 0 : round(Int, median([o.gens for o in won])),
                 tests = isempty(won) ? 0 : round(Int, median([o.tests for o in won])),
                 z3 = isempty(won) ? 0 : round(Int, median([o.z3 for o in won])),
                 size = isempty(won) ? 0 : round(Int, median([o.size for o in won])), errors = nerr))
end

println("\n| spec | constraints | config | solved | median s | gens | tests | z3 calls | size |")
println("|---|---|---|---|---|---|---|---|---|")
for r in rows
    @printf("| %s | %d | %s | %d/%d | %s | %s | %s | %s | %s |\n", r.arm, r.nc, r.config,
            r.solved, r.runs,
            r.solved == 0 ? "—" : @sprintf("%.1f", r.secs),
            r.solved == 0 ? "—" : string(r.gens), r.solved == 0 ? "—" : string(r.tests),
            r.solved == 0 ? "—" : string(r.z3), r.solved == 0 ? "—" : string(r.size))
end
