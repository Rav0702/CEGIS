"""
    constraint_patches.jl

Spec-derived **answer patches** for the guided operator (v3, RQ1_RQ2_PLAN.md §7.10 steps 3–4).

For a single-invocation spec with synth-fun `f`, every output term `t` the spec itself mentions
(the right-hand side of a comparison with `f(x)`, plus `t ± 1` for strict bounds) gets a guard

    G_t  =  simplify( ⋀_c  c[f(x) := t] )

— the inputs at which `t` is a valid answer. The patch `ite(G_t, t, n)` at the root is then
**sound by construction** (wherever it fires it returns a valid answer) and **general** (the guard
comes from the spec, not from the tests, so it does not memorize). On `max6`, `G_{x3}` is
"x3 ≥ every other input"; on a case split, `G_t` is the region premise(s) demanding `t`. This is
the term + guard decomposition of divide-and-conquer SyGuS solvers (EUSolver), driven by the
parent's failing tests: a recipe is used only if its guard holds at one of them — the
constraint → failing-test map, evaluated pointwise (interpreter only, no Z3).

`spec_answer_recipes(spec, grammar)` builds the recipes once per run; `nothing` when the spec is
outside the scope (multi-invocation or non-canonical applications, parameters that are not the
declared variables, a guard or term the grammar cannot express).
"""

const _SX = Any   # s-expression: String atom or Vector{Any}

_sx_int(s) = s isa AbstractString ? tryparse(Int, s) : nothing
_sx_true(s) = s == "true"
_sx_false(s) = s == "false"

"""Split `(+ a k)` / `(- a k)` / `a` into (base, constant offset) for simple comparisons."""
function _sx_offset(s)
    if s isa Vector && length(s) == 3 && (s[1] == "+" || s[1] == "-")
        k = _sx_int(s[3])
        k !== nothing && return (s[2], s[1] == "+" ? k : -k)
        k = _sx_int(s[2])
        (k !== nothing && s[1] == "+") && return (s[3], k)
    end
    return (s, 0)
end

"""Partial evaluation: constant folding, trivial comparisons, Boolean identities, flattening."""
function _sx_simplify(s)
    s isa AbstractString && return s
    h = s[1]
    a = Any[_sx_simplify(x) for x in s[2:end]]
    if h in ("+", "-") && length(a) == 2 && _sx_int(a[1]) !== nothing && _sx_int(a[2]) !== nothing
        return string(h == "+" ? _sx_int(a[1]) + _sx_int(a[2]) : _sx_int(a[1]) - _sx_int(a[2]))
    end
    if h in (">=", "<=", ">", "<", "=") && length(a) == 2
        (b1, k1), (b2, k2) = _sx_offset(a[1]), _sx_offset(a[2])
        if b1 == b2 || (_sx_int(b1) !== nothing && _sx_int(b2) !== nothing)
            x = k1 + something(_sx_int(b1), 0) * (b1 == b2 ? 0 : 1)
            y = k2 + something(_sx_int(b2), 0) * (b1 == b2 ? 0 : 1)
            r = h == ">=" ? x >= y : h == "<=" ? x <= y : h == ">" ? x > y : h == "<" ? x < y : x == y
            return r ? "true" : "false"
        end
        # Integer normal form: constants to the right (a + k1 ⋈ b + k2  ⇒  a ⋈ b + (k2 - k1)), and strict
        # comparisons made non-strict (a > b + c ⇒ a ≥ b + c + 1). `w + 1 > x` becomes `w ≥ x`: the
        # same atom shape as max_n's guards, and far easier for Z3 than the offset form.
        c = k2 - k1
        op = h
        if op == ">"
            op, c = ">=", c + 1
        elseif op == "<"
            op, c = "<=", c - 1
        end
        rhs = _sx_int(b2) !== nothing ? string(_sx_int(b2) + c) :
              c == 0 ? b2 : c > 0 ? Any["+", b2, string(c)] : Any["-", b2, string(-c)]
        return Any[op, b1, rhs]
    end
    if h == "and"
        out = Any[]
        for x in a
            _sx_false(x) && return "false"
            _sx_true(x) && continue
            x isa Vector && x[1] == "and" ? append!(out, x[2:end]) : push!(out, x)
        end
        out = unique(out)
        return isempty(out) ? "true" : length(out) == 1 ? out[1] : Any["and"; out]
    elseif h == "or"
        out = Any[]
        for x in a
            _sx_true(x) && return "true"
            _sx_false(x) && continue
            x isa Vector && x[1] == "or" ? append!(out, x[2:end]) : push!(out, x)
        end
        out = unique(out)
        return isempty(out) ? "false" : length(out) == 1 ? out[1] : Any["or"; out]
    elseif h == "not" && length(a) == 1
        _sx_true(a[1]) && return "false"
        _sx_false(a[1]) && return "true"
        (a[1] isa Vector && a[1][1] == "not") && return a[1][2]
        return Any["not", a[1]]
    elseif h == "=>" && length(a) >= 2
        concl = a[end]
        prem = length(a) == 2 ? a[1] : _sx_simplify(Any["and"; a[1:end-1]])
        _sx_false(prem) && return "true"
        _sx_true(prem) && return concl
        _sx_true(concl) && return "true"
        _sx_false(concl) && return _sx_simplify(Any["not", prem])
        return Any["=>", prem, concl]
    end
    return Any[h; a]
