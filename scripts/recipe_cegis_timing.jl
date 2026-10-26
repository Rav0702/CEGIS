# recipe-cegis on the specs of scripts/cvc5_compare.py: warm in-process wall time (median of `reps`), final
# program size, solved flag; comparable to cvc5's own `global::totalTime`. Run alone.
#
#     julia --project=. scripts/recipe_cegis_timing.jl [reps] [z3_timeout_s]
using HerbCore, HerbGrammar, HerbConstraints, HerbInterpret, HerbSearch, HerbSpecification
include(joinpath(@__DIR__, "..", "src", "CEGIS.jl"))
using Statistics
const CG = CEGIS.CEXGeneration

const ROOT = normpath(joinpath(@__DIR__, ".."))
const SPECS = [
    "max6" => "spec_files/phase3_benchmarks/max6_simple.sl",
    "above4" => "spec_files/multi_answer/above4.sl",
    "array_search4" => "spec_files/case_split/array_search4.sl",
    "countpos4.split" => "spec_files/case_split/countpos4_split.sl",
    ["max$n.sygus" => "spec_files/grammar_variants/max$(n)_sygus.sl" for n in (6, 7, 8, 10, 12, 16, 18, 20, 30)]...,
    ["above$n" => "spec_files/scaled/above$n.sl" for n in (8, 10, 12, 14, 16, 20)]...,
    "array_search20" => "spec_files/scaled/array_search20.sl",
]
reps = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 3
z3s = length(ARGS) >= 2 ? parse(Float64, ARGS[2]) : 60.0

function setup(path)
    sp = CG.parse_spec_from_file(joinpath(ROOT, path))
    has = sp.synth_funs[1].grammar !== nothing           # the bench worker's rule
    g = has ? CEGIS.GrammarBuilding.build_grammar_from_sygus(sp) : CEGIS.build_grammar_from_spec(joinpath(ROOT, path))
    st = has ? CEGIS.GrammarBuilding.sygus_start_symbol(sp) : :Expr
    return g, st
end
once(path, g, st) = @timed CEGIS.run_recipe_cegis(joinpath(ROOT, path); grammar = g, start_symbol = st,
                                                  max_time = 300.0, z3_timeout_ms = round(Int, z3s * 1000))

let (g, st) = setup(SPECS[1][2]); once(SPECS[1][2], g, st); end   # warm-up: compile everything once

out = joinpath(ROOT, "results", "cvc5", "recipe_cegis.tsv")
open(out, "w") do io
    println(io, join(["spec", "solved", "median_s", "times_s", "proposals", "size"], '\t'))
    for (name, path) in SPECS
        g, st = setup(path)
        runs = [once(path, g, st) for _ in 1:reps]
        r = runs[1].value
        ts = [x.time for x in runs]
        row = [name, string(all(x.value.solved for x in runs)), string(round(median(ts), digits = 3)),
               join(round.(ts, digits = 3), ","), string(r.verifications),
               r.program === nothing ? "" : string(length(r.program.tree))]
        println(io, join(row, '\t')); flush(io)
        println(join(row, "  ")); flush(stdout)
    end
end
println("wrote ", out)
