#!/usr/bin/env julia
"""
sygus_to_z3_lite.jl  —  Generate counterexample query from parsed spec + candidate

USAGE
─────
  julia sygus_to_z3_lite.jl <spec.parsed.jl> --fun "<name>=<expr>" [--fun ...]

DESCRIPTION
───────────
Loads a pre-parsed Spec object (from parse_spec.jl) and generates a
verification query for the given candidate(s).

EXAMPLES
────────
  julia parse_spec.jl spec.sl spec.parsed.jl
  julia sygus_to_z3_lite.jl spec.parsed.jl --fun "f=if x1 = x2 then 0 else 1" > q.smt2
  z3 q.smt2
"""

using Serialization

# ══════════════════════════════════════════════════════════════════
# §1  S-EXPRESSION UTILITIES (minimal)
# ══════════════════════════════════════════════════════════════════

sexp_to_str(s)::String =
    s isa String ? s :
    s isa Vector ? (isempty(s) ? "()" : "(" * join(sexp_to_str.(s), " ") * ")") :
    string(s)

# ══════════════════════════════════════════════════════════════════
# §2  DATA STRUCTURES (identical to sygus_to_z3.jl)
# ══════════════════════════════════════════════════════════════════

struct SynthFun
    name   :: String
    params :: Vector{Tuple{String,String}}
    ret    :: String
end

struct FreeVar
    name :: String
    sort :: String
end

mutable struct Spec
    logic            :: String
    options          :: Vector{String}
    sort_decls       :: Vector{String}
    fun_decls        :: Vector{String}
    define_funs      :: Vector{String}
    define_funs_rec  :: Vector{String}
    datatypes        :: Vector{String}
    synth_funs       :: Vector{SynthFun}
    free_vars        :: Vector{FreeVar}
    constraints      :: Vector{String}
    ordered_preamble :: Vector{String}
end

# ══════════════════════════════════════════════════════════════════
# §3  CANDIDATE INFIX PARSER  →  SMT-LIB2 prefix string
# ═════════════════════════════════════════════════════════════════

function tokenise_sexp(text::String)::Vector{String}
    text = replace(text, r";[^\n]*" => "")
    tokens = String[]
    i = 1; n = length(text)
    while i <= n
        c = text[i]
        if isspace(c)
            i += 1
        elseif c ∈ ('(', ')')
            push!(tokens, string(c)); i += 1
        elseif c == '"'
            j = i + 1
            while j <= n
                text[j] == '"'  && (j += 1; break)
                text[j] == '\\' && (j += 1)
                j += 1
            end
            push!(tokens, text[i:j-1]); i = j
        elseif c == '|'
            j = i + 1
            while j <= n && text[j] != '|'; j += 1; end
            push!(tokens, text[i:j]); i = j + 1
        else
            j = i
            while j <= n && !isspace(text[j]) && text[j] ∉ ('(', ')', '"', '|')
                j += 1
            end
            tok = text[i:j-1]
            isempty(tok) || push!(tokens, tok)
            i = j
        end
    end
    tokens
end

function read_sexprs(text::String)::Vector{Any}
    toks = tokenise_sexp(text)
    pos  = Ref(1)
    out  = Any[]
    while pos[] <= length(toks)
        push!(out, _read1(toks, pos))
    end
    out
end

function _read1(toks::Vector{String}, pos::Ref{Int})::Any
    pos[] > length(toks) && error("Unexpected EOF in s-expression")
    t = toks[pos[]]; pos[] += 1
    if t == "("
        lst = Any[]
        while true
            pos[] > length(toks) && error("Unclosed '('")
            toks[pos[]] == ")" && (pos[] += 1; break)
            push!(lst, _read1(toks, pos))
        end
        return lst
    elseif t == ")"
        error("Unexpected ')' near token $(pos[]-1)")
    else
        return t
    end
end

function tokenise_infix(src::String)::Vector{String}
    tokens = String[]
    i = 1; n = length(src)
    while i <= n
        c = src[i]
        if isspace(c)
            i += 1
        elseif c ∈ ('(', ')', ',')
            push!(tokens, string(c)); i += 1
        elseif c ∈ ('<', '>', '!', '=')
            if i < n && src[i+1] == '='
                push!(tokens, src[i:i+1]); i += 2
            else
                push!(tokens, string(c)); i += 1
            end
        elseif c == '-'
            prev = isempty(tokens) ? "" : tokens[end]
            if prev ∈ ("", "(", ",", "then", "else",
                        "+", "-", "*", "=", "!=",
                        "<", "<=", ">", ">=", "and", "or", "not")
                j = i + 1
                while j <= n && isdigit(src[j]); j += 1; end
                push!(tokens, src[i:j-1]); i = j
            else
                push!(tokens, "-"); i += 1
            end
        else
            j = i
            while j <= n && !isspace(src[j]) && src[j] ∉ ('(', ')', ',')
                j += 1
            end
            push!(tokens, src[i:j-1]); i = j
        end
    end
    tokens
end

