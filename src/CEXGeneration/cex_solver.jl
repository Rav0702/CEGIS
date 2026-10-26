"""
In-process counterexample extraction via a persistent high-level `Z3.Solver` —
the warm counterpart to `generate_cex_query` + `verify_query` (subprocess).

Mirrors the fresh-constant construction of `generate_query`: the free vars, a
spec-valid output constant `out_<f>`, a candidate output constant, and every
candidate-independent assertion are built as Z3 AST **once**:

  * for each constraint that applies the synth-fun, a copy with `(f …) ↦ out_<f>`
    is asserted — `out_<f>` is "an output the spec accepts at this input",
  * the violation disjunction `(or (not C₁[f↦cand]) … (not Cₙ[f↦cand]))` is
    asserted over a candidate output constant.

Per candidate only `cand_out == candidate(inputs)` is asserted inside a
`push`/`pop` and one `check-sat` runs — no subprocess, no temp file, no
re-parse. On `:sat` the model is read in-process (`Z3_model_eval` with model
completion) into the same key scheme `verify_query` produces: free-var names
plus `out_<f>`, so `Z3Result` consumers work unchanged.

Scope (same as `ConstraintSatSolver`): a single synth-fun whose only
application in the constraints is the canonical `(f <free vars>)` over the
declared free vars, LIA operators only, no preamble helpers. Out-of-scope
specs raise during construction — callers fall back to the subprocess path.
"""

"""
    CexSolver(spec::Spec; timeout_ms=0, nl_arith=true)

Persistent in-process counterexample finder. Builds all candidate-independent
assertions once; reuse across candidates via `find_counterexample`.

`timeout_ms > 0` bounds each counterexample check (timed-out ⇒ `:unknown`);
`nl_arith=false` disables Z3's crash-prone nonlinear reasoning (nonlinear
goals ⇒ `:unknown`). Both recommended for GA workloads where candidates may
contain `*` — see `_csat_configure!`.
"""
mutable struct CexSolver
    env_spec::_CSatEnv        # `(f …)` in constraints ↦ out_<f> (spec-valid output)
    env_cand::_CSatEnv        # `(f …)` in constraints ↦ candidate output const
    solver::Z3.Solver
    param_names::Vector{String}
    out_key::String           # model key for the spec-valid output ("out_<f>")
    # Output oracle: the spec-validity copies alone, in a Z3 context of its
    # own. `complete_output` and `output_is_unique` pin an input here. The main
    # `solver` also carries the violation disjunction over a free candidate
    # constant, which says nothing about which outputs are valid. A separate
    # context because terms built in the search's context change the models Z3
    # returns there — measured: a solver merely *existing* beside it changed the
    # counterexamples of 2 of 3 replayed countpos3 seeds, so stored runs no
    # longer replayed bit-for-bit.
    env_out::_CSatEnv
    out_solver::Z3.Solver
end

function CexSolver(spec::Spec; timeout_ms::Integer=0, nl_arith::Bool=true)
    isempty(spec.synth_funs) && error("CexSolver: spec has no synth-fun")
    isempty(spec.constraints) && error("CexSolver: spec has no constraints")
    sf = spec.synth_funs[1]
    ctx = Z3.Context()
    solver = Z3.Solver(ctx)
    _csat_configure!(ctx, solver; timeout_ms=timeout_ms, nl_arith=nl_arith)

    varmap, var_types, free_names = _csat_free_var_env(spec, ctx)

    out_is_int = sf.sort != "Bool"
    out_key = "out_$(sf.name)"
    mkconst(name) = out_is_int ? Z3.IntVar(name, ctx) : Z3.BoolVar(name, ctx)
    env_spec = _CSatEnv(ctx, varmap, var_types, sf.name, free_names, mkconst(out_key), out_is_int)
    env_cand = _CSatEnv(ctx, varmap, var_types, sf.name, free_names,
                        mkconst("__cex_cand_$(sf.name)"), out_is_int)

    # Spec-validity copies: constraints applying the synth-fun, with the
    # application replaced by out_<f> (mirrors generate_query's filter).
    for c in spec.constraints
        contains(c, "($(sf.name)") || continue
        Z3.add(solver, _csat_to_z3(read_sexprs(c)[1], env_spec, :bool))
    end

    octx = Z3.Context()
    ovarmap, ovar_types, ofree = _csat_free_var_env(spec, octx)
    env_out = _CSatEnv(octx, ovarmap, ovar_types, sf.name, ofree,
                       out_is_int ? Z3.IntVar(out_key, octx) : Z3.BoolVar(out_key, octx), out_is_int)
    out_solver = Z3.Solver(octx)
    _csat_configure!(octx, out_solver; timeout_ms=timeout_ms, nl_arith=nl_arith)
    for c in spec.constraints
        contains(c, "($(sf.name)") || continue
        Z3.add(out_solver, _csat_to_z3(read_sexprs(c)[1], env_out, :bool))
    end

    # The candidate violates at least one constraint.
    viol = Z3.Expr[Z3.Not(_csat_to_z3(read_sexprs(c)[1], env_cand, :bool))
                   for c in spec.constraints]
    Z3.add(solver, Z3.Or(viol))

    param_names = String[pname for (pname, _) in sf.params]
    return CexSolver(env_spec, env_cand, solver, param_names, out_key, env_out, out_solver)
