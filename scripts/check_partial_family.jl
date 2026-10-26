# Check the partial-knowledge family (scripts/gen_partial_family.py): what the compiler gets, that the known
# solution verifies, whether the spec is single-answer, and how decomposed CEGIS fares (spec_knowledge/, E6b).
#
#     julia --project=. scripts/check_partial_family.jl [max_time_s=120] [leaf_depth=5] [bfs|oe] [files...]
using HerbCore, HerbGrammar, HerbConstraints, HerbInterpret, HerbSearch, HerbSpecification
include(joinpath(@__DIR__, "..", "src", "CEGIS.jl"))
const CG = CEGIS.CEXGeneration
const GS = CEGIS.GeneticSearch
const ROOT = normpath(joinpath(@__DIR__, ".."))

max_time = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 120.0
leaf_depth = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 5
mode = length(ARGS) >= 3 && ARGS[3] in ("bfs", "oe", "unif") ? Symbol(ARGS[3]) : :bfs
rest = length(ARGS) >= 3 && ARGS[3] in ("bfs", "oe", "unif") ? ARGS[4:end] : ARGS[3:end]
files = !isempty(rest) ? rest :
        sort(filter(f -> endswith(f, ".sl"), readdir(joinpath(ROOT, "spec_files", "partial_knowledge", "family"); join = true)))

# warm-up (compile) on the first file
let p = files[1], sp = CG.parse_spec_from_file(p)
    CEGIS.run_recipe_cegis(p; grammar = CEGIS.GrammarBuilding.build_grammar_from_sygus(sp), regions = true, max_time = 5.0,
                           leaf_search = mode)
end

println("leaf search: ", mode)
println(join(["spec", "recipes", "guards", "solution", "single", "decomposed", "time_s", "cex", "leaf_enum", "recheck"], '\t'))
for p in files
    sp = CG.parse_spec_from_file(p)
    g = CEGIS.GrammarBuilding.build_grammar_from_sygus(sp)
    fname = sp.synth_funs[1].name
    nr = length(something(GS.spec_answer_recipes(sp, g), []))
    ng = length(GS.spec_region_guards(sp, g))
    m = match(r"; Known solution: (.*)", read(p, String))
    sol = m === nothing ? "-" : string(CG.verify_query(CG.generate_cex_query(sp, Dict(fname => String(m.captures[1])))).status)
    single = try GS.spec_single_answer(sp) catch; "n/a (relational)" end
    t = @elapsed r = CEGIS.run_recipe_cegis(p; grammar = g, regions = true, leaf_depth = leaf_depth, max_time = max_time,
                                             leaf_search = mode)
    st = r.solved ? "solved" : (r.guided.no_patch == 1 ? "stuck" : "timeout")
    re = r.solved ? string(CG.verify_query(CG.generate_cex_query(sp, Dict(fname => CG.rulenode_to_smt2(r.program.tree, g)))).status) : "-"
    println(join([basename(p), nr, ng, sol, single, st, round(t, digits = 2), length(r.counterexamples),
                  get(r.guided, :leaf_enumerations, 0), re], '\t'))
    flush(stdout)
end