mutable struct IParser; toks::Vector{String}; pos::Int; end
_pk(p::IParser)       = p.pos <= length(p.toks) ? p.toks[p.pos] : ""
_nx(p::IParser)       = (t = _pk(p); p.pos += 1; t)
_ex(p::IParser, e)    = (t = _nx(p); t == e || error("Expected '$e' got '$t'"); t)

const IOPS = Dict(
    "or"  => (1,"or"), "and" => (2,"and"),
    "="   => (3,"="),  "!=" => (3,"distinct"),
    "<"   => (3,"<"),  "<=" => (3,"<="),
    ">"   => (3,">"),  ">=" => (3,">="),
    "+"   => (4,"+"),  "-"  => (4,"-"),  "*" => (5,"*"),
)

function _iexpr(p::IParser, min::Int=0)::String
    lhs = _iunary(p)
    while true
        op = _pk(p); info = get(IOPS, op, nothing)
        (info === nothing || info[1] <= min) && break
        _nx(p); lhs = "($(info[2]) $lhs $(_iexpr(p, info[1])))"
    end
    lhs
end

_iunary(p::IParser) =
    _pk(p) == "not" ? (_nx(p); "(not $(_iprimary(p)))") : _iprimary(p)

function _iprimary(p::IParser)::String
    t = _pk(p)
    if t == "if"
        _nx(p); c = _iexpr(p); _ex(p,"then"); th = _iexpr(p); _ex(p,"else")
        return "(ite $c $th $(_iexpr(p)))"
    end
    if t == "ite"
        _nx(p); _ex(p,"("); c = _iexpr(p); _ex(p,","); th = _iexpr(p)
        _ex(p,","); el = _iexpr(p); _ex(p,")"); return "(ite $c $th $el)"
    end
    if t == "("
        _nx(p); inner = _iexpr(p); _ex(p,")"); return inner
    end
    _nx(p)
    occursin(r"^-?\d+$", t) && return parse(Int,t) < 0 ? "(- $(abs(parse(Int,t))))" : t
    t ∈ ("true","false") && return t
    t
end

function candidate_to_smt2(src::String)::String
    src = String(strip(src))
    if startswith(src, "(")
        es = read_sexprs(src)
        length(es) == 1 || error("Expected exactly one expression, got $(length(es))")
        return sexp_to_str(es[1])
    end
    p = IParser(tokenise_infix(src), 1)
    r = _iexpr(p)
    p.pos <= length(p.toks) &&
        @warn "Trailing tokens in candidate: $(join(p.toks[p.pos:end], " "))"
    r
end

"""
Substitute free variable names with synthetic function parameter names in an expression.
Assumes parameters correspond to free variables in order.
E.g., y1→x1, y2→x2, y3→x3 (after parsing, we need to reverse this for the body)
"""
function substitute_params(expr::String, param_names::Vector{String}, 
                          free_var_names::Vector{String})::String
    # Build a mapping: free_var_name → param_name
    subst = Dict{String, String}()
    for (i, (pname, fvname)) in enumerate(zip(param_names, free_var_names))
        subst[fvname] = pname
    end
    
    # Tokenize and replace identifiers
    tokens = tokenise_sexp(expr)
    for i in eachindex(tokens)
        if haskey(subst, tokens[i])
            tokens[i] = subst[tokens[i]]
        end
    end
    
    # Reconstruct
    join(tokens, " ")
end

# ══════════════════════════════════════════════════════════════════
# §4  QUERY GENERATOR (identical to sygus_to_z3.jl)
# ══════════════════════════════════════════════════════════════════

