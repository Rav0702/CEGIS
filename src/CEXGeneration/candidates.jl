"""
Parser for infix candidate expressions to SMT-LIB2 prefix notation.

Surface syntax:
  Literals     : 0, -3, true, false
  Arithmetic   : e + e, e - e, e * e, -e
  Comparison   : e = e, e != e, e < e, e <= e, e > e, e >= e
  Boolean      : e and e, e or e, not e
  If-then-else : if C then T else E  or  ite(C, T, E)
  Raw SMT-LIB2 : (ite (= x 0) 1 x)  — pass-through when starting with '('
"""

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

mutable struct InfixParser
    toks :: Vector{String}
    pos  :: Int
end

_pk(p::InfixParser) = p.pos <= length(p.toks) ? p.toks[p.pos] : ""
_nx(p::InfixParser) = (t = _pk(p); p.pos += 1; t)
_ex(p::InfixParser, e) = (t = _nx(p); t == e || error("Expected '$e' got '$t'"); t)

const INFIX_OPS = Dict(
    "or"  => (1, "or"),   "and" => (2, "and"),
    "="   => (3, "="),    "!="  => (3, "distinct"),
    "<"   => (3, "<"),    "<="  => (3, "<="),
    ">"   => (3, ">"),    ">="  => (3, ">="),
    "+"   => (4, "+"),    "-"   => (4, "-"),    "*" => (5, "*"),
)

function _parse_expr(p::InfixParser, min_prec::Int=0)::String
    lhs = _parse_unary(p)
    while true
        op = _pk(p)
        info = get(INFIX_OPS, op, nothing)
        (info === nothing || info[1] <= min_prec) && break
        _nx(p)
        rhs = _parse_expr(p, info[1])
        lhs = "($(info[2]) $lhs $rhs)"
    end
    lhs
end

_parse_unary(p::InfixParser) =
    _pk(p) == "not" ? (_nx(p); "(not $(_parse_primary(p)))") : _parse_primary(p)

function _parse_primary(p::InfixParser)::String
    t = _pk(p)
    if t == "if"
        _nx(p); c = _parse_expr(p); _ex(p, "then"); th = _parse_expr(p); _ex(p, "else")
        return "(ite $c $th $(_parse_expr(p)))"
    end
    if t == "ite"
        _nx(p); _ex(p, "("); c = _parse_expr(p); _ex(p, ",")
        th = _parse_expr(p); _ex(p, ","); el = _parse_expr(p); _ex(p, ")")
        return "(ite $c $th $el)"
    end
    if t == "("
        _nx(p); inner = _parse_expr(p); _ex(p, ")"); return inner
    end
    _nx(p)
    occursin(r"^-?\d+$", t) && return parse(Int, t) < 0 ? "(- $(abs(parse(Int, t))))" : t
    t ∈ ("true", "false") && return t
    t
end

"""Parse a candidate expression (infix or raw SMT-LIB2) to SMT-LIB2 prefix."""
function candidate_to_smt2(src::String)::String
    src = String(strip(src))
    if startswith(src, "(")
        es = read_sexprs(src)
        length(es) == 1 || error("Expected exactly one expression, got $(length(es))")
        return sexp_to_str(es[1])
    end
    p = InfixParser(tokenise_infix(src), 1)
    r = _parse_expr(p)
    p.pos <= length(p.toks) &&
        @warn "Trailing tokens in candidate: $(join(p.toks[p.pos:end], " "))"
    r
end
