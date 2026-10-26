"""
    localization.jl

Fault localization for candidate programs — *where* a failing program should be
changed (RQ1_RQ2_PLAN.md §3–§4).

Sites are addressed by **paths** (child-index vectors from the root, `Int[]` =
root) so a site found on one tree transfers to its copy.

- `active_paths` — nodes executed on one input (at an `ifelse`, the condition and
  the taken branch only).
- `ochiai_scores` — spectrum-based suspiciousness over failing vs passing inputs
  (interpreter only).
- `repairable_paths` — SMT localization: which single nodes are *correction sets*,
  i.e. replacing that subtree alone by an arbitrary function (a fresh value per
  input, "angelic") can make the program right on all the evidence. Also returns
  the angelic values and classifies them (FLIP / VAR / CONST / OFFSET / SPLIT).

`repairable_paths` builds a symbolic evaluation of the tree at each evidence
input with the node under test replaced by a fresh Z3 variable; every other
subtree evaluates concretely, so only the path from the hole to the root is
symbolic. It runs in a Z3 context of its own (never the search's; see
`spec_single_answer` for why) with a per-check timeout.
"""

const NodePath = Vector{Int}
const _Z3 = CEXGeneration.Z3

# ── paths ────────────────────────────────────────────────────────────────────

"""Every node's path, root first (pre-order)."""
function node_paths(tree::RuleNode)::Vector{NodePath}
    out = NodePath[Int[]]
    _node_paths!(out, tree, Int[])
    return out
end
function _node_paths!(out, node::RuleNode, prefix::NodePath)
    for (i, c) in enumerate(node.children)
        c isa RuleNode || continue
        p = [prefix; i]
        push!(out, p)
        _node_paths!(out, c, p)
    end
end

"""The node at `path`."""
node_at(tree::RuleNode, path::NodePath)::RuleNode = foldl((n, i) -> n.children[i], path; init = tree)

"""A HerbGrammar `NodeLoc` for `path` in `tree` (for `insert!`)."""
function nodeloc_at(tree::RuleNode, path::NodePath)::NodeLoc
    isempty(path) && return HerbGrammar.root_node_loc(tree)
    return NodeLoc(node_at(tree, path[1:end-1]), path[end])
end

"""Is `q` a strict descendant path of `p`?"""
_is_descendant(q::NodePath, p::NodePath) = length(q) > length(p) && q[1:length(p)] == p

# ── L1: active paths ─────────────────────────────────────────────────────────

"""Paths of the nodes executed when `tree` runs on `input`."""
function active_paths(tree::RuleNode, grammar::AbstractGrammar, symboltable,
                      input::Dict{Symbol,Any})::Vector{NodePath}
    out = NodePath[]
    _active_paths!(out, tree, Int[], grammar, symboltable, input)
    return out
end

function _active_paths!(out, node::RuleNode, path::NodePath, grammar, st, input)
    push!(out, path)
    isempty(node.children) && return
    if _is_ifelse(grammar, node)
        _active_paths!(out, node.children[1], [path; 1], grammar, st, input)
        taken = try
            Bool(execute_on_input(st, rulenode2expr(node.children[1], grammar), input))
        catch
            true
        end
        i = taken ? 2 : 3
        _active_paths!(out, node.children[i], [path; i], grammar, st, input)
    else
        for (i, c) in enumerate(node.children)
            c isa RuleNode && _active_paths!(out, c, [path; i], grammar, st, input)
        end
    end
end

# ── L2: spectrum-based (Ochiai) ──────────────────────────────────────────────

"""
    ochiai_scores(tree, grammar, symboltable, failing, passing) -> Dict{NodePath,Float64}

Ochiai suspiciousness `fail(n) / sqrt(F * (fail(n) + pass(n)))`: how strongly a node's
execution is associated with failing rather than passing inputs. Zero for nodes never
executed on a failing input.
"""
function ochiai_scores(tree::RuleNode, grammar::AbstractGrammar, symboltable,
                       failing::Vector{Dict{Symbol,Any}}, passing::Vector{Dict{Symbol,Any}})
    fail = Dict{NodePath,Int}()
    pass = Dict{NodePath,Int}()
    for x in failing, p in active_paths(tree, grammar, symboltable, x)
        fail[p] = get(fail, p, 0) + 1
    end
    for x in passing, p in active_paths(tree, grammar, symboltable, x)
        pass[p] = get(pass, p, 0) + 1
    end
    F = length(failing)
    return Dict{NodePath,Float64}(p => begin
        f = get(fail, p, 0)
        f == 0 || F == 0 ? 0.0 : f / sqrt(F * (f + get(pass, p, 0)))
    end for p in node_paths(tree))
end

# ── L3: SMT single-node correction sets ──────────────────────────────────────