end

"""Replace every canonical application `(f p1 … pn)` by `t`; `nothing` if one is not canonical."""
function _sx_subst_app(s, fname::String, params::Vector{String}, t)
    s isa AbstractString && return s == fname ? nothing : s
    if s[1] == fname
        (length(s) == length(params) + 1 && all(i -> s[i+1] == params[i], eachindex(params))) || return nothing
        return t
    end
    out = Any[s[1]]
    for x in s[2:end]
        y = _sx_subst_app(x, fname, params, t)
        y === nothing && return nothing
        push!(out, y)
    end
    return out
end

_sx_has(s, name) = s isa AbstractString ? s == name : any(x -> _sx_has(x, name), s)

"""Output terms the spec compares `f(x)` with (plus `t ± 1` for strict bounds)."""
function _sx_answer_terms!(out, s, fname)
    s isa AbstractString && return out
    if length(s) == 3 && s[1] in (">=", "<=", ">", "<", "=")
        for (me, other, op) in ((s[2], s[3], s[1]), (s[3], s[2], _flip(s[1])))
            if me isa Vector && me[1] == fname && !_sx_has(other, fname)
                push!(out, other)
                op == ">" && push!(out, Any["+", other, "1"])
                op == "<" && push!(out, Any["-", other, "1"])
            end
        end
    end
    foreach(x -> _sx_answer_terms!(out, x, fname), s[2:end])
    return out
end
_flip(op) = op == ">=" ? "<=" : op == "<=" ? ">=" : op == ">" ? "<" : op == "<" ? ">" : op

# ── translation into grammar RuleNodes ──────────────────────────────────────

struct _Rules
    g::AbstractGrammar
    ops::Dict{Symbol,Int}           # :ge :le :gt :lt :eq :and :or :not :ite :plus :minus :times :coerce
    vars::Dict{String,Int}          # parameter name => leaf rule
    zero::Int
    one::Int
end

