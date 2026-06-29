"""
In-process per-constraint satisfaction checking via a persistent high-level
`Z3.Solver` (the warm-solver counterpart to `check_constraint_satisfaction`).

`check_constraint_satisfaction` (constraint_satisfaction.jl) is correct but spawns a
fresh `z3` subprocess per candidate (temp file + re-parse). `ConstraintSatSolver`
keeps the same Method 2 algorithm — one assumption literal `pᵢ` per constraint with
`(=> pᵢ (not Cᵢ))`, isolated by `(check-sat-assuming (pᵢ))` — but realised on a
**persistent in-process `Z3.Solver`**:

  * the free-var constants, the synth-output constant `out`, and every
    `(=> pᵢ (not Cᵢ))` are built as `Z3.Expr` AST and asserted **once** (the AST is
    reused across candidates),
  * per candidate it only asserts `out == candidate(inputs)` inside a `push`/`pop`
    and runs one `check-sat-assuming` per constraint — no subprocess, no re-parse.

Returns the same `ConstraintSatResult`.

Scope (same as the warm subprocess query): a single synth-fun whose only application
in the constraints is the canonical `(f <free vars>)` over the declared free vars.
Non-canonical specs raise during construction — callers fall back to the subprocess
path. Comparisons/`=`/`distinct` are treated as integer (LIA).
"""

# ── Z3.Expr builders not in the high-level API (drop to Libz3) ───────────────────
_csat_cref(ctx::Z3.Context) = ctx.ctx
_csat_raw(e::Z3.Expr) = e.expr
_csat_nary(ctx, mk, args) = Z3.Expr(ctx, mk(_csat_cref(ctx), length(args), map(_csat_raw, args)))
_csat_bin(ctx, mk, a, b)  = Z3.Expr(ctx, mk(_csat_cref(ctx), _csat_raw(a), _csat_raw(b)))

_z3_add(ctx, args) = _csat_nary(ctx, Z3.Libz3.Z3_mk_add, args)
_z3_sub(ctx, args) = _csat_nary(ctx, Z3.Libz3.Z3_mk_sub, args)
_z3_mul(ctx, args) = _csat_nary(ctx, Z3.Libz3.Z3_mk_mul, args)
_z3_ge(ctx, a, b)  = _csat_bin(ctx, Z3.Libz3.Z3_mk_ge, a, b)
_z3_gt(ctx, a, b)  = _csat_bin(ctx, Z3.Libz3.Z3_mk_gt, a, b)
_z3_le(ctx, a, b)  = _csat_bin(ctx, Z3.Libz3.Z3_mk_le, a, b)
_z3_lt(ctx, a, b)  = _csat_bin(ctx, Z3.Libz3.Z3_mk_lt, a, b)
_z3_eq(ctx, a, b)  = _csat_bin(ctx, Z3.Libz3.Z3_mk_eq, a, b)
_z3_distinct(ctx, args) = _csat_nary(ctx, Z3.Libz3.Z3_mk_distinct, args)

"""Bool→Int via `(ite e 1 0)`; Int→Bool via `(> e 0)`; identity otherwise."""
function _csat_coerce(ctx::Z3.Context, e::Z3.Expr, from::Symbol, to::Symbol)::Z3.Expr
    from == to && return e
    from == :bool && to == :int && return Z3.If(e, Z3.IntVal(1, ctx), Z3.IntVal(0, ctx))
    from == :int && to == :bool && return _z3_gt(ctx, e, Z3.IntVal(0, ctx))
    error("Unsupported coercion: $from → $to")
end

"""Conversion environment shared by constraint and candidate building."""
struct _CSatEnv
    ctx::Z3.Context
    varmap::Dict{String,Z3.Expr}      # name → const (free vars, also candidate params after renaming)
    var_types::Dict{String,Symbol}    # name → :int/:bool
    synth_name::String
    free_names::Vector{String}
    out::Z3.Expr
    out_is_int::Bool
end