end

"""
Evaluate `e` in model `m` (with model completion) and read it as an Int.
Booleans map to 1/0, matching `_parse_z3_numeral` on the subprocess path.
Returns `nothing` if the value cannot be extracted.
"""
function _cex_model_value(ctx::Z3.Context, m::Z3.Model, e::Z3.Expr, is_int::Bool)::Union{Int,Nothing}
    out = Ref{Z3.Libz3.Z3_ast}(C_NULL)
    Z3.Libz3.Z3_model_eval(ctx.ctx, m.model, e.expr, true, out) || return nothing
    if is_int
        v = Ref{Int64}(0)
        Z3.Libz3.Z3_get_numeral_int64(ctx.ctx, out[], v) || return nothing
        return Int(v[])
    end
    b = Z3.Libz3.Z3_get_bool_value(ctx.ctx, out[])
    b == Z3.Libz3.Z3_L_UNDEF && return nothing
    return b == Z3.Libz3.Z3_L_TRUE ? 1 : 0
end

"""
    find_counterexample(cs::CexSolver, candidate_exprs) :: Z3Result

Counterexample query for the candidate on the persistent solver. Same
semantics and result shape as `verify_query(generate_cex_query(spec, …))`:

  - `:unsat`   — the candidate satisfies every constraint for all inputs.
  - `:sat`     — the model holds a violating input (free-var names) and a
                 spec-valid output at that input (`out_<f>`).
  - `:unknown` — the candidate could not be built (ill-typed) or Z3 gave up.
"""
function find_counterexample(cs::CexSolver, candidate_exprs::Dict{String,String})::Z3Result
    cand = try
        _csat_candidate_expr(cs.env_cand, cs.param_names, candidate_exprs)
    catch
        return Z3Result(:unknown, Dict{String,Any}(), String[])
    end

    ctx = cs.env_cand.ctx
    Z3.push(cs.solver)
    try
        Z3.add(cs.solver, _z3_eq(ctx, cs.env_cand.out, cand))
        t0 = time_ns()
        r = try
            Z3.check(cs.solver)
        finally
            _z3_count!(:cex_queries, t0)
        end
        r.result == Z3.Libz3.Z3_L_FALSE && return Z3Result(:unsat, Dict{String,Any}(), String[])
        r.result == Z3.Libz3.Z3_L_TRUE  || return Z3Result(:unknown, Dict{String,Any}(), String[])

        m = Z3.model(cs.solver)
        model = Dict{String,Any}()
        for name in cs.env_cand.free_names
            v = _cex_model_value(ctx, m, cs.env_cand.varmap[name],
                                 cs.env_cand.var_types[name] == :int)
            v === nothing || (model[name] = v)
        end
        v = _cex_model_value(ctx, m, cs.env_spec.out, cs.env_spec.out_is_int)
        v === nothing || (model[cs.out_key] = v)
        return Z3Result(:sat, model, String[])
    finally
        Z3.pop(cs.solver)
    end
end