function _Rules(g::AbstractGrammar)
    find(e) = something(findfirst(==(e), g.rules), 0)
    ops = Dict(:ge => find(:(Expr >= Expr)), :le => find(:(Expr <= Expr)), :gt => find(:(Expr > Expr)),
               :lt => find(:(Expr < Expr)), :eq => find(:(Expr == Expr)), :and => find(:(BoolExpr && BoolExpr)),
               :or => find(:(BoolExpr || BoolExpr)), :not => find(:(!BoolExpr)),
               :ite => find(:(ifelse(BoolExpr, Expr, Expr))), :plus => find(:(Expr + Expr)),
               :minus => find(:(Expr - Expr)), :times => find(:(Expr * Expr)),
               :coerce => something(findfirst(i -> g.rules[i] === :BoolExpr && g.types[i] === :Expr,
                                              eachindex(g.rules)), 0))
    vars = Dict{String,Int}()
    zero = one = 0
    for (i, r) in enumerate(g.rules)
        g.types[i] === :Expr || continue
        r isa Symbol && isempty(g.childtypes[i]) && r !== :BoolExpr && (vars[String(r)] = i)
        r === 0 && (zero = i)
        r === 1 && (one = i)
    end
    _Rules(g, ops, vars, zero, one)
end

_rn(r, cs...) = r == 0 ? nothing : any(isnothing, cs) ? nothing : RuleNode(r, collect(RuleNode, cs))

"""Balanced binary tree over `xs` with binary rule `r` (keeps depth logarithmic)."""
function _balanced(r, xs)
    (r == 0 || isempty(xs) || any(isnothing, xs)) && return nothing
    length(xs) == 1 && return xs[1]
    m = length(xs) ÷ 2
    return _rn(r, _balanced(r, xs[1:m]), _balanced(r, xs[m+1:end]))
end

function _int_term(R::_Rules, k::Int)
    k == 0 && return R.zero == 0 ? nothing : RuleNode(R.zero)
    k == 1 && return R.one == 0 ? nothing : RuleNode(R.one)
    k < 0 && return _rn(R.ops[:minus], _int_term(R, 0), _int_term(R, -k))
    return _balanced(R.ops[:plus], [_int_term(R, 1) for _ in 1:k])
end

"""Int term → RuleNode (variables, integers, + - *)."""
function _term_rn(R::_Rules, s)
    if s isa AbstractString
        k = _sx_int(s)
        k !== nothing && return _int_term(R, k)
        return haskey(R.vars, s) ? RuleNode(R.vars[s]) : nothing
    end
    h = s[1]
    op = h == "+" ? :plus : h == "-" ? :minus : h == "*" ? :times : nothing
    op === nothing && return nothing
    length(s) == 2 && h == "-" && return _rn(R.ops[:minus], _int_term(R, 0), _term_rn(R, s[2]))
    return _balanced(R.ops[op], [_term_rn(R, x) for x in s[2:end]])
end

"""Atom `a ⋈ b` with the grammar's comparison rules (rewriting via flips / offsets when needed)."""
function _atom_rn(R::_Rules, op::String, a, b)
    ta, tb = _term_rn(R, a), _term_rn(R, b)
    (ta === nothing || tb === nothing) && return nothing
    o = R.ops
    op == ">=" && return o[:ge] != 0 ? _rn(o[:ge], ta, tb) : _rn(o[:le], tb, ta)
    op == "<=" && return o[:le] != 0 ? _rn(o[:le], ta, tb) : _rn(o[:ge], tb, ta)
    op == "=" && return _rn(o[:eq], ta, tb)
    op == ">" && return o[:gt] != 0 ? _rn(o[:gt], ta, tb) : o[:lt] != 0 ? _rn(o[:lt], tb, ta) :
                        _atom_rn(R, ">=", a, Any["+", b, "1"])
    op == "<" && return o[:lt] != 0 ? _rn(o[:lt], ta, tb) : o[:gt] != 0 ? _rn(o[:gt], tb, ta) :
                        _atom_rn(R, "<=", Any["+", a, "1"], b)
    return nothing
end

const _NEG = Dict(">=" => "<", "<=" => ">", ">" => "<=", "<" => ">=")

