#!/usr/bin/env julia
"""
parse_spec.jl  —  Parse a SyGuS-v2 specification file into a reusable object

USAGE
─────
  julia parse_spec.jl <file.sl> <output.jl>

DESCRIPTION
───────────
Parses the SyGuS-v2 specification without a candidate expression.
Outputs a Julia serialization of the Spec object that can be loaded
and used with a candidate to generate verification queries.

EXAMPLES
────────
  julia parse_spec.jl spec.sl spec.parsed.jl
  # Then use with sygus_to_z3_lite.jl
  julia sygus_to_z3_lite.jl spec.parsed.jl "f=if x1 = x2 then 0 else 1" > q.smt2
"""

using Serialization

# ══════════════════════════════════════════════════════════════════
# §1  S-EXPRESSION READER (copied from sygus_to_z3.jl)
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
# §2  DATA STRUCTURES (copied from sygus_to_z3.jl)
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
    # order-preserving list of all top-level commands we need to emit
    ordered_preamble :: Vector{String}
end

Spec() = Spec("", String[], String[], String[], String[], String[],
              String[], SynthFun[], FreeVar[], String[], String[])

# ══════════════════════════════════════════════════════════════════
# §3  SyGuS SPEC PARSER (copied from sygus_to_z3.jl)
# ══════════════════════════════════════════════════════════════════

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
                # VC3: inv(x) => post(x)
                push!(s.constraints, "(=> $inv_pre $post_call)")

                # Declare primed variables as free vars (same sorts)
                for (n_, sort_) in zip(pnames_, psorts)
                    any(fv -> fv.name == n_, s.free_vars) ||
                        push!(s.free_vars, FreeVar(n_, sort_))
                end
            else
                @warn "inv-constraint references unknown synth-inv '$inv_name'; skipping"
            end

        # everything else is ignored
        end
    end
    s
end

# ══════════════════════════════════════════════════════════════════
# §4  ENTRY POINT
# ══════════════════════════════════════════════════════════════════

function main()
    if length(ARGS) < 2 || ARGS[1] ∈ ("-h", "--help")
        println(stderr, """
USAGE
  julia parse_spec.jl <file.sl> <output.jl>

DESCRIPTION
  Parses a SyGuS-v2 specification file and serializes the Spec object.

EXAMPLES
  julia parse_spec.jl spec.sl spec.parsed.jl
  julia sygus_to_z3_lite.jl spec.parsed.jl "f=if x1 = x2 then 0 else 1" > q.smt2
""")
        exit(length(ARGS) == 0 ? 1 : 0)
    end

    sl_file = ARGS[1]
    output_file = ARGS[2]

    isfile(sl_file) || (println(stderr, "ERROR: file not found: $sl_file"); exit(1))

    # Parse the specification
    text = read(sl_file, String)
    spec = parse_sl(text)

    # Serialize using Julia's native serialization
    open(output_file, "w") do f
        serialize(f, spec)
    end

    println(stderr, "Parsed specification from: $sl_file")
    println(stderr, "Serialized object written to: $output_file")
    println(stderr, "  Logic: $(isempty(spec.logic) ? "(none)" : spec.logic)")
    println(stderr, "  Synthesis targets: $(join([sf.name for sf in spec.synth_funs], ", "))")
    println(stderr, "  Free variables: $(join([fv.name for fv in spec.free_vars], ", "))")
    println(stderr, "  Constraints: $(length(spec.constraints))")
end

main()
