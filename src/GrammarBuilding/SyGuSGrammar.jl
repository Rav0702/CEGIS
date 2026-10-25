"""
    SyGuSGrammar.jl

Translation of the grammar body of a SyGuS-v2 `synth-fun` command into a
`HerbGrammar` context-sensitive grammar.

Before this, `src/CEXGeneration/parser.jl` read only the name, parameters and return
sort of a `synth-fun` and discarded the grammar body, so the search grammar came either
from the logic-wide operation sets in `GrammarConfig.jl` or from a Julia function
hardcoded in a driver script. A benchmark suite whose families need different terminal
sets (and which varies grammar size as an experimental axis) needs the grammar declared
in the benchmark file itself.

## Supported syntax

SyGuS-v2 (separate nonterminal declarations):

    (synth-fun f ((x Int) (y Int)) Int
      ((Start Int) (CondExpr Bool))
      ((Start Int (x y 0 1 (ite CondExpr Start Start)))
       (CondExpr Bool ((< Start Start) (> Start Start)))))

SyGuS-v1 (declarations merged into the production groups) is also accepted, as are the
`(Constant <Sort>)` and `(Variable <Sort>)` special forms at the top level of a
production list.

## Nonterminal naming

Nonterminals are renamed to the names the rest of the pipeline expects: the start
nonterminal becomes `Expr` (the start symbol hardcoded by
`PartialSat.SeededCostBUIterator`), further `Int` nonterminals become `Expr2`, `Expr3`,
…, and `Bool` nonterminals become `BoolExpr`, `BoolExpr2`, …. The original SyGuS names
are returned alongside the grammar for diagnostics.
"""

# ─────────────────────────────────────────────────────────────────────────────
# Operator translation: SyGuS/SMT-LIB name → Julia surface syntax
# ─────────────────────────────────────────────────────────────────────────────

"""Binary SyGuS operators rendered infix in Julia, e.g. `(< a b)` → `(a < b)`."""
const SYGUS_INFIX_OPS = Dict{String,String}(
    "+" => "+", "-" => "-", "*" => "*",
    "<" => "<", "<=" => "<=", ">" => ">", ">=" => ">=",
    "=" => "==", "distinct" => "!=",
    "and" => "&&", "or" => "||",
)

"""SyGuS operators rendered as Julia function calls, e.g. `(ite c a b)` → `ifelse(c, a, b)`."""
const SYGUS_CALL_OPS = Dict{String,String}(
    "ite" => "ifelse", "div" => "div", "mod" => "mod", "abs" => "abs",
    "min" => "min", "max" => "max",
)

"""Unary SyGuS operators, e.g. `(not b)` → `(!b)`."""
const SYGUS_UNARY_OPS = Dict{String,String}("not" => "!", "-" => "-")

# ─────────────────────────────────────────────────────────────────────────────
# Grammar body destructuring
# ─────────────────────────────────────────────────────────────────────────────

"""Render an s-expression back to text, for error messages (local to this module so
`GrammarBuilding` need not depend on `CEXGeneration`)."""
_sexp_str(s) = s isa String ? s :
               s isa Vector ? (isempty(s) ? "()" : "(" * join(_sexp_str.(s), " ") * ")") :
               string(s)

"""
    has_sygus_grammar(sf) :: Bool

Whether this `synth-fun` carried a grammar body (`(synth-fun f ((x Int)) Int)` did not).
"""
has_sygus_grammar(sf) = !isempty(sf.grammar_sexp)

_is_decl(e) = e isa Vector && length(e) == 2 && all(x -> x isa String, e)
_is_group(e) = e isa Vector && length(e) == 3 && e[1] isa String && e[2] isa String

"""
    sygus_grammar_parts(sf) :: Tuple{Vector{Tuple{String,String}}, Vector{Any}}

Split a grammar body into `[(nonterminal, sort), …]` and the production groups,
accepting both the SyGuS-v2 form (declarations then groups) and the v1 form (groups
only, each carrying its own sort).
"""
function sygus_grammar_parts(sf)
    body = sf.grammar_sexp
    isempty(body) && error("synth-fun $(sf.name) has no grammar body")

    groups = nothing
    decls = Tuple{String,String}[]

    if length(body) >= 2 && body[1] isa Vector && !isempty(body[1]) && all(_is_decl, body[1])
        # v2: ((Start Int) (B Bool)) ((Start Int (...)) (B Bool (...)))
        for d in body[1]
            push!(decls, (String(d[1]), String(d[2])))
        end
        groups = body[2]
    elseif body[1] isa Vector && !isempty(body[1]) && all(_is_group, body[1])
        # v1: ((Start Int (...)) (B Bool (...)))
        groups = body[1]
    else
        error("synth-fun $(sf.name): unrecognised grammar body shape $(_sexp_str(body))")
    end

    groups isa Vector && all(_is_group, groups) ||
        error("synth-fun $(sf.name): production groups must each be (NT Sort (productions...)), got $(_sexp_str(groups))")

    if isempty(decls)
        for g in groups
            push!(decls, (String(g[1]), String(g[2])))
        end
    end
    return decls, Vector{Any}(groups)
end