"""Bool formula → RuleNode. Negation is pushed to the atoms; and/or fall back to a 0/1 sum
(`Expr = BoolExpr` coercion) when the grammar lacks them."""
function _bool_rn(R::_Rules, s, neg::Bool = false)
    s isa AbstractString && return nothing        # true/false are simplified away before this
    h = s[1]
    if h == "not"
        return _bool_rn(R, s[2], !neg)
    elseif h == "=>"
        return _bool_rn(R, Any["or", Any["not", s[2]], s[3]], neg)
    elseif h in ("and", "or")
        conj = (h == "and") != neg                    # De Morgan under negation
        parts = [_bool_rn(R, x, neg) for x in s[2:end]]
        any(isnothing, parts) && return nothing
        r = conj ? R.ops[:and] : R.ops[:or]
        r != 0 && return _balanced(r, parts)
        R.ops[:coerce] == 0 && return nothing
        total = _balanced(R.ops[:plus], [RuleNode(R.ops[:coerce], [p]) for p in parts])
        return _rn(R.ops[:ge] != 0 ? R.ops[:ge] : 0, total, _int_term(R, conj ? length(parts) : 1))
    elseif h in (">=", "<=", ">", "<")
        return _atom_rn(R, neg ? _NEG[h] : h, s[2], s[3])
    elseif h == "="
        neg || return _atom_rn(R, "=", s[2], s[3])
        R.ops[:not] != 0 && return _rn(R.ops[:not], _atom_rn(R, "=", s[2], s[3]))
        return _bool_rn(R, Any["or", Any["<", s[2], s[3]], Any[">", s[2], s[3]]])
    end
    return nothing
end

"""A spec-derived answer patch: return `term` wherever `guard` holds."""
struct AnswerRecipe
    term_sx::Any
    guard_sx::Any                 # simplified; "true" ⇒ `term` is a solution by itself
    term::RuleNode
    guard::Union{RuleNode,Nothing}
end

"""
A *demand*: constraint `P₁ ⇒ … ⇒ (f(x) = t)` (premises peeled from nested implications). Where
`P` holds every valid output equals `t`, so `ite(P, t, n)` is sound — and `P` is compact, unlike
the validity guard of `t`, which would be the complement of every other region. `nothing` if
the constraint is not of that form.
"""
function _sx_demand(c, fname::String, params::Vector{String})
    prem = Any[]
    s = c
    while s isa Vector && s[1] == "=>" && length(s) >= 2
        append!(prem, s[2:end-1])
        s = s[end]
    end
    (s isa Vector && length(s) == 3 && s[1] == "=") || return nothing
    for (me, t) in ((s[2], s[3]), (s[3], s[2]))
        me isa Vector && me[1] == fname && !_sx_has(t, fname) || continue
        _sx_subst_app(me, fname, params, "·") === nothing && return nothing
        return (isempty(prem) ? "true" : _sx_simplify(Any["and"; prem]), t)
    end
    return nothing
end

"""
    spec_answer_recipes(spec, grammar) -> Union{Vector{AnswerRecipe},Nothing}

Recipes for the answer terms the spec mentions. A term some constraint *demands*
(`P ⇒ f(x) = t`) gets one recipe per demanding constraint, guarded by that constraint's premise
`P` (case splits: one recipe per region). Every other term gets its *validity* guard
`⋀_c c[f(x) := t]` (bound specs: `max_n`, `above_n`). Guards that simplify to `false`, or that
`grammar` cannot express, are dropped. `nothing` when the spec is out of scope.
"""
function spec_answer_recipes(spec, grammar::AbstractGrammar)
    sf = spec.synth_funs[1]
    fname = sf.name
    params = String[p[1] for p in sf.params]
    Set(params) == Set(fv.name for fv in spec.free_vars) || return nothing
    cons = Any[CEXGeneration.read_sexprs(c)[1] for c in spec.constraints]
    R = _Rules(grammar)
    out = AnswerRecipe[]
    function add!(t, guard)
        _sx_false(guard) && return
        tr = _term_rn(R, _sx_simplify(t))
        tr === nothing && return
        gr = _sx_true(guard) ? nothing : _bool_rn(R, guard)
        (!_sx_true(guard) && gr === nothing) && return
        push!(out, AnswerRecipe(t, guard, tr, gr))
    end
    demanded = Set{Any}()
    for c in cons
        d = _sx_demand(c, fname, params)
        d === nothing && continue
        push!(demanded, d[2])
        add!(d[2], d[1])
    end
    terms = Any[]
    foreach(c -> _sx_answer_terms!(terms, c, fname), cons)
    for t in unique(terms)
        t in demanded && continue
        gs = Any[]
        for c in cons
            s = _sx_subst_app(c, fname, params, t)
            s === nothing && return nothing       # a non-canonical application: out of scope
            push!(gs, s)
        end
        add!(t, _sx_simplify(Any["and"; gs]))
    end
    return out