function generate_query(spec::Spec, candidates::Dict{String,String},
                        spec_file::String)::String

    for sf in spec.synth_funs
        haskey(candidates, sf.name) ||
            error("No candidate provided for synth-fun '$(sf.name)'.\n" *
                  "Pass it with --fun \"$(sf.name)=<expr>\"")
    end

    out = IOBuffer()
    pl(s="")  = println(out, s)
    pr(s)     = print(out, s)

    pl("; -- generated by sygus_to_z3_lite.jl -----")
    pl("; source     : $spec_file")
    for sf in spec.synth_funs
        pl("; candidate  : $(sf.name) = $(candidates[sf.name])")
    end
    pl()

    if !isempty(spec.logic)
        pl("(set-logic $(spec.logic))")
        pl()
    end

    sygus_opt_prefixes = [":sygus", ":produce-models"]
    kept_opts = filter(o -> !any(p -> occursin(p, o), sygus_opt_prefixes), spec.options)
    if !isempty(kept_opts)
        foreach(pl, kept_opts); pl()
    end

    if !isempty(spec.ordered_preamble)
        pl("; -- preamble (sorts, helpers, uninterpreted functions) --")
        foreach(pl, spec.ordered_preamble)
        pl()
    end

    pl("; -- candidate implementations --")
    for sf in spec.synth_funs
        param_str = join(["($(n) $(t))" for (n,t) in sf.params], " ")
        param_names = [name for (name, _) in sf.params]
        free_var_names = [fv.name for fv in spec.free_vars]
        
        # Substitute free variable names with parameter names in candidate
        candidate_body = candidates[sf.name]
        substituted_body = substitute_params(candidate_body, param_names, free_var_names)
        
        pl("(define-fun $(sf.name) ($param_str) $(sf.ret)")
        pl("  $substituted_body)")
        pl()
    end

    if !isempty(spec.free_vars)
        pl("; -- free variables --")
        for fv in spec.free_vars
            pl("(declare-const $(fv.name) $(fv.sort))")
        end
        pl()
    end

    pl("; -- verification condition --")
    pl("; unsat  ->  candidate is correct for all inputs")
    pl("; sat    ->  model below is a concrete counterexample")
    if isempty(spec.constraints)
        pl("(assert false)   ; no constraints")
    elseif length(spec.constraints) == 1
        pl("(assert (not $(spec.constraints[1])))")
    else
        pl("(assert (not")
        pl("  (and")
        for c in spec.constraints
            pl("    $c")
        end
        pl("  )")
        pl("))")
    end
    pl()

    pl("(check-sat)")
    pl()

    if !isempty(spec.free_vars)
        var_list = join([fv.name for fv in spec.free_vars], " ")
        pl("; free-variable assignments")
        pl("(get-value ($var_list))")
    end

    pl("; synthesised function value(s) at the counterexample point")
    for sf in spec.synth_funs
        sort_queue = Dict{String,Vector{String}}()
        for fv in spec.free_vars
            push!(get!(sort_queue, fv.sort, String[]), fv.name)
        end
        sort_used = Dict{String,Int}()

        args = String[]
        for (pname, psort) in sf.params
            bucket = get(sort_queue, psort, String[])
            idx    = get(sort_used, psort, 0) + 1
            if idx <= length(bucket)
                sort_used[psort] = idx
                push!(args, bucket[idx])
            else
                push!(args, pname)
            end
        end

        pl("(get-value (($(sf.name) $(join(args, " ")))))")
    end

    String(take!(out))
end

# ══════════════════════════════════════════════════════════════════
# §5  ENTRY POINT
# ══════════════════════════════════════════════════════════════════

function usage()
    println(stderr, """
USAGE
  julia sygus_to_z3_lite.jl <spec.parsed.jl> --fun "<name>=<expr>" [--fun ...]

DESCRIPTION
  Loads a pre-parsed Spec object and generates a verification query.

EXPRESSION SYNTAX
  Literals     : 0  -3  true  false
  Arithmetic   : e + e   e - e   e * e   -e
  Comparison   : e = e   e != e   e < e   e <= e   e > e   e >= e
  Boolean      : e and e   e or e   not e
  If-then-else : if C then T else E   or   ite(C, T, E)
  Raw SMT-LIB2 : (ite (= x1 x2) 0 1)  — pass-through when starting with '('

EXAMPLES
  julia parse_spec.jl spec.sl spec.parsed.jl
  julia sygus_to_z3_lite.jl spec.parsed.jl --fun "f=if x1 = x2 then 0 else 1" \\
    > q.smt2
  z3 q.smt2
""")
end

function main()
    if length(ARGS) < 2 || ARGS[1] ∈ ("-h", "--help")
        usage()
        exit(length(ARGS) < 2 ? 1 : 0)
    end

    spec_file = ARGS[1]
    isfile(spec_file) || (println(stderr, "ERROR: file not found: $spec_file"); exit(1))

    # Deserialize the Spec object
    spec = open(f -> deserialize(f), spec_file)

    candidates = Dict{String,String}()
    i = 2
    while i <= length(ARGS)
        if ARGS[i] == "--fun"
            i + 1 > length(ARGS) &&
                (println(stderr, "ERROR: --fun requires an argument"); exit(1))
            spec_str = ARGS[i+1]; i += 2
            eq = findfirst('=', spec_str)
            eq === nothing &&
                (println(stderr, "ERROR: --fun argument must be 'name=expr', got: $spec_str"); exit(1))
            fname = String(strip(spec_str[1:eq-1]))
            fexpr = String(strip(spec_str[eq+1:end]))
            isempty(fname) &&
                (println(stderr, "ERROR: empty function name in --fun argument"); exit(1))
            candidates[fname] = candidate_to_smt2(fexpr)
        else
            println(stderr, "ERROR: unexpected argument '$(ARGS[i])'")
            usage(); exit(1)
        end
    end

    isempty(spec.synth_funs) &&
        (println(stderr, "ERROR: no synth-fun or synth-inv found in parsed spec"); exit(1))

    missing = [sf.name for sf in spec.synth_funs if !haskey(candidates, sf.name)]
    if !isempty(missing)
        println(stderr, "ERROR: missing candidate(s) for: $(join(missing, ", "))")
        println(stderr, "       Provide them with --fun \"name=expr\"")
        exit(1)
    end

    write(stdout, generate_query(spec, candidates, spec_file) * "\n")
end

main()
