# Inclusion rules 1 and 2 of the confirmatory phase (spec_knowledge/FULL_SCALE_PLAN.md, C1) for candidate specs:
#   1. knowledge in the file's own grammar: recipes (and region guards) the compiler extracts there;
#   2. the case chain fits the depth cap: (recipes + region guards) + 1 <= cap.
# Rule 3 (calibration in band) needs runs and is checked by the calibration chain.
#
#     julia --project=. scripts/check_inclusion.jl <cap> spec.sl [spec.sl ...]
using HerbGrammar, HerbCore
using CEGIS
const CG = CEGIS.CEXGeneration
const GS = CEGIS.GeneticSearch
const ROOT = normpath(joinpath(@__DIR__, ".."))

cap = parse(Int, ARGS[1])
println(rpad("spec", 52), rpad("recipes", 9), rpad("regions", 9), rpad("depth", 7), "rule 1, rule 2")
for path in ARGS[2:end]
    try
        sp = CG.parse_spec_from_file(joinpath(ROOT, path))
        g = CEGIS.GrammarBuilding.build_grammar_from_sygus(sp)
        k = length(GS.spec_answer_recipes(sp, g))
        r = length(GS.spec_region_guards(sp, g))
        depth = k + r + 1
        r1 = k + r > 0 ? "knowledge" : "NO KNOWLEDGE"
        r2 = depth <= cap ? "fits" : "TOO DEEP"
        println(rpad(path, 52), rpad(string(k), 9), rpad(string(r), 9), rpad(string(depth), 7), r1, ", ", r2)
    catch e
        println(rpad(path, 52), "ERROR: ", sprint(showerror, e)[1:min(end, 120)])
    end
end
