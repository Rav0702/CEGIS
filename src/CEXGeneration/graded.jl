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