"""
Evidence for SMT localization: complete tests (program input => expected output)
and bindings (free-var name => value) at which every spec constraint must hold
(violation witnesses, incomplete tests).
"""
struct LocEvidence
    complete::Vector{Tuple{Dict{Symbol,Any},Any}}
    constrained::Vector{Dict{String,Any}}
end

_lift(v, ctx) = v isa _Z3.Expr ? v : v isa Bool ? _Z3.BoolVal(v, ctx) : _Z3.IntVal(Int(v), ctx)
function _as_int(v, ty::Symbol, ctx)
    ty === :int && return v
    v isa Bool && return Int(v)
    return _Z3.If(v, _Z3.IntVal(1, ctx), _Z3.IntVal(0, ctx))
end
_node_ty(grammar, node) = return_type(grammar, node) === :BoolExpr ? :bool : :int

"""
Evaluate `node` at `input`, returning `(value, :int|:bool)`. The node at `hole` is
replaced by `holevar`; the value is concrete (Int/Bool) unless it depends on the hole,
in which case it is a Z3 expression. Supports the LIA operators of our grammars.
"""
function _symeval(node::RuleNode, path::NodePath, hole::NodePath, holevar, holety::Symbol,
                  grammar::AbstractGrammar, input::Dict{Symbol,Any}, ctx)
    path == hole && return (holevar, holety)
    r = grammar.rules[node.ind]
    if isempty(node.children)
        r isa Symbol && (v = input[r]; return (v, v isa Bool ? :bool : :int))
        r isa Bool && return (r, :bool)
        r isa Integer && return (Int(r), :int)
        error("localization: unsupported leaf rule $(repr(r))")
    end
    ev(i) = _symeval(node.children[i], [path; i], hole, holevar, holety, grammar, input, ctx)
    if r isa Symbol                        # unit rule, e.g. Expr = BoolExpr
        (v, t) = ev(1)
        return _node_ty(grammar, node) === :int ? (_as_int(v, t, ctx), :int) : (v, t)
    end
    r isa Expr || error("localization: unsupported rule $(repr(r))")
    if r.head === :&& || r.head === :||
        (a, _), (b, _) = ev(1), ev(2)
        if !(a isa _Z3.Expr) && !(b isa _Z3.Expr)
            return (r.head === :&& ? (a && b) : (a || b), :bool)
        end
        xs = _Z3.Expr[_lift(a, ctx), _lift(b, ctx)]
        return (r.head === :&& ? _Z3.And(xs) : _Z3.Or(xs), :bool)
    end
    r.head === :call || error("localization: unsupported rule $(repr(r))")
    op = r.args[1]
    if op === :ifelse
        (c, _) = ev(1)
        if !(c isa _Z3.Expr)               # concrete condition: only the taken branch matters
            return c ? ev(2) : ev(3)
        end
        (a, ta), (b, tb) = ev(2), ev(3)
        return (_Z3.If(c, _lift(a, ctx), _lift(b, ctx)), ta)
    elseif op === :!
        (a, _) = ev(1)
        return a isa _Z3.Expr ? (_Z3.Not(a), :bool) : (!a, :bool)
    end
    vals = [ev(i) for i in eachindex(node.children)]
    ints = [_as_int(v, t, ctx) for (v, t) in vals]
    concrete = all(v -> !(v isa _Z3.Expr), ints)
    if op in (:+, :-, :*)
        concrete && return (op === :+ ? sum(ints) : op === :* ? prod(ints) :
                            length(ints) == 1 ? -ints[1] : ints[1] - sum(ints[2:end]), :int)
        zs = _Z3.Expr[_lift(v, ctx) for v in ints]
        f = op === :+ ? CEXGeneration._z3_add : op === :* ? CEXGeneration._z3_mul : CEXGeneration._z3_sub
        length(zs) == 1 && op === :- && return (CEXGeneration._z3_sub(ctx, _Z3.Expr[_Z3.IntVal(0, ctx), zs[1]]), :int)
        return (f(ctx, zs), :int)
    elseif op in (:<=, :>=, :<, :>, :(==))
        a, b = ints
        if concrete
            return (op === :<= ? a <= b : op === :>= ? a >= b : op === :< ? a < b :
                    op === :> ? a > b : a == b, :bool)
        end
        za, zb = _lift(a, ctx), _lift(b, ctx)
        g = op === :<= ? CEXGeneration._z3_le : op === :>= ? CEXGeneration._z3_ge :
            op === :< ? CEXGeneration._z3_lt : op === :> ? CEXGeneration._z3_gt : CEXGeneration._z3_eq
        return (g(ctx, za, zb), :bool)
    end
    error("localization: unsupported operator $op")
end

"""Concrete value of the subtree at `path` on `input` (no hole)."""
_concrete_at(tree, path, grammar, input) =
    _symeval(node_at(tree, path), path, NodePath([-1]), nothing, :int, grammar, input, nothing)[1]