find_counterexample(cs::CexSolver, sfun_name::AbstractString, candidate_expr::AbstractString) =
    find_counterexample(cs, Dict{String,String}(String(sfun_name) => String(candidate_expr)))

# ── Extra solver information: violation witnesses & output completion ─────────

"""
    check_constraint_satisfaction_witnesses(css::ConstraintSatSolver, candidate_exprs)
        :: Tuple{ConstraintSatResult, Vector{Union{Dict{String,Any},Nothing}}}

Per-constraint universal check that additionally extracts, for every **violated**
constraint, the Z3 model as a witness input (free-var name → value). Witnesses
are `nothing` for satisfied/undetermined constraints. Same solver session and
cost as `check_constraint_satisfaction` plus one model read per violation —
this is the raw material for fault localization and witness-derived tests.
"""
function check_constraint_satisfaction_witnesses(
    css::ConstraintSatSolver, candidate_exprs::Dict{String,String},
)::Tuple{ConstraintSatResult,Vector{Union{Dict{String,Any},Nothing}}}
    n = length(css.constraints)
    witnesses = Vector{Union{Dict{String,Any},Nothing}}(nothing, n)
    n == 0 && return (ConstraintSatResult(String[], Bool[], Symbol[]), witnesses)

    cand = try
        _csat_build_candidate(css, candidate_exprs)
    catch
        return (ConstraintSatResult(copy(css.constraints), fill(false, n), fill(:unknown, n)),
                witnesses)
    end

    env = css.env
    status = Vector{Symbol}(undef, n)
    Z3.push(css.solver)
    try
        Z3.add(css.solver, _z3_eq(env.ctx, env.out, cand))
        for i in 1:n
            status[i] = _csat_check_assuming(css, css.assume_lits[i])
            status[i] === :sat || continue
            m = Z3.model(css.solver)
            w = Dict{String,Any}()
            for name in env.free_names
                v = _cex_model_value(env.ctx, m, env.varmap[name], env.var_types[name] == :int)
                v === nothing || (w[name] = v)
            end
            witnesses[i] = w
        end
    finally
        Z3.pop(css.solver)
    end
    satisfied = [s === :unsat for s in status]
    return (ConstraintSatResult(copy(css.constraints), satisfied, status), witnesses)
end

check_constraint_satisfaction_witnesses(css::ConstraintSatSolver,
                                        sfun_name::AbstractString,
                                        candidate_expr::AbstractString) =
    check_constraint_satisfaction_witnesses(
        css, Dict{String,String}(String(sfun_name) => String(candidate_expr)))

"""Pin the free vars named in `input` to their values on `solver` (inside a push)."""
function _cex_pin!(solver::Z3.Solver, env::_CSatEnv, input::Dict{String,<:Any})
    for (name, v) in input
        c = get(env.varmap, name, nothing)
        c === nothing && continue
        pin = env.var_types[name] == :int ? Z3.IntVal(Int(v), env.ctx) :
                                            Z3.BoolVal(v == 1 || v === true, env.ctx)
        Z3.add(solver, _z3_eq(env.ctx, c, pin))
    end
    return nothing
end

"""An output value as a Z3 constant of the synth-fun's sort (Bool outputs travel as 1/0)."""
_cex_out_val(env::_CSatEnv, v) =
    env.out_is_int ? Z3.IntVal(Int(v), env.ctx) : Z3.BoolVal(v == 1 || v === true, env.ctx)

"""
    complete_output(cs::CexSolver, input::Dict{String,<:Any}) -> Union{Int,Nothing}

Given a concrete input (free-var name → value), ask the spec what a **valid
output** at that input is: pins the free vars, checks the spec-validity copies,
and reads `out_<f>` from the model. Returns `nothing` when the spec admits no
output there (or Z3 can't tell). Turns a violation witness into a full
`(input, expected)` test case.

The output is *a* valid one, not *the* valid one: when the spec accepts several
outputs at this input, Z3 picks one arbitrarily. Check `output_is_unique`
before demanding it of a candidate.
"""
function complete_output(cs::CexSolver, input::Dict{String,<:Any})::Union{Int,Nothing}
    env = cs.env_out
    Z3.push(cs.out_solver)
    try
        _cex_pin!(cs.out_solver, env, input)
        t0 = time_ns()
        r = try
            Z3.check(cs.out_solver)
        finally
            _z3_count!(:complete_output, t0)
        end
        r.result == Z3.Libz3.Z3_L_TRUE || return nothing
        return _cex_model_value(env.ctx, Z3.model(cs.out_solver), env.out, env.out_is_int)
    finally
        Z3.pop(cs.out_solver)
    end
