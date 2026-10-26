#=
scripts/rq1_coverage_survey.jl — RQ1: how much of a benchmark population does syntactic compilation cover?

For each LIA `.sl` file of a population:
  1. Parse it. When the synth-fun's parameters are not the declared variables but every application of f uses one
     argument list of distinct declared variables, rename the parameters positionally (the compiler's missing
     "positional mapping"; recorded as `renamed`).
  2. Compile recipes and region guards twice: in the general LIA grammar generated from the signature (what the
     specification itself determines) and, when the file declares one, in the file's own grammar (what can be
     delivered as productions).
  3. Compose the recipe chain ite(g1, t1, ... t_k) and verify it with a z3 subprocess (timeout).

Classes:
  stated        an unguarded recipe: the spec writes the answer as one expression
  complete      the composed chain verifies (unsat)
  partial       recipes or region guards exist, but the chain does not verify (sat), or only region guards exist
  unproven      the chain's verification timed out
  none          in the fragment, but no recipe and no region guard
  out of scope  several synth-funs, f applied to other arguments, or parameters that cannot be mapped
  error         the file could not be parsed or its grammar built

    julia --project=. scripts/rq1_coverage_survey.jl name=dir[,dir...] ...   (writes results/rq1_survey/<name>.tsv)
=#
using HerbCore, HerbGrammar, CEGIS, Printf
const GS = CEGIS.GeneticSearch
const CG = CEGIS.CEXGeneration
const ROOT = normpath(joinpath(@__DIR__, ".."))
const Z3_TIMEOUT_S = 10

"""Text span of the `(synth-fun …)` form (paren matching, `;` comments skipped)."""
function synthfun_span(txt)
    i = findfirst("(synth-fun", txt).start
    depth, j = 0, i
    while true
        c = txt[j]
        if c == ';'
            j = findnext('\n', txt, j)
        elseif c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
            depth == 0 && return i:j
        end
        j = nextind(txt, j)
    end
end

function applications!(out, s, fname)
    s isa Vector || return out
    !isempty(s) && s[1] == fname && push!(out, s[2:end])
    foreach(x -> applications!(out, x, fname), s)
    return out
end

"""If the parameters are not the declared variables, try a positional renaming; returns (path, renamed)."""
function maybe_rename(path, spec)
    sf = spec.synth_funs[1]
    params = String[p[1] for p in sf.params]
    fvs = String[fv.name for fv in spec.free_vars]
    Set(params) == Set(fvs) && return (path, false)
    apps = Any[]
    for c in spec.constraints
        applications!(apps, CG.read_sexprs(c)[1], sf.name)
    end
    args = unique(apps)
    (length(args) == 1 && all(a -> a isa AbstractString, args[1]) && allunique(args[1]) &&
     length(args[1]) == length(params) && all(in(fvs), args[1])) || return (path, false)
    map = Dict(zip(params, String.(args[1])))
    txt = read(path, String)
    sp = synthfun_span(txt)
    block = replace(txt[sp], r"[^\s()]+" => t -> get(map, t, t))
    tmp = tempname() * ".sl"
    write(tmp, txt[1:prevind(txt, first(sp))] * block * txt[nextind(txt, last(sp)):end])
    return (tmp, true)
end

"""z3 subprocess verdict on a query, with a hard timeout."""
function z3_status(query)
    f = tempname() * ".smt2"
    write(f, query)
    out = try
        read(ignorestatus(`z3 -T:$Z3_TIMEOUT_S $f`), String)
    finally
        rm(f; force = true)
    end
    tok = strip(first(split(out, '\n')))
    return tok in ("sat", "unsat") ? Symbol(tok) : startswith(tok, "timeout") || tok == "unknown" ? :timeout : :error
end