"""
Convert a parsed s-expression to a `Z3.Expr` of `expected` type, mirroring
`rulenode_to_smt2`'s type tracking. The canonical synth-fun application
`(f <free vars>)` maps to `out`; free vars map to `env.varmap`.
"""
function _csat_to_z3(s, env::_CSatEnv, expected::Symbol)::Z3.Expr
    ctx = env.ctx
    if s isa AbstractString
        occursin(r"^-?\d+$", s) && return _csat_coerce(ctx, Z3.IntVal(parse(Int, s), ctx), :int, expected)
        s == "true"  && return _csat_coerce(ctx, Z3.BoolVal(true, ctx), :bool, expected)
        s == "false" && return _csat_coerce(ctx, Z3.BoolVal(false, ctx), :bool, expected)
        haskey(env.varmap, s) && return _csat_coerce(ctx, env.varmap[s], env.var_types[s], expected)
        error("Unknown atom: $s")
    end
    isempty(s) && error("Empty s-expression")
    head = s[1]::AbstractString

    if head == env.synth_name
        argstrs = [a isa AbstractString ? String(a) : sexp_to_str(a) for a in s[2:end]]
        argstrs == env.free_names ||
            error("non-canonical application $(sexp_to_str(s)); use the subprocess path")
        return _csat_coerce(ctx, env.out, env.out_is_int ? :int : :bool, expected)
    end

    if head in ("+", "-", "*")
        if head == "-" && length(s) == 2
            res = _z3_sub(ctx, [Z3.IntVal(0, ctx), _csat_to_z3(s[2], env, :int)])
        else
            cargs = Z3.Expr[_csat_to_z3(a, env, :int) for a in s[2:end]]
            res = head == "+" ? _z3_add(ctx, cargs) : head == "-" ? _z3_sub(ctx, cargs) : _z3_mul(ctx, cargs)
        end
        return _csat_coerce(ctx, res, :int, expected)
    elseif head in (">=", ">", "<=", "<", "=", "distinct")
        cargs = Z3.Expr[_csat_to_z3(a, env, :int) for a in s[2:end]]
        res = head == ">="       ? _z3_ge(ctx, cargs[1], cargs[2]) :
              head == ">"        ? _z3_gt(ctx, cargs[1], cargs[2]) :
              head == "<="       ? _z3_le(ctx, cargs[1], cargs[2]) :
              head == "<"        ? _z3_lt(ctx, cargs[1], cargs[2]) :
              head == "="        ? _z3_eq(ctx, cargs[1], cargs[2]) :
                                   _z3_distinct(ctx, cargs)
        return _csat_coerce(ctx, res, :bool, expected)
    elseif head in ("and", "or")
        cargs = Z3.Expr[_csat_to_z3(a, env, :bool) for a in s[2:end]]
        res = head == "and" ? Z3.And(cargs) : Z3.Or(cargs)
        return _csat_coerce(ctx, res, :bool, expected)
    elseif head == "not"
        return _csat_coerce(ctx, Z3.Not(_csat_to_z3(s[2], env, :bool)), :bool, expected)
    elseif head == "=>"
        a = _csat_to_z3(s[2], env, :bool); b = _csat_to_z3(s[3], env, :bool)
        return _csat_coerce(ctx, Z3.Or([Z3.Not(a), b]), :bool, expected)
    elseif head == "ite"
        cond = _csat_to_z3(s[2], env, :bool)
        return Z3.If(cond, _csat_to_z3(s[3], env, expected), _csat_to_z3(s[4], env, expected))
    end
    error("Unsupported operator in s-expression: $head")
end

# ── Persistent solver ───────────────────────────────────────────────────────────

"""
    ConstraintSatSolver(spec::Spec)

Persistent in-process solver for Method 2. Builds the free-var consts, the synth
output const, and each `(=> pᵢ (not Cᵢ))` once; reuse across candidates via
`check_constraint_satisfaction(css, candidate_exprs)`.
"""
mutable struct ConstraintSatSolver
    env::_CSatEnv
    solver::Z3.Solver
    assume_lits::Vector{Z3.Expr}
    constraints::Vector{String}
    param_names::Vector{String}
end

