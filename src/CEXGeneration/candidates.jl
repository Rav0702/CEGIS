"""
candidates.jl - Abstract Candidate Parser with Multiple Implementations

Provides an extensible architecture for converting candidate expressions to SMT-LIB2.
Supports dependency injection to enable different parsing strategies.

Abstract Interface:
  - AbstractCandidateParser: Base type for all parser implementations
  - to_smt2(parser, src): Convert candidate to SMT-LIB2 using specified parser

Built-in Implementations:
  1. InfixCandidateParser (default, strictly-typed SMT-LIB2)
  2. SymbolicCandidateParser (experimental, handles mixed bool-numeric)

Surface syntax (both):
  Literals     : 0, -3, true, false
  Arithmetic   : e + e, e - e, e * e, -e
  Comparison   : e = e, e != e, e < e, e <= e, e > e, e >= e
  Boolean      : e and e, e or e, not e
  If-then-else : if C then T else E  or  ite(C, T, E)
  Raw SMT-LIB2 : (ite (= x 0) 1 x)  — pass-through when starting with '('
"""

# ═════════════════════════════════════════════════════════════════════════════
# ABSTRACT INTERFACE
# ═════════════════════════════════════════════════════════════════════════════

"""
    AbstractCandidateParser

Abstract base type for candidate expression parsers.
Implementations must define: to_smt2(parser::T, src::String)::String
"""
abstract type AbstractCandidateParser end

"""
    to_smt2(parser::AbstractCandidateParser, src::String)::String

Convert candidate expression string to SMT-LIB2 format using specified parser.

Arguments:
  - parser: Concrete parser implementation
  - src: Candidate expression string (infix or raw SMT-LIB2)

Returns:
  - SMT-LIB2 prefix notation string

Throws:
  - error if parser does not implement to_smt2
"""
function to_smt2(parser::AbstractCandidateParser, src::String)::String
    error("to_smt2 not implemented for $(typeof(parser))")
end

# ═════════════════════════════════════════════════════════════════════════════
# INFIX PARSER IMPLEMENTATION
# ═════════════════════════════════════════════════════════════════════════════

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

mutable struct _InfixParserImpl
    toks :: Vector{String}
    pos  :: Int
end

_pk(p::_InfixParserImpl) = p.pos <= length(p.toks) ? p.toks[p.pos] : ""
_nx(p::_InfixParserImpl) = (t = _pk(p); p.pos += 1; t)
_ex(p::_InfixParserImpl, e) = (t = _nx(p); t == e || error("Expected '$e' got '$t'"); t)

const _INFIX_OPS = Dict(
    "or"  => (1, "or"),   "and" => (2, "and"),
    "="   => (3, "="),    "!="  => (3, "distinct"),
    "<"   => (3, "<"),    "<="  => (3, "<="),
    ">"   => (3, ">"),    ">="  => (3, ">="),
    "+"   => (4, "+"),    "-"   => (4, "-"),    "*" => (5, "*"),
)

function _infix_parse_expr(p::_InfixParserImpl, min_prec::Int=0)::String
    lhs = _infix_parse_unary(p)
    while true
        op = _pk(p)
        info = get(_INFIX_OPS, op, nothing)
        (info === nothing || info[1] <= min_prec) && break
        _nx(p)
        rhs = _infix_parse_expr(p, info[1])
        lhs = "($(info[2]) $lhs $rhs)"
    end
    lhs
end

_infix_parse_unary(p::_InfixParserImpl) =
    _pk(p) == "not" ? (_nx(p); "(not $(_infix_parse_primary(p)))") : _infix_parse_primary(p)