"""Classify a spec's knowledge under grammar `g`; returns (class, detail)."""
function classify(spec, g)
    sf = spec.synth_funs[1]
    rs = GS.spec_answer_recipes(spec, g)
    rs === nothing && return ("out of scope", "f applied to other arguments")
    rg = GS.spec_region_guards(spec, g)
    guarded = [r for r in rs if r.guard !== nothing]
    unguarded = [r for r in rs if r.guard === nothing]
    detail = "$(length(rs)) recipes, $(length(rg)) region guards"
    isempty(rs) && return (isempty(rg) ? "none" : "partial", detail)
    if !isempty(unguarded)
        st = z3_status(CG.generate_cex_query(spec, Dict(sf.name => CG.rulenode_to_smt2(unguarded[1].term, g))))
        st === :unsat && return ("stated", detail)
    end
    isempty(guarded) && return ("partial", detail)
    ite = GS._Rules(g).ops[:ite]
    ite == 0 && return ("partial", detail * "; grammar has no ite")
    prog = foldr((r, acc) -> RuleNode(ite, [r.guard, r.term, acc]), guarded[1:end-1]; init = guarded[end].term)
    st = z3_status(CG.generate_cex_query(spec, Dict(sf.name => CG.rulenode_to_smt2(prog, g))))
    cls = st === :unsat ? (isempty(rg) ? "complete" : "partial") : st === :sat ? "partial" :
          st === :timeout ? "unproven" : "error"
    return (cls, detail * ", chain $(st)")
end

function survey_file(path)
    spec = CG.parse_spec_from_file(path)
    length(spec.synth_funs) == 1 || return ("out of scope", "several synth-funs", "-", "-", false)
    p2, renamed = maybe_rename(path, spec)
    spec = CG.parse_spec_from_file(p2)
    own = spec.synth_funs[1].grammar !== nothing
    gen_cls, gen_det = try
        classify(spec, CEGIS.build_grammar_from_spec(p2))
    catch e
        ("error", "generated grammar: " * first(sprint(showerror, e), 60))
    end
    own_cls, own_det = !own ? ("-", "no grammar in file") : try
        classify(spec, CEGIS.GrammarBuilding.build_grammar_from_sygus(spec))
    catch e
        ("error", "own grammar: " * first(sprint(showerror, e), 60))
    end
    renamed && rm(p2; force = true)
    return (gen_cls, gen_det, own_cls, own_det, renamed)
end

const CLASSES = ["stated", "complete", "partial", "unproven", "none", "out of scope", "error", "skipped"]
# Files above this size are skipped and recorded: a 54 KB General-track invariant spec (inv_gen_ex23) never
# finished compiling, and Julia cannot interrupt a stuck computation inside one process.
const MAX_BYTES = 20_000

outdir = joinpath(ROOT, "results", "rq1_survey"); mkpath(outdir)
for arg in ARGS
    name, dirs = split(arg, "="; limit = 2)
    files = String[]
    for d in split(dirs, ",")
        if isfile(d)
            occursin(r"\(set-logic\s+LIA\)", read(d, String)) && push!(files, d)
            continue
        end
        for (r, _, fs) in walkdir(d), f in fs
            endswith(f, ".sl") || continue
            p = joinpath(r, f)
            occursin(r"\(set-logic\s+LIA\)", read(p, String)) && push!(files, p)
        end
    end
    sort!(files)
    io = open(joinpath(outdir, "$name.tsv"), "w")
    println(io, join(["file", "class_lia", "detail_lia", "class_own", "detail_own", "renamed", "seconds"], '\t'))
    cnt = Dict(c => 0 for c in CLASSES); cnt_own = Dict(c => 0 for c in vcat(CLASSES, ["-"]))
    nren = 0
    for p in files
        t = time()
        row = filesize(p) > MAX_BYTES ? ("skipped", "file larger than $(MAX_BYTES ÷ 1000) KB", "skipped", "-", false) : try
            survey_file(p)
        catch e
            ("error", "parse: " * first(replace(sprint(showerror, e), '\n' => ' '), 80), "-", "-", false)
        end
        gc, gd, oc, od, ren = row
        cnt[gc] += 1; cnt_own[oc] = get(cnt_own, oc, 0) + 1; nren += ren
        println(io, join([relpath(p, dirname(first(split(dirs, ",")))), gc, gd, oc, od, ren, round(time() - t; digits = 2)], '\t'))
        flush(io)
    end
    close(io)
    println(rpad(name, 24), length(files), " LIA files; renamed ", nren)
    println("   general LIA grammar: ", join(("$c $(cnt[c])" for c in CLASSES if cnt[c] > 0), ", "))
    println("   file's own grammar:  ", join(("$c $(cnt_own[c])" for c in vcat(CLASSES, ["-"]) if get(cnt_own, c, 0) > 0), ", "))
end