end

"""
    output_is_unique(cs::CexSolver, input, value) -> Union{Bool,Nothing}

Is `value` the **only** output the spec accepts at `input`? Pins the input,
excludes `value`, and asks for another valid output:

  - `true`    — no other output exists: the complete test `(input, value)` is sound.
  - `false`   — another output is equally correct. A test demanding `value` would
                fail correct programs, so the counterexample must become an
                *incomplete* test (input only, judged by the constraints).
  - `nothing` — Z3 could not decide (timeout); callers must treat it as `false`.

The reference CDGP's second-output query (`searchForSecondOutput` in
`CDGPState.createTestFromCounterex`).
"""
function output_is_unique(cs::CexSolver, input::Dict{String,<:Any}, value)::Union{Bool,Nothing}
    env = cs.env_out
    Z3.push(cs.out_solver)
    try
        _cex_pin!(cs.out_solver, env, input)
        Z3.add(cs.out_solver, Z3.Not(_z3_eq(env.ctx, env.out, _cex_out_val(env, value))))
        t0 = time_ns()
        r = try
            Z3.check(cs.out_solver)
        finally
            _z3_count!(:output_unique, t0)
        end
        r.result == Z3.Libz3.Z3_L_FALSE && return true
        r.result == Z3.Libz3.Z3_L_TRUE && return false
        return nothing
    finally
        Z3.pop(cs.out_solver)
    end
end

"""
    spec_single_answer(spec::Spec; timeout_ms=5_000) -> Union{Bool,Nothing}

Does the spec accept **at most one output at every input**? One query for an
input with two distinct outputs that both satisfy every constraint applying the
synth-fun. `true` means every counterexample completes into a sound complete
test and no per-test `output_is_unique` query is needed; `nothing` means Z3
could not decide within `timeout_ms`.

`false` does not mean every input is ambiguous: a spec can be unique everywhere
except a don't-care region (`(=> (>= x 0) …)`), so callers still check each
counterexample. The reference's `hasSingleAnswerForEveryInput`.

Runs in a Z3 context of its own. Building its terms in the search's context
changes the models Z3 later returns there — measured: a different fifth
counterexample on max2 — so a run would stop replaying bit-for-bit. Same
in-process scope as `CexSolver` (raises on a non-canonical application).
"""
function spec_single_answer(spec::Spec; timeout_ms::Integer=5_000)::Union{Bool,Nothing}
    sf = spec.synth_funs[1]
    valid = Any[read_sexprs(c)[1] for c in spec.constraints if contains(c, "($(sf.name)")]
    isempty(valid) && return false   # f is unconstrained: every output is valid
    ctx = Z3.Context()
    varmap, var_types, free_names = _csat_free_var_env(spec, ctx)
    out_is_int = sf.sort != "Bool"
    mk(name) = out_is_int ? Z3.IntVar(name, ctx) : Z3.BoolVar(name, ctx)
    a = _CSatEnv(ctx, varmap, var_types, sf.name, free_names, mk("__out_a"), out_is_int)
    b = _CSatEnv(ctx, varmap, var_types, sf.name, free_names, mk("__out_b"), out_is_int)
    s = Z3.Solver(ctx)
    _csat_configure!(ctx, s; timeout_ms=timeout_ms, nl_arith=false)
    for sx in valid
        Z3.add(s, _csat_to_z3(sx, a, :bool))
        Z3.add(s, _csat_to_z3(sx, b, :bool))
    end
    Z3.add(s, Z3.Not(_z3_eq(ctx, a.out, b.out)))
    t0 = time_ns()
    r = try
        Z3.check(s)
    finally
        _z3_count!(:output_unique, t0)
    end
    r.result == Z3.Libz3.Z3_L_FALSE && return true
    r.result == Z3.Libz3.Z3_L_TRUE && return false
    return nothing
end