end

"""Does the recipe's guard hold at program input `x`? (Pointwise; parameters = variables.)"""
function recipe_fires(r::AnswerRecipe, fname::String, x::Dict{Symbol,Any})::Bool
    _sx_true(r.guard_sx) && return true
    b = Dict{String,Any}(String(k) => v for (k, v) in x)
    return try
        CEXGeneration.eval_constraint_pointwise(r.guard_sx, fname, b, _ -> error("no application"))
    catch
        false
    end
end

"""
A region the spec names without giving its answer: constraint `constraint` is `P ⇒ R(f(x), x)` where `f(x)`
does not stand alone (`f(x) − y = x + x`), so no recipe exists, but where `P` holds that constraint alone
decides the output. `guard` is `P` in the grammar's operators (spec_knowledge/PARTIAL_KNOWLEDGE.md).
"""
struct RegionGuard
    guard_sx::Any
    guard::RuleNode
    constraint::Int
end

"""
    spec_region_guards(spec, grammar) -> Vector{RegionGuard}

Guard-only knowledge: one `RegionGuard` per implication whose consequent mentions `f` but is not a
demand (`P ⇒ f(x) = t`, which `spec_answer_recipes` already turns into a recipe). Premises that the
grammar cannot express are dropped; empty when the spec is out of the recipes' scope.
"""
function spec_region_guards(spec, grammar::AbstractGrammar)
    sf = spec.synth_funs[1]
    fname = sf.name
    params = String[p[1] for p in sf.params]
    Set(params) == Set(fv.name for fv in spec.free_vars) || return RegionGuard[]
    R = _Rules(grammar)
    out = RegionGuard[]
    for (i, c) in enumerate(spec.constraints)
        s = CEXGeneration.read_sexprs(c)[1]
        (s isa Vector && s[1] == "=>") || continue
        _sx_demand(s, fname, params) === nothing || continue
        prem = Any[]
        body = s
        while body isa Vector && body[1] == "=>" && length(body) >= 2
            append!(prem, body[2:end-1])
            body = body[end]
        end
        _sx_has(body, fname) || continue
        g = _sx_simplify(Any["and"; prem])
        (_sx_true(g) || _sx_false(g)) && continue
        rn = _bool_rn(R, g)
        rn === nothing || push!(out, RegionGuard(g, rn, i))
    end
    return out
end

"""Does the region's guard hold at program input `x`? (Pointwise.)"""
function region_fires(r::RegionGuard, fname::String, x::Dict{Symbol,Any})::Bool
    b = Dict{String,Any}(String(k) => v for (k, v) in x)
    return try
        CEXGeneration.eval_constraint_pointwise(r.guard_sx, fname, b, _ -> error("no application"))
    catch
        false
    end
end

"""The patched tree: `ite(guard, term, tree)` at the root, or `term` alone for an unguarded answer."""
function answer_patch(tree::RuleNode, r::AnswerRecipe, ite_rule::Int)
    r.guard === nothing && return deepcopy(r.term)
    ite_rule == 0 && return nothing
    return RuleNode(ite_rule, [deepcopy(r.guard), deepcopy(r.term), deepcopy(tree)])
end
