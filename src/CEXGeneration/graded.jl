"""
    graded.jl

Per-constraint counterexample queries for *graded* fitness.

`generate_query` (in `query.jl`) bundles every spec constraint into a single
`(not (and c1 c2 ...))` check, so it can only answer the binary question "is the
candidate correct?" and return one counterexample. The genetic-search POC needs a
finer signal: *how many* of the spec's constraints does a candidate satisfy
universally? `generate_constraint_check_query` builds a query that checks exactly
**one** constraint:

  - `:unsat` ⇒ the candidate satisfies constraint `idx` for all inputs.
  - `:sat`   ⇒ the candidate violates it; the model is a concrete counterexample
               input (used to steer targeted mutation).

Unlike `generate_query`, this needs no fresh constants — the candidate is inlined
via `define-fun`, so the constraint's `(f ...)` calls are expanded by Z3 directly.
"""

"""
    generate_constraint_check_query(spec::Spec, candidate_exprs::Dict{String,String}, idx::Int) :: String

Build an SMT-LIB2 query that asks whether the given candidate(s) violate the
`idx`-th constraint of `spec`. Reuses the candidate-substitution helpers from
`query.jl`.
"""
function generate_constraint_check_query(
    spec::Spec,
    candidate_exprs::Dict{String,String},
    idx::Int,
)::String
    isa(spec, Spec) || error("spec is not a Spec object: $(typeof(spec))")
    (1 <= idx <= length(spec.constraints)) ||
        error("constraint index $idx out of range (1:$(length(spec.constraints)))")

    parts = String[]
    push!(parts, "(set-logic $(spec.logic))")
    push!(parts, "(set-option :model.completion true)")

    # Preamble (sorts, helper define-funs, uninterpreted functions) in source order.
    if !isempty(spec.ordered_preamble)
        for item in spec.ordered_preamble
            push!(parts, item)
        end
    end

    # Free variables (the inputs Z3 searches over for a counterexample).
    for fv in spec.free_vars
        push!(parts, "(declare-const $(fv.name) $(fv.sort))")
    end

    # Inline each candidate as a define-fun so constraint calls (f x y) expand.
    for sfun in spec.synth_funs
        candidate = get(candidate_exprs, sfun.name, nothing)
        candidate === nothing && continue
        param_names   = [pname for (pname, _) in sfun.params]
        free_var_names = [fv.name for fv in spec.free_vars]
        body = substitute_params(candidate, param_names, free_var_names)
        if sfun.sort == "Int" && _looks_like_bool(body)
            body = _wrap_bool_to_int(body)
        end
        param_decls = join(["($(pname) $(sort))" for (pname, sort) in sfun.params], " ")
        push!(parts, "(define-fun $(sfun.name) ($param_decls) $(sfun.sort) $body)")
    end

    # Negate the single constraint: sat ⇒ a counterexample input exists.
    push!(parts, "(assert (not $(spec.constraints[idx])))")
    push!(parts, "(check-sat)")

    # Witness input values, for targeted mutation.
    if !isempty(spec.free_vars)
        var_list = join([fv.name for fv in spec.free_vars], " ")
        push!(parts, "(get-value ($var_list))")
    end

    return join(parts, "\n") * "\n"
end

# ── One-query graded check ──────────────────────────────────────────────────────
#
# `generate_constraint_check_query` answers ONE constraint per Z3 invocation, so the
# graded evaluator pays N process spawns (and re-parses the preamble N times) per
# candidate. `generate_graded_query` collapses all N checks into a *single* query by
# emitting the candidate/preamble once and then probing each constraint inside its
# own `(push)`/`(pop)` scope. One Z3 process, N independent (universal) verdicts —
# semantically identical to the N-query loop, just far cheaper.

"""
    ConstraintResult

Per-constraint verdict from `verify_graded_query`.

- `status`  — `:unsat` ⇒ candidate satisfies the constraint for **all** inputs;
              `:sat` ⇒ violated; `:unknown` ⇒ Z3 gave up (treat conservatively).
- `witness` — free-var counterexample (`name → value`) when `:sat`, else empty.
"""
struct ConstraintResult
    status::Symbol
    witness::Dict{String,Any}
end

"""
    generate_graded_query(spec::Spec, candidate_exprs::Dict{String,String}) :: String

Build a single SMT-LIB2 query that checks **every** constraint of `spec`
independently. The candidate is inlined once as a `define-fun`; each constraint is
negated inside a `(push)`/`(pop)` so the checks don't interfere. The emitted
`(check-sat)` results appear in `spec.constraints` order (parse with
`verify_graded_query`).
"""
function generate_graded_query(spec::Spec, candidate_exprs::Dict{String,String})::String
    isa(spec, Spec) || error("spec is not a Spec object: $(typeof(spec))")

    parts = String[]
    push!(parts, "(set-logic $(spec.logic))")
    push!(parts, "(set-option :model.completion true)")

    for item in spec.ordered_preamble
        push!(parts, item)
    end
    for fv in spec.free_vars
        push!(parts, "(declare-const $(fv.name) $(fv.sort))")
    end
    for sfun in spec.synth_funs
        candidate = get(candidate_exprs, sfun.name, nothing)
        candidate === nothing && continue
        param_names    = [pname for (pname, _) in sfun.params]
        free_var_names = [fv.name for fv in spec.free_vars]
        body = substitute_params(candidate, param_names, free_var_names)
        if sfun.sort == "Int" && _looks_like_bool(body)
            body = _wrap_bool_to_int(body)
        end
        param_decls = join(["($(pname) $(sort))" for (pname, sort) in sfun.params], " ")
        push!(parts, "(define-fun $(sfun.name) ($param_decls) $(sfun.sort) $body)")
    end

    var_list = isempty(spec.free_vars) ? "" : join([fv.name for fv in spec.free_vars], " ")
    for (idx, c) in enumerate(spec.constraints)
        push!(parts, "(push 1)")
        push!(parts, "(assert (not $c))")  # sat ⇒ constraint $idx violated somewhere
        push!(parts, "(check-sat)")
        isempty(var_list) || push!(parts, "(get-value ($var_list))")
        push!(parts, "(pop 1)")
    end

    return join(parts, "\n") * "\n"
end

"""
    verify_graded_query(query::String) :: Vector{ConstraintResult}

Run a `generate_graded_query` string through one Z3 call and parse the per-constraint
`(check-sat)` results in order. On `:sat`, the `(get-value …)` block that follows is
captured as the constraint's witness; on `:unsat`/`:unknown` Z3's `model is not
available` error line is harmlessly skipped.
"""
function verify_graded_query(query::String)::Vector{ConstraintResult}
    out = _z3_solve(query)

    results   = ConstraintResult[]
    status    = Ref{Union{Symbol,Nothing}}(nothing)
    buf       = String[]
    flush!() = begin
        s = status[]
        s === nothing && return
        if s == :sat
            push!(results, ConstraintResult(:sat, _parse_get_value_output(join(buf, "\n"))))
        else
            push!(results, ConstraintResult(s, Dict{String,Any}()))
        end
    end

    for raw in split(out, '\n')
        line = strip(raw)
        isempty(line) && continue
        if line in ("sat", "unsat", "unknown")
            flush!()
            status[] = Symbol(line)
            empty!(buf)
        else
            push!(buf, raw)  # get-value model lines (or skippable error blocks)
        end
    end
    flush!()
    return results
end
