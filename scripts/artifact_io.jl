#=
scripts/artifact_io.jl — shared helpers for offline analyses of stored runs:
read a run's per-seed artifacts (JSON lines) and turn stored program strings back
into RuleNodes. Include after `using HerbCore, HerbGrammar`.
=#

const _AIO_ROOT = normpath(joinpath(@__DIR__, ".."))

"""Artifacts (one Dict per seed) of `spec` in stored run `run`."""
function read_artifacts_run(run::AbstractString, spec::AbstractString)
    out = Any[]
    d = joinpath(_AIO_ROOT, "results", "runs", run, "artifacts")
    isdir(d) || return out
    for f in readdir(d)
        startswith(f, spec * ".s") || continue
        rest = f[length(spec)+3:end]                   # "<k>.jsonl" — reject e.g. above4 vs above4x
        endswith(rest, ".jsonl") && all(isdigit, rest[1:end-6]) || continue
        for l in eachline(joinpath(d, f))
            isempty(strip(l)) || push!(out, parse_json(l))
        end
    end
    return out
end

# ── minimal JSON reader (objects, arrays, strings, numbers, true/false/null) ──
parse_json(s::AbstractString) = _jv(s, Ref(1))
_jskip(s, i) = (while i[] <= ncodeunits(s) && s[i[]] in (' ', '\n', '\t', '\r'); i[] += 1; end)
function _jv(s, i)
    _jskip(s, i)
    c = s[i[]]
    if c == '{'
        i[] += 1; d = Dict{String,Any}(); _jskip(s, i)
        s[i[]] == '}' && (i[] += 1; return d)
        while true
            _jskip(s, i); k = _jv(s, i); _jskip(s, i); i[] += 1
            d[k] = _jv(s, i); _jskip(s, i)
            s[i[]] == ',' ? (i[] += 1) : (i[] += 1; return d)
        end
    elseif c == '['
        i[] += 1; a = Any[]; _jskip(s, i)
        s[i[]] == ']' && (i[] += 1; return a)
        while true
            push!(a, _jv(s, i)); _jskip(s, i)
            s[i[]] == ',' ? (i[] += 1) : (i[] += 1; return a)
        end
    elseif c == '"'
        j = i[] + 1; buf = IOBuffer()
        while s[j] != '"'
            if s[j] == '\\'
                j += 1
                write(buf, s[j] == 'n' ? '\n' : s[j] == 't' ? '\t' : s[j])
            else
                write(buf, s[j])
            end
            j = nextind(s, j)
        end
        i[] = j + 1
        return String(take!(buf))
    elseif startswith(SubString(s, i[]), "true");  i[] += 4; return true
    elseif startswith(SubString(s, i[]), "false"); i[] += 5; return false
    elseif startswith(SubString(s, i[]), "null");  i[] += 4; return nothing
    end
    j = i[]
    while j <= ncodeunits(s) && (isdigit(s[j]) || s[j] in ('-', '.', 'e', 'E', '+')); j += 1; end
    t = s[i[]:j-1]; i[] = j
    return something(tryparse(Int, t), tryparse(Float64, t))
end

# ── program strings back to RuleNodes ──
# HerbGrammar's expr2rulenode rejects `&&` / `||` (Expr heads, not calls), which the
# SyGuS-built grammar uses for and/or; match rule shapes directly instead.
function shape_index(g)
    d = Dict{Any,Int}()
    for (i, r) in enumerate(g.rules)
        key = r isa Symbol ? (:sym, r) : r isa Bool ? (:bool, r) : r isa Integer ? (:int, Int(r)) :
              r.head === :call ? (:call, r.args[1], length(r.args) - 1) : (r.head, length(r.args))
        d[key] = i
    end
    return d
end

function to_rulenode(ex, d)
    ex isa Symbol && return RuleNode(d[(:sym, ex)])
    ex isa Bool && return RuleNode(d[(:bool, ex)])
    ex isa Integer && return RuleNode(d[(:int, Int(ex))])
    if ex.head === :call
        return RuleNode(d[(:call, ex.args[1], length(ex.args) - 1)], [to_rulenode(a, d) for a in ex.args[2:end]])
    end
    args = ex.args
    length(args) > 2 && return to_rulenode(Expr(ex.head, args[1], Expr(ex.head, args[2:end]...)), d)
    return RuleNode(d[(ex.head, 2)], [to_rulenode(a, d) for a in args])
end
