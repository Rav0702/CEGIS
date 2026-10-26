# E6a (spec_knowledge/EXPERIMENTS.md): the plain-CEGIS side, deterministic, one run each.
#   bfs-<variant>  Herb BFSIterator (max depth 10) + Z3 oracle on the orig / case / caseguard / decoy grammar
#   decomposed     the deductive iterator with region guards (run_recipe_cegis(...; regions = true)) on orig
# Every solution is re-verified against the ORIGINAL spec by a separate z3 process. Run alone.
#
#     julia --project=. scripts/e6a_cegis.jl [max_time_s=300] [spec=spec_files/partial_knowledge/tiered3.sl]
#                                            [runs=orig,case,caseguard,decoy,decomposed] [out=e6a] [max_depth=10]
#
# E2 uses the same runner on the E1 specs: `runs` lists grammar variants (missing variant files are skipped) and
# optionally `decomposed`; results go to results/<out>/cegis_<stem>.tsv.
using HerbCore, HerbGrammar, HerbConstraints, HerbInterpret, HerbSearch, HerbSpecification
include(joinpath(@__DIR__, "..", "src", "CEGIS.jl"))
const CG = CEGIS.CEXGeneration
CG.set_default_candidate_parser(CG.SymbolicCandidateParser())
const ROOT = normpath(joinpath(@__DIR__, ".."))

max_time = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 300.0
spec_path = length(ARGS) >= 2 ? ARGS[2] : "spec_files/partial_knowledge/tiered3.sl"
runs = length(ARGS) >= 3 ? String.(split(ARGS[3], ",")) : ["orig", "case", "caseguard", "decoy", "decomposed"]
outname = length(ARGS) >= 4 ? ARGS[4] : "e6a"
bfs_depth = length(ARGS) >= 5 ? parse(Int, ARGS[5]) : 10
stem = replace(basename(spec_path), ".sl" => "")
orig = CG.parse_spec_from_file(joinpath(ROOT, spec_path))
fname = orig.synth_funs[1].name
grammar_of(path) = CEGIS.GrammarBuilding.build_grammar_from_sygus(CG.parse_spec_from_file(joinpath(ROOT, path)))

"""Independent check: the program, unfolded to SMT, against the original spec in a z3 subprocess."""
function recheck(prog, g)
    prog === nothing && return "-"
    smt = CG.rulenode_to_smt2(prog, g)
    return string(CG.verify_query(CG.generate_cex_query(orig, Dict(fname => smt))).status)
end

outdir = joinpath(ROOT, "results", outname); mkpath(outdir)
out = joinpath(outdir, "cegis_$stem.tsv")
io = open(out, "w")
println(io, join(["run", "status", "time_s", "counterexamples", "enumerations", "size", "recheck", "program"], '\t'))
emit(row) = (println(io, join(row, '\t')); flush(io); println(join(row[1:7], "  ")); flush(stdout))

# warm-up: compile the CEGIS loop and the Z3 path once (not timed)
let g = grammar_of(spec_path)
    redirect_stdout(devnull) do
        CEGIS.run_synthesis(CEGIS.CEGISProblem(joinpath(ROOT, spec_path)), BFSIterator(g, :Expr; max_depth = 3); max_time = 2.0,
                            use_direct_conversion = true)
    end
end

for variant in filter(!=("decomposed"), runs)
    path = variant == "orig" ? spec_path : "spec_files/enriched/$(stem)_$variant.sl"
    isfile(joinpath(ROOT, path)) || continue
    g = grammar_of(path)
    logf = joinpath(outdir, "cegis_$(stem)_bfs-$variant.log")
    local r
    t = @elapsed open(logf, "w") do lio
        r = redirect_stdout(lio) do
            # Direct RuleNode -> SMT conversion (as CDGP and the harness use). The default path (RuleNode ->
            # string -> SymbolicCandidateParser) fails on `&&` inside ifelse arguments and falls back to the
            # infix parser, which mistranslates such programs: wrong programs were accepted (2026-10-02).
            CEGIS.run_synthesis(CEGIS.CEGISProblem(joinpath(ROOT, path)), BFSIterator(g, :Expr; max_depth = bfs_depth);
                                max_time = max_time, use_direct_conversion = true)
        end
    end
    m = collect(eachmatch(r"\[enum=(\d+)\]", read(logf, String)))
    nenum = isempty(m) ? "" : m[end].captures[1]
    prog = r.status == CEGIS.cegis_success ? r.program : nothing
    emit(["bfs-$variant", string(r.status), string(round(t, digits = 2)), string(length(r.counterexamples)), nenum,
          prog === nothing ? "" : string(length(prog)), recheck(prog, g),
          prog === nothing ? "" : string(rulenode2expr(prog, g))])
end

if "decomposed" in runs
g = grammar_of(spec_path)
t = @elapsed r = CEGIS.run_recipe_cegis(joinpath(ROOT, spec_path); grammar = g, regions = true, leaf_depth = 5,
                                         max_time = max_time)
emit(["decomposed", r.solved ? "cegis_success" : (r.guided.no_patch == 1 ? "stuck" : "cegis_timeout"),
      string(round(t, digits = 2)), string(length(r.counterexamples)),
      string(get(r.guided, :leaf_enumerations, "")), r.program === nothing ? "" : string(length(r.program.tree)),
      recheck(r.solved ? r.program.tree : nothing, g), r.expr])
end
close(io)
println("wrote ", relpath(out, ROOT))