function _infix_parse_primary(p::_InfixParserImpl)::String
    t = _pk(p)
    if t == "if"
        _nx(p); c = _infix_parse_expr(p); _ex(p, "then"); th = _infix_parse_expr(p); _ex(p, "else")
        return "(ite $c $th $(_infix_parse_expr(p)))"
    end
    if t == "ite"
        _nx(p); _ex(p, "("); c = _infix_parse_expr(p); _ex(p, ",")
        th = _infix_parse_expr(p); _ex(p, ","); el = _infix_parse_expr(p); _ex(p, ")")
        return "(ite $c $th $el)"
    end
    if t == "ifelse"
        _nx(p); _ex(p, "("); c = _infix_parse_expr(p); _ex(p, ",")
        th = _infix_parse_expr(p); _ex(p, ","); el = _infix_parse_expr(p); _ex(p, ")")
        return "(ite $c $th $el)"
    end
    if t == "("
        _nx(p); inner = _infix_parse_expr(p); _ex(p, ")"); return inner
    end
    _nx(p)
    occursin(r"^-?\d+$", t) && return parse(Int, t) < 0 ? "(- $(abs(parse(Int, t))))" : t
    t ∈ ("true", "false") && return t
    t
end

# ═════════════════════════════════════════════════════════════════════════════
# InfixCandidateParser: Default implementation (strictly-typed SMT-LIB2)
# ═════════════════════════════════════════════════════════════════════════════

"""
    struct InfixCandidateParser <: AbstractCandidateParser

Parser that converts infix expressions to SMT-LIB2 with strict type checking.
Cannot handle mixed boolean-numeric expressions like (x > y) * x because
SMT-LIB2 keeps Bool and Int as distinct sorts.

For mixed expressions, use SymbolicCandidateParser instead.
"""
struct InfixCandidateParser <: AbstractCandidateParser
    name::String
end

InfixCandidateParser() = InfixCandidateParser("InfixCandidateParser")

function to_smt2(parser::InfixCandidateParser, src::String)::String
    src = String(strip(src))
    if startswith(src, "(")
        try
            es = read_sexprs(src)
            length(es) == 1 || error("Expected exactly one expression, got $(length(es))")
            return sexp_to_str(es[1])
        catch
            # Not valid raw SMT-LIB2, fall through to infix parsing
        end
    end
    p = _InfixParserImpl(tokenise_infix(src), 1)
    r = _infix_parse_expr(p)
    p.pos <= length(p.toks) &&
        @warn "[$(parser.name)] Trailing tokens in candidate: $(join(p.toks[p.pos:end], " "))"
    r
end

# ═════════════════════════════════════════════════════════════════════════════
# SymbolicCandidateParser: Experimental (handles mixed bool-numeric)
# ═════════════════════════════════════════════════════════════════════════════

"""
    struct SymbolicCandidateParser <: AbstractCandidateParser

Parser that handles mixed boolean-numeric expressions with automatic type coercion.
Converts true/false to 1/0 in arithmetic contexts, enabling expressions like:
  - (x > y) * x
  - (x <= 5) + k
  - (a > b) and (c = d)

Implementation: Type-aware recursive descent parser that:
1. Parses infix expressions into typed AST
2. Tracks Bool vs Int sorts during parsing
3. Automatically wraps (condition) → (ite condition 1 0) when Bool appears in Int context
4. Generates SMT-LIB2 with proper type handling
"""
struct SymbolicCandidateParser <: AbstractCandidateParser
    name::String
end

SymbolicCandidateParser() = SymbolicCandidateParser("SymbolicCandidateParser")

# ──────────────────────────────────────────────────────────────────────────────
# Symbolic Parser Implementation: Type-aware AST with coercion
# ──────────────────────────────────────────────────────────────────────────────

abstract type TypedExpr end

struct IntExpr <: TypedExpr
    smt::String  # SMT-LIB2 representation
end

struct BoolExpr <: TypedExpr
    smt::String  # SMT-LIB2 representation
end

"""Convert a Bool expression to Int by wrapping in (ite expr 1 0)"""
_bool_to_int(e::BoolExpr)::IntExpr = IntExpr("(ite $(e.smt) 1 0)")
_bool_to_int(e::IntExpr)::IntExpr = e

mutable struct _SymbolicParserImpl
    toks::Vector{String}
    pos::Int
end