function ConstraintSatSolver(spec::Spec)
    isempty(spec.synth_funs) && error("ConstraintSatSolver: spec has no synth-fun")
    sf = spec.synth_funs[1]
    ctx = Z3.Context()
    solver = Z3.Solver(ctx)

    varmap = Dict{String,Z3.Expr}()
    var_types = Dict{String,Symbol}()
    free_names = String[]
    for fv in spec.free_vars
        t = fv.sort == "Bool" ? :bool : :int
        varmap[fv.name] = t == :bool ? Z3.BoolVar(fv.name, ctx) : Z3.IntVar(fv.name, ctx)
        var_types[fv.name] = t
        push!(free_names, fv.name)
    end

    out_is_int = sf.sort != "Bool"
    out = out_is_int ? Z3.IntVar("__csat_out_$(sf.name)", ctx) : Z3.BoolVar("__csat_out_$(sf.name)", ctx)
    env = _CSatEnv(ctx, varmap, var_types, sf.name, free_names, out, out_is_int)

    assume_lits = Z3.Expr[]
    for (i, c) in enumerate(spec.constraints)
        cexpr = _csat_to_z3(read_sexprs(c)[1], env, :bool)
        p = Z3.BoolVar("__csat_assume_$i", ctx)
        Z3.add(solver, Z3.Or([Z3.Not(p), Z3.Not(cexpr)]))   # (=> pᵢ (not Cᵢ))
        push!(assume_lits, p)
    end

    param_names = String[pname for (pname, _) in sf.params]
    return ConstraintSatSolver(env, solver, assume_lits, copy(spec.constraints), param_names)
end

"""Build the candidate body (params renamed to free vars, Bool→Int wrapped) as Z3.Expr."""
function _csat_build_candidate(css::ConstraintSatSolver, candidate_exprs::Dict{String,String})::Z3.Expr
    body = get(candidate_exprs, css.env.synth_name, nothing)
    body === nothing && error("ConstraintSatSolver: no candidate for $(css.env.synth_name)")
    b = substitute_params(body, css.param_names, css.env.free_names)
    if css.env.out_is_int && _looks_like_bool(b)
        b = _wrap_bool_to_int(b)
    end
    _csat_to_z3(read_sexprs(b)[1], css.env, css.env.out_is_int ? :int : :bool)
end

"""`:sat`/`:unsat`/`:unknown` for `(check-sat-assuming (lit))` on the persistent solver."""
function _csat_check_assuming(css::ConstraintSatSolver, lit::Z3.Expr)::Symbol
    r = Z3.Libz3.Z3_solver_check_assumptions(css.env.ctx.ctx, css.solver.solver, 1, [lit.expr])
    r == Z3.Libz3.Z3_L_TRUE  ? :sat :
    r == Z3.Libz3.Z3_L_FALSE ? :unsat : :unknown
end

"""
    check_constraint_satisfaction(css::ConstraintSatSolver, candidate_exprs) :: ConstraintSatResult

Per-constraint universal check for `candidate_exprs` using the persistent solver.
Same semantics/return type as the subprocess `check_constraint_satisfaction`.
"""
function check_constraint_satisfaction(css::ConstraintSatSolver, candidate_exprs::Dict{String,String})::ConstraintSatResult
    n = length(css.constraints)
    n == 0 && return ConstraintSatResult(String[], Bool[], Symbol[])

    cand = try
        _csat_build_candidate(css, candidate_exprs)
    catch
        # Ill-typed candidate: like the subprocess path's z3 error, report undetermined.
        return ConstraintSatResult(copy(css.constraints), fill(false, n), fill(:unknown, n))
    end

    status = Vector{Symbol}(undef, n)
    Z3.push(css.solver)
    try
        Z3.add(css.solver, _z3_eq(css.env.ctx, css.env.out, cand))
        for i in 1:n
            status[i] = _csat_check_assuming(css, css.assume_lits[i])
        end
    finally
        Z3.pop(css.solver)
    end
    satisfied = [s === :unsat for s in status]
    return ConstraintSatResult(copy(css.constraints), satisfied, status)
end

function check_constraint_satisfaction(css::ConstraintSatSolver, sfun_name::AbstractString, candidate_expr::AbstractString)::ConstraintSatResult
    check_constraint_satisfaction(css, Dict{String,String}(String(sfun_name) => String(candidate_expr)))
end
