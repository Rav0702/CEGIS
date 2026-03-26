#!/usr/bin/env julia
"""
sygus_to_z3.jl  —  generic SyGuS-v2 → Z3 SMT-LIB2 counterexample query generator

USAGE
─────
  julia sygus_to_z3.jl <file.sl> --fun "<name>=<expr>" [--fun ...]

  One --fun is required per synth-fun / synth-inv in the .sl file.

CANDIDATE EXPRESSION SYNTAX
────────────────────────────
  Literals     : 0  -3  true  false
  Identifiers  : any name
  Arithmetic   : e + e   e - e   e * e   -e
  Comparison   : e = e   e != e   e < e   e <= e   e > e   e >= e
  Boolean      : e and e   e or e   not e
  If-then-else : if C then T else E   |   ite(C, T, E)
  Raw SMT-LIB2 : (ite (= x 0) 1 x)   — passed through verbatim when
                 the expression starts with '('

EXAMPLES
────────
  julia sygus_to_z3.jl spec.sl --fun "f=if x1 = x2 then 0 else 1"
  julia sygus_to_z3.jl spec.sl --fun "f=if x1 = x2 then 0 else 1" > q.smt2
  z3 q.smt2
"""

# ══════════════════════════════════════════════════════════════════
# §1  S-EXPRESSION READER
#     Full SMT-LIB2 / SyGuS-v2 token grammar:
#       atoms, numerals, quoted strings "…", quoted symbols |…|, keywords :foo
# ══════════════════════════════════════════════════════════════════

function tokenise_sexp(text::String)::Vector{String}
    text = replace(text, r";[^\n]*" => "")   # strip line comments
    tokens = String[]
    i = 1; n = length(text)
    while i <= n
        c = text[i]
        if isspace(c)
            i += 1
        elseif c ∈ ('(', ')')
            push!(tokens, string(c)); i += 1
        elseif c == '"'                          # quoted string  "…"
            j = i + 1
            while j <= n
                text[j] == '"'  && (j += 1; break)
                text[j] == '\\' && (j += 1)     # skip escaped char
                j += 1
            end
            push!(tokens, text[i:j-1]); i = j
        elseif c == '|'                          # quoted symbol  |…|
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

sexp_to_str(s)::String =
    s isa String ? s :
    s isa Vector ? (isempty(s) ? "()" : "(" * join(sexp_to_str.(s), " ") * ")") :
    string(s)

# ══════════════════════════════════════════════════════════════════
# §2  CANDIDATE INFIX PARSER  →  SMT-LIB2 prefix string
# ══════════════════════════════════════════════════════════════════

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

"""Convert a candidate expression to SMT-LIB2.
If it starts with '(' it is treated as already valid SMT-LIB2 prefix notation.
"""
function candidate_to_smt2(src::String)::String
    src = String(strip(src))  # Convert SubString to String
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
# §3  SyGuS SPEC PARSER
#     Handles the full SyGuS-v2 command vocabulary.
# ══════════════════════════════════════════════════════════════════

struct SynthFun
    name   :: String
    params :: Vector{Tuple{String,String}}   # (param_name, sort)
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
    fun_decls        :: Vector{String}   # uninterpreted declare-fun (arity > 0)
    define_funs      :: Vector{String}
    define_funs_rec  :: Vector{String}
    datatypes        :: Vector{String}
    synth_funs       :: Vector{SynthFun}
    free_vars        :: Vector{FreeVar}
    constraints      :: Vector{String}
    # order-preserving list of all top-level commands we need to emit, so that
    # define-fun helpers that depend on each other are emitted in source order
    ordered_preamble :: Vector{String}
end

Spec() = Spec("", String[], String[], String[], String[], String[],
              String[], SynthFun[], FreeVar[], String[], String[])