_pk_sym(p::_SymbolicParserImpl) = p.pos <= length(p.toks) ? p.toks[p.pos] : ""
_nx_sym(p::_SymbolicParserImpl) = (t = _pk_sym(p); p.pos += 1; t)
_ex_sym(p::_SymbolicParserImpl, e) = (t = _nx_sym(p); t == e || error("Expected '$e' got '$t'"); t)

# Operator precedence and SMT names (same as infix parser)
const _SYMBOLIC_OPS = Dict(
    "or"  => (1, "or", :bool),    "and" => (2, "and", :bool),
    "="   => (3, "=", :bool),     "!="  => (3, "distinct", :bool),
    "<"   => (3, "<", :bool),     "<="  => (3, "<=", :bool),
    ">"   => (3, ">", :bool),     ">="  => (3, ">=", :bool),
    "+"   => (4, "+", :int),      "-"   => (4, "-", :int),    "*" => (5, "*", :int),
)

"""Parse expression with type tracking - entry point"""
function _symbolic_parse_expr_typed(p::_SymbolicParserImpl, min_prec::Int=0)::TypedExpr
    lhs = _symbolic_parse_unary_typed(p)
    while true
        op = _pk_sym(p)
        info = get(_SYMBOLIC_OPS, op, nothing)
        (info === nothing || info[1] <= min_prec) && break
        _nx_sym(p)
        rhs = _symbolic_parse_expr_typed(p, info[1])
        prec, smt_op, result_type = info
        
        # Type coercion: if arithmetic operator needs Int but got Bool, coerce
        lhs_int = (result_type == :int) ? _bool_to_int(lhs) : lhs
        rhs_int = (result_type == :int) ? _bool_to_int(rhs) : rhs
        
        if result_type == :bool
            smt = "($(smt_op) $(lhs_int.smt) $(rhs_int.smt))"
            lhs = BoolExpr(smt)
        else
            smt = "($(smt_op) $(lhs_int.smt) $(rhs_int.smt))"
            lhs = IntExpr(smt)
        end
    end
    lhs
end

function _symbolic_parse_unary_typed(p::_SymbolicParserImpl)::TypedExpr
    if _pk_sym(p) == "not"
        _nx_sym(p)
        arg = _symbolic_parse_primary_typed(p)
        # 'not' expects Bool; coerce if needed
        arg = arg isa BoolExpr ? arg : _bool_to_int(arg)
        return BoolExpr("(not $(arg.smt))")
    end
    _symbolic_parse_primary_typed(p)
end

function _symbolic_parse_primary_typed(p::_SymbolicParserImpl)::TypedExpr
    t = _pk_sym(p)
    
    # if-then-else: always returns Bool or Int depending on branches
    if t == "if"
        _nx_sym(p)
        cond = _symbolic_parse_expr_typed(p)
        _ex_sym(p, "then")
        then_br = _symbolic_parse_expr_typed(p)
        _ex_sym(p, "else")
        else_br = _symbolic_parse_expr_typed(p)
        
        # Determine result type from branches
        if then_br isa BoolExpr && else_br isa BoolExpr
            return BoolExpr("(ite $(cond.smt) $(then_br.smt) $(else_br.smt))")
        else
            then_int = _bool_to_int(then_br)
            else_int = _bool_to_int(else_br)
            return IntExpr("(ite $(cond.smt) $(then_int.smt) $(else_int.smt))")
        end
    end
    
    # ite(..., ..., ...) function-style
    if t == "ite"
        _nx_sym(p); _ex_sym(p, "(")
        cond = _symbolic_parse_expr_typed(p); _ex_sym(p, ",")
        then_br = _symbolic_parse_expr_typed(p); _ex_sym(p, ",")
        else_br = _symbolic_parse_expr_typed(p); _ex_sym(p, ")")
        
        if then_br isa BoolExpr && else_br isa BoolExpr
            return BoolExpr("(ite $(cond.smt) $(then_br.smt) $(else_br.smt))")
        else
            then_int = _bool_to_int(then_br)
            else_int = _bool_to_int(else_br)
            return IntExpr("(ite $(cond.smt) $(then_int.smt) $(else_int.smt))")
        end
    end
    
    # ifelse(..., ..., ...)
    if t == "ifelse"
        _nx_sym(p); _ex_sym(p, "(")
        cond = _symbolic_parse_expr_typed(p); _ex_sym(p, ",")
        then_br = _symbolic_parse_expr_typed(p); _ex_sym(p, ",")
        else_br = _symbolic_parse_expr_typed(p); _ex_sym(p, ")")
        
        if then_br isa BoolExpr && else_br isa BoolExpr
            return BoolExpr("(ite $(cond.smt) $(then_br.smt) $(else_br.smt))")
        else
            then_int = _bool_to_int(then_br)
            else_int = _bool_to_int(else_br)
            return IntExpr("(ite $(cond.smt) $(then_int.smt) $(else_int.smt))")
        end
    end
    
    # Parenthesized expression
    if t == "("
        _nx_sym(p)
        inner = _symbolic_parse_expr_typed(p)
        _ex_sym(p, ")")
        return inner
    end
    
    # Literals and identifiers
    _nx_sym(p)
    
    # Boolean literals
    if t ∈ ("true", "false")
        return BoolExpr(t)
    end
    
    # Integer literals
    if occursin(r"^-?\d+$", t)
        return IntExpr(parse(Int, t) < 0 ? "(- $(abs(parse(Int, t))))" : t)
    end
    
    # Variable (assume Int by default, could be refined with type info)
    return IntExpr(t)