"""
    nonterminal_names(decls) :: Dict{String,String}

Map SyGuS nonterminal names to Herb type names (see the module docstring). The start
nonterminal — the first declared, per SyGuS semantics — must be `Int`-sorted, because
the search starts at `:Expr`.
"""
function nonterminal_names(decls::Vector{Tuple{String,String}})::Dict{String,String}
    isempty(decls) && error("grammar has no nonterminals")
    start_sort = decls[1][2]
    start_sort == "Int" ||
        error("the start nonterminal $(decls[1][1]) has sort $start_sort; only Int start " *
              "nonterminals are supported (the search starts at :Expr)")

    names = Dict{String,String}()
    n_int, n_bool = 0, 0
    for (i, (nt, sort)) in enumerate(decls)
        if sort == "Int"
            n_int += 1
            names[nt] = i == 1 ? "Expr" : "Expr$(n_int)"
        elseif sort == "Bool"
            n_bool += 1
            names[nt] = n_bool == 1 ? "BoolExpr" : "BoolExpr$(n_bool)"
        else
            error("unsupported nonterminal sort $sort for $nt (Int and Bool only)")
        end
    end
    return names
end

# ─────────────────────────────────────────────────────────────────────────────
# Production rendering
# ─────────────────────────────────────────────────────────────────────────────

_is_int_literal(s::String) = occursin(r"^-?\d+$", s)

"""
    render_production(prod, nt_names, params; constants) :: Vector{String}

Render one SyGuS production as Julia right-hand sides. Returns a vector because the
`(Constant Sort)` and `(Variable Sort)` special forms each expand to several rules.
"""
function render_production(prod, nt_names::Dict{String,String},
                           params::Vector{Tuple{String,String}};
                           constants::Vector{Int} = Int[])::Vector{String}
    # Special forms, only meaningful at the top level of a production list.
    if prod isa Vector && length(prod) == 2 && prod[1] isa String && prod[2] isa String
        head, sort = String(prod[1]), String(prod[2])
        if head == "Constant"
            sort == "Int" || error("(Constant $sort) is unsupported; Int only")
            isempty(constants) && error("(Constant Int) used but no constant set was supplied")
            return [string(c) for c in constants]
        elseif head == "Variable" || head == "InputVariable" || head == "LocalVariable"
            vars = [p for (p, s) in params if s == sort]
            isempty(vars) && error("($head $sort) used but the synth-fun has no $sort parameter")
            return vars
        end
    end
    return [render_term(prod, nt_names, params)]
end

"""
    render_term(term, nt_names, params) :: String

Render a single SyGuS grammar term (nonterminal reference, literal, parameter, or
operator application) as Julia surface syntax.
"""
function render_term(term, nt_names::Dict{String,String},
                     params::Vector{Tuple{String,String}})::String
    if term isa String
        haskey(nt_names, term) && return nt_names[term]
        _is_int_literal(term) && return term
        term in ("true", "false") && return term
        any(p -> p[1] == term, params) && return term
        error("unknown grammar symbol `$term` (not a nonterminal, literal or parameter)")
    end

    term isa Vector || error("unexpected grammar term $term")
    isempty(term) && error("empty grammar term")
    op = term[1]
    op isa String || error("operator position must be a symbol, got $(_sexp_str(term))")
    args = [render_term(a, nt_names, params) for a in term[2:end]]

    if length(args) == 1 && haskey(SYGUS_UNARY_OPS, op)
        return "($(SYGUS_UNARY_OPS[op])$(args[1]))"
    elseif haskey(SYGUS_CALL_OPS, op)
        return "$(SYGUS_CALL_OPS[op])($(join(args, ", ")))"
    elseif haskey(SYGUS_INFIX_OPS, op)
        length(args) >= 2 || error("operator $op needs at least 2 arguments in $(_sexp_str(term))")
        # n-ary and/or/+/* fold left, matching SMT-LIB semantics.
        return "(" * join(args, " $(SYGUS_INFIX_OPS[op]) ") * ")"
    end
    error("unsupported grammar operator `$op` in $(_sexp_str(term))")
end

# ─────────────────────────────────────────────────────────────────────────────
# Entry points
# ─────────────────────────────────────────────────────────────────────────────

"""
    sygus_grammar_to_csgrammar(sf; constants) :: Tuple{String, Dict{String,String}}

Translate the grammar body of `sf` into a `@csgrammar` source string, plus the
SyGuS-name → Herb-type-name map. One rule is emitted per production, in declaration
order, so the resulting rule indices are a deterministic function of the `.sl` file —
which is what lets programs be remapped between the grammars of two problems in the
same family.
"""
function sygus_grammar_to_csgrammar(sf; constants::Vector{Int} = Int[])
    decls, groups = sygus_grammar_parts(sf)
    nt_names = nonterminal_names(decls)
    params = sf.params

    lines = String[]
    for g in groups
        nt = String(g[1])
        haskey(nt_names, nt) || error("production group for undeclared nonterminal $nt")
        prods = g[3]
        prods isa Vector || error("production list for $nt must be a list")
        for prod in prods
            for rhs in render_production(prod, nt_names, params; constants)
                push!(lines, "    $(nt_names[nt]) = $rhs")
            end
        end
    end
    isempty(lines) && error("synth-fun $(sf.name): grammar body has no productions")

    return "@csgrammar begin\n" * join(lines, "\n") * "\nend\n", nt_names
end

"""
    build_grammar_from_synth_fun(sf; constants) :: AbstractGrammar

Build the Herb grammar declared by a `synth-fun` grammar body.
"""
function build_grammar_from_synth_fun(sf; constants::Vector{Int} = Int[])
    src, _ = sygus_grammar_to_csgrammar(sf; constants)
    return eval_grammar_string(src)
end