function parse_sl(text::String)::Spec
    exprs = read_sexprs(text)
    s = Spec()
    synth_names = Set{String}()

    for expr in exprs
        (expr isa Vector && !isempty(expr)) || continue
        head = expr[1]

        # ── logic / options ──────────────────────────────────────
        if head == "set-logic"
            s.logic = sexp_to_str(expr[2])

        elseif head == "set-option"
            raw = sexp_to_str(expr)
            push!(s.options, raw)

        # ── sort & type declarations ─────────────────────────────
        elseif head ∈ ("declare-sort", "define-sort")
            raw = sexp_to_str(expr)
            push!(s.sort_decls, raw)
            push!(s.ordered_preamble, raw)

        elseif head ∈ ("declare-datatypes", "declare-datatype")
            raw = sexp_to_str(expr)
            push!(s.datatypes, raw)
            push!(s.ordered_preamble, raw)

        # ── function definitions / declarations ──────────────────
        elseif head == "define-fun"
            raw = sexp_to_str(expr)
            push!(s.define_funs, raw)
            push!(s.ordered_preamble, raw)

        elseif head == "define-funs-rec"
            raw = sexp_to_str(expr)
            push!(s.define_funs_rec, raw)
            push!(s.ordered_preamble, raw)

        elseif head == "declare-fun"
            # nullary → free constant; arity > 0 → uninterpreted function
            params_raw = expr[3]
            raw = sexp_to_str(expr)
            if params_raw isa Vector && isempty(params_raw)
                push!(s.free_vars, FreeVar(sexp_to_str(expr[2]), sexp_to_str(expr[4])))
            else
                push!(s.fun_decls, raw)
                push!(s.ordered_preamble, raw)
            end

        # ── variables (SyGuS declare-var) ────────────────────────
        elseif head == "declare-var"
            push!(s.free_vars, FreeVar(sexp_to_str(expr[2]), sexp_to_str(expr[3])))

        # ── synthesis targets ────────────────────────────────────
        elseif head ∈ ("synth-fun", "synth-inv")
            name = sexp_to_str(expr[2])
            raw_p = expr[3]
            ret   = head == "synth-inv" ? "Bool" : sexp_to_str(expr[4])
            params = Tuple{String,String}[
                (sexp_to_str(p[1]), sexp_to_str(p[2])) for p in raw_p
            ]
            push!(s.synth_funs, SynthFun(name, params, ret))
            push!(synth_names, name)

        # ── constraints ──────────────────────────────────────────
        elseif head == "constraint"
            push!(s.constraints, sexp_to_str(expr[2]))

        elseif head == "inv-constraint"
            # (inv-constraint inv pre trans post)
            # Expand the three standard VCs using the parameter names from the
            # synth-inv declaration.  For trans we need primed copies of all
            # state variables — we generate them as fresh names (append _prime).
            inv_name = sexp_to_str(expr[2])
            pre_fn   = sexp_to_str(expr[3])
            trans_fn = sexp_to_str(expr[4])
            post_fn  = sexp_to_str(expr[5])
            sf_idx   = findfirst(sf -> sf.name == inv_name, s.synth_funs)
            if sf_idx !== nothing
                sf      = s.synth_funs[sf_idx]
                pnames  = [p[1] for p in sf.params]
                psorts  = [p[2] for p in sf.params]
                pnames_ = pnames .* "_prime"   # primed variables for post-state

                inv_pre   = "($inv_name $(join(pnames,  " ")))"
                inv_post  = "($inv_name $(join(pnames_, " ")))"
                pre_call  = "($pre_fn  $(join(pnames,  " ")))"
                trans_call= "($trans_fn $(join(pnames, " ")) $(join(pnames_, " ")))"
                post_call = "($post_fn $(join(pnames_, " ")))"

                # VC1: pre(x) => inv(x)
                push!(s.constraints, "(=> $pre_call $inv_pre)")
                # VC2: inv(x) ∧ trans(x,x') => inv(x')
                push!(s.constraints, "(=> (and $inv_pre $trans_call) $inv_post)")
                # VC3: inv(x) ∧ ¬trans… (no loop back) => post(x)  i.e. inv(x) => post(x)
                push!(s.constraints, "(=> $inv_pre $post_call)")

                # Declare primed variables as free vars (same sorts)
                for (n_, sort_) in zip(pnames_, psorts)
                    any(fv -> fv.name == n_, s.free_vars) ||
                        push!(s.free_vars, FreeVar(n_, sort_))
                end
            else
                @warn "inv-constraint references unknown synth-inv '$inv_name'; skipping"
            end

        # everything else (check-synth, set-feature, …) is ignored
        end
    end
    s
end

# ══════════════════════════════════════════════════════════════════
# §4  QUERY GENERATOR
# ══════════════════════════════════════════════════════════════════

"""
Build the complete .smt2 query.
`candidates` maps synth-fun name → SMT-LIB2 body string.
"""
function generate_query(spec::Spec, candidates::Dict{String,String},
                        sl_file::String)::String

    # validate
    for sf in spec.synth_funs
        haskey(candidates, sf.name) ||
            error("No candidate provided for synth-fun '$(sf.name)'.\n" *
                  "Pass it with --fun \"$(sf.name)=<expr>\"")
    end

    out = IOBuffer()
    pl(s="")  = println(out, s)
    pr(s)     = print(out, s)

    pl("; ── generated by sygus_to_z3.jl ─────────────────────────────")
    pl("; source     : $sl_file")
    for sf in spec.synth_funs
        pl("; candidate  : $(sf.name) = $(candidates[sf.name])")
    end
    pl()

    # logic
    if !isempty(spec.logic)
        pl("(set-logic $(spec.logic))")
        pl()
    end

    # options — drop SyGuS-only ones Z3 rejects
    sygus_opt_prefixes = [":sygus", ":produce-models"]
    kept_opts = filter(o -> !any(p -> occursin(p, o), sygus_opt_prefixes), spec.options)
    if !isempty(kept_opts)
        foreach(pl, kept_opts); pl()
    end

    # preamble in source order (sorts, datatypes, declare-fun, define-fun, define-funs-rec)
    if !isempty(spec.ordered_preamble)
        pl("; ── preamble (sorts, helpers, uninterpreted functions) ──")
        foreach(pl, spec.ordered_preamble)
        pl()
    end

    # concrete synth-fun implementations
    pl("; ── candidate implementations ──")
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

    # free variable declarations
    if !isempty(spec.free_vars)
        pl("; ── free variables ──")
        for fv in spec.free_vars
            pl("(declare-const $(fv.name) $(fv.sort))")
        end
        pl()
    end

    # verification condition
    pl("; ── verification condition ──")
    pl("; unsat  →  candidate is correct for all inputs")
    pl("; sat    →  model below is a concrete counterexample")
    if isempty(spec.constraints)
        pl("(assert false)   ; no constraints — trivially unsat")
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

    # counterexample values: all free variables
    if !isempty(spec.free_vars)
        var_list = join([fv.name for fv in spec.free_vars], " ")
        pl("; free-variable assignments")
        pl("(get-value ($var_list))")
    end

    # counterexample values: each synth-fun applied to its inputs
    # We map formal parameter sorts to free variables by sort+declaration order.
    pl("; synthesised function value(s) at the counterexample point")
    for sf in spec.synth_funs
        # Build a per-sort queue from free_vars (in declaration order)
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
                # fallback: formal name (works when declare-var names == param names)
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
  julia sygus_to_z3.jl <file.sl> --fun "<name>=<expr>" [--fun ...]

  Provide one --fun for every synth-fun / synth-inv in the .sl file.