end

function to_smt2(parser::SymbolicCandidateParser, src::String)::String
    src = String(strip(src))
    
    # Attempt to detect and pass-through raw SMT-LIB2
    # (only if it's complete S-expressions without obvious infix operators)
    if startswith(src, "(")
        try
            es = read_sexprs(src)
            length(es) == 1 || error("Expected exactly one expression, got $(length(es))")
            # Only return as pass-through if it looks like pure SMT-LIB2
            # (no obvious infix operators left over)
            return sexp_to_str(es[1])
        catch
            # Not valid raw SMT-LIB2, fall through to infix parsing
        end
    end
    
    # Parse with type tracking
    try
        p = _SymbolicParserImpl(tokenise_infix(src), 1)
        result = _symbolic_parse_expr_typed(p)
        
        # Warn if trailing tokens
        p.pos <= length(p.toks) &&
            @warn "[$(parser.name)] Trailing tokens in candidate: $(join(p.toks[p.pos:end], " "))"
        
        return result.smt
    catch e
        @warn "[$(parser.name)] Error during symbolic parsing: $e, falling back to infix parser"
        fallback = InfixCandidateParser()
        to_smt2(fallback, src)
    end
end

# ═════════════════════════════════════════════════════════════════════════════
# BACKWARDS COMPATIBILITY: Default dispatcher
# ═════════════════════════════════════════════════════════════════════════════

const _global_default_parser = Ref{AbstractCandidateParser}(InfixCandidateParser())

"""
    set_default_candidate_parser(parser::AbstractCandidateParser)

Set the global default parser for backwards-compatible candidate_to_smt2() calls.
"""
function set_default_candidate_parser(parser::AbstractCandidateParser)
    _global_default_parser[] = parser
end

"""
    get_default_candidate_parser()::AbstractCandidateParser

Get the current default parser used by candidate_to_smt2().
"""
function get_default_candidate_parser()::AbstractCandidateParser
    _global_default_parser[]
end

"""
    candidate_to_smt2(src::String)::String

Legacy wrapper for backwards compatibility.
Converts candidate expression to SMT-LIB2 using the default parser.

To use a specific parser, call: to_smt2(parser_instance, candidate_str)

Examples:
```julia
# Use default (InfixCandidateParser)
candidate_to_smt2("x + 5")

# Switch to symbolic parser
set_default_candidate_parser(SymbolicCandidateParser())
candidate_to_smt2("(x > y) * x")  # Now works!

# Or use explicit parser
parser = InfixCandidateParser()
to_smt2(parser, "x + 5")
```
"""
function candidate_to_smt2(src::String)::String
    to_smt2(_global_default_parser[], src)
end