"""
    repairable_paths(tree, grammar, spec, ev; timeout_ms=2000, candidates=nothing)
        -> (repairable::Dict{NodePath,Vector}, minimal::Vector{NodePath}, status::Dict{NodePath,Symbol})

For each candidate node (default: every node), decide whether it is a single-node
correction set for the evidence `ev`: `:sat` ⇒ repairable, with its angelic values
(one per evidence input, complete tests first, then constrained bindings); `:unsat` ⇒ not;
`:unknown` ⇒ undecided (timeout). `minimal` holds the repairable nodes with no repairable
descendant.
"""
function repairable_paths(tree::RuleNode, grammar::AbstractGrammar, spec, ev::LocEvidence;
                          timeout_ms::Integer = 2_000, candidates = nothing)
    sf = spec.synth_funs[1]
    sexprs = Any[CEXGeneration.read_sexprs(c)[1] for c in spec.constraints]
    free_names = String[fv.name for fv in spec.free_vars]
    var_types = Dict{String,Symbol}(fv.name => (fv.sort == "Bool" ? :bool : :int) for fv in spec.free_vars)
    cons = [(b, _model_to_input(spec, b)) for b in ev.constrained]
    ctx = _Z3.Context()
    s = _Z3.Solver(ctx)
    CEXGeneration._csat_configure!(ctx, s; timeout_ms = timeout_ms, nl_arith = false)
    repairable = Dict{NodePath,Vector}()
    status = Dict{NodePath,Symbol}()
    paths = candidates === nothing ? node_paths(tree) : candidates
    for path in paths
        ty = _node_ty(grammar, node_at(tree, path))
        _Z3.push(s)
        holes = _Z3.Expr[]
        mk(j) = ty === :bool ? _Z3.BoolVar("h$j", ctx) : _Z3.IntVar("h$j", ctx)
        try
            j = 0
            for (inp, y) in ev.complete
                h = mk(j += 1); push!(holes, h)
                (v, t) = _symeval(tree, Int[], path, h, ty, grammar, inp, ctx)
                out = _lift(_as_int(v, t, ctx), ctx)
                _Z3.add(s, CEXGeneration._z3_eq(ctx, out, _lift(y, ctx)))
            end
            for (b, inp) in cons
                h = mk(j += 1); push!(holes, h)
                (v, t) = _symeval(tree, Int[], path, h, ty, grammar, inp, ctx)
                out = _lift(_as_int(v, t, ctx), ctx)
                varmap = Dict{String,_Z3.Expr}(n => _lift(b[n], ctx) for n in free_names)
                env = CEXGeneration._CSatEnv(ctx, varmap, var_types, sf.name, free_names, out, true)
                for sx in sexprs
                    _Z3.add(s, CEXGeneration._csat_to_z3(sx, env, :bool))
                end
            end
            r = _Z3.check(s)
            if r.result == _Z3.Libz3.Z3_L_TRUE
                m = _Z3.model(s)
                repairable[path] = [CEXGeneration._cex_model_value(ctx, m, h, ty === :int) for h in holes]
                status[path] = :sat
            else
                status[path] = r.result == _Z3.Libz3.Z3_L_FALSE ? :unsat : :unknown
            end
        catch err
            status[path] = :error
        finally
            _Z3.pop(s)
        end
    end
    rp = collect(keys(repairable))
    minimal = [p for p in rp if !any(q -> _is_descendant(q, p), rp)]
    return (repairable, minimal, status)
end

"""
    angelic_class(tree, grammar, path, angelic, inputs) -> Symbol

What the angelic values at a repairable node suggest (the RQ2 hook):
`:FLIP` a Bool node whose value must change on some inputs; `:VAR` an Int node that
must equal one input variable everywhere; `:CONST` a constant everywhere; `:OFFSET`
the original value plus a constant; `:SPLIT` anything else (values that differ by
region — guard insertion). `inputs` are the program inputs in evidence order.
"""
function angelic_class(tree::RuleNode, grammar::AbstractGrammar, path::NodePath,
                       angelic::Vector, inputs::Vector{Dict{Symbol,Any}})::Symbol
    node = node_at(tree, path)
    ok = [i for i in eachindex(angelic) if angelic[i] !== nothing]
    isempty(ok) && return :UNKNOWN
    orig = [(_concrete_at(tree, path, grammar, inputs[i])) for i in ok]
    ang = [angelic[i] for i in ok]
    if _node_ty(grammar, node) === :bool
        flips = any(i -> (orig[i] ? 1 : 0) != ang[i], eachindex(ok))
        return flips ? :FLIP : :NOCHANGE
    end
    origi = [o isa Bool ? Int(o) : o for o in orig]
    length(unique(ang)) == 1 && return :CONST
    for v in keys(inputs[ok[1]])
        all(i -> inputs[ok[i]][v] == ang[i], eachindex(ok)) && return :VAR
    end
    d = ang .- origi
    length(unique(d)) == 1 && return :OFFSET
    return :SPLIT
end