EXPRESSION SYNTAX  (candidate)
  Literals     : 0  -3  true  false
  Arithmetic   : e + e   e - e   e * e   -e
  Comparison   : e = e   e != e   e < e   e <= e   e > e   e >= e
  Boolean      : e and e   e or e   not e
  If-then-else : if C then T else E     or     ite(C, T, E)
  Raw SMT-LIB2 : (ite (= x1 x2) 0 1)  — pass-through when starting with '('

EXAMPLES
  julia sygus_to_z3.jl spec.sl --fun "f=if x1 = x2 then 0 else 1"
  julia sygus_to_z3.jl spec.sl --fun "f=if x1 = x2 then 0 else 1" > q.smt2
  z3 q.smt2
""")
end

function main()
    if isempty(ARGS) || ARGS[1] ∈ ("-h", "--help")
        usage(); exit(isempty(ARGS) ? 1 : 0)
    end

    sl_file = ARGS[1]
    isfile(sl_file) || (println(stderr, "ERROR: file not found: $sl_file"); exit(1))

    candidates = Dict{String,String}()
    i = 2
    
    # Auto-detect simple syntax: positional candidate expression
    # If ARGS[2] doesn't start with '--', treat it as a candidate for the first synth-fun
    if i <= length(ARGS) && !startswith(ARGS[i], "--")
        # Simple syntax: file candidate [output.smt2]
        candidate_expr = ARGS[i]; i += 1
        output_file = nothing
        if i <= length(ARGS) && endswith(ARGS[i], ".smt2")
            output_file = ARGS[i]; i += 1
        end
        
        spec = parse_sl(read(sl_file, String))
        if isempty(spec.synth_funs)
            println(stderr, "ERROR: no synth-fun or synth-inv found in $sl_file")
            exit(1)
        end
        
        # Use first synth-fun name
        fname = spec.synth_funs[1].name
        candidates[fname] = candidate_to_smt2(candidate_expr)
        
        query_output = generate_query(spec, candidates, sl_file)
        
        # Output (Julia handles UTF-8 by default)
        if output_file !== nothing
            open(output_file, "w") do f
                write(f, query_output * "\n")
            end
            println(stderr, "Wrote SMT-LIB2 query to: $output_file")
        else
            write(stdout, query_output * "\n")
        end
        return
    end
    
    # Traditional --fun syntax
    while i <= length(ARGS)
        if ARGS[i] == "--fun"
            i + 1 > length(ARGS) &&
                (println(stderr, "ERROR: --fun requires an argument"); exit(1))
            spec_str = ARGS[i+1]; i += 2
            eq = findfirst('=', spec_str)
            eq === nothing &&
                (println(stderr, "ERROR: --fun argument must be 'name=expr', got: $spec_str"); exit(1))
            fname = String(strip(spec_str[1:eq-1]))  # Convert SubString to String
            fexpr = String(strip(spec_str[eq+1:end]))  # Convert SubString to String
            isempty(fname) &&
                (println(stderr, "ERROR: empty function name in --fun argument"); exit(1))
            candidates[fname] = candidate_to_smt2(fexpr)
        else
            println(stderr, "ERROR: unexpected argument '$(ARGS[i])'")
            usage(); exit(1)
        end
    end

    spec = parse_sl(read(sl_file, String))

    isempty(spec.synth_funs) &&
        (println(stderr, "ERROR: no synth-fun or synth-inv found in $sl_file"); exit(1))

    missing = [sf.name for sf in spec.synth_funs if !haskey(candidates, sf.name)]
    if !isempty(missing)
        println(stderr, "ERROR: missing candidate(s) for: $(join(missing, ", "))")
        println(stderr, "       Provide them with --fun \"name=expr\"")
        exit(1)
    end

    write(stdout, generate_query(spec, candidates, sl_file) * "\n")
end

main()