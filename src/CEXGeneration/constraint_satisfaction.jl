"""
Per-constraint satisfaction checking (Method 2: warm solver + assumption literals).

Given a candidate program and a SyGuS spec, determine, *for each* top-level
`(constraint …)` clause, whether the candidate satisfies it for ALL inputs.

This is the sound universal check: a constraint Cᵢ is satisfied iff `(not Cᵢ)` is
UNSAT once the candidate is inlined as a `define-fun`. The naive way is one fresh
z3 process per constraint. Method 2 instead issues a SINGLE z3 process that:

  1. builds the candidate-independent context (declarations, candidate define-fun)
     exactly once,
  2. introduces one Boolean *assumption literal* `pᵢ` per constraint, asserting
     `(=> pᵢ (not Cᵢ))`, and
  3. runs `(check-sat-assuming (pᵢ))` once per constraint.

All n checks share the same solver session, so the context is parsed once and the
solver reuses learned clauses between checks. Each check is independent and sound:

  * `unsat` ⟹ no input violates Cᵢ ⟹ constraint satisfied (bit = true)
  * `sat`   ⟹ some input violates Cᵢ ⟹ constraint violated  (bit = false)

`(echo …)` markers delimit the checks so the results can be mapped back to the
originating constraint regardless of ordering.
"""

"""
Result of a per-constraint satisfaction check.

Fields:
  - `constraints` — the spec constraint strings, in spec order
  - `satisfied`   — `satisfied[i]` is true iff `constraints[i]` holds for all inputs
  - `status`      — raw per-constraint z3 verdict: `:unsat` (satisfied),
                    `:sat` (violated), or `:unknown`
"""
struct ConstraintSatResult
    constraints :: Vector{String}
    satisfied   :: Vector{Bool}
    status      :: Vector{Symbol}
end

"""Number of constraints the candidate satisfies for all inputs."""
n_satisfied(r::ConstraintSatResult)::Int = count(r.satisfied)

"""True iff the candidate satisfies every constraint (a full solution)."""
all_satisfied(r::ConstraintSatResult)::Bool = !isempty(r.satisfied) && all(r.satisfied)

"""Indices (1-based, spec order) of constraints satisfied for all inputs."""
satisfied_indices(r::ConstraintSatResult)::Vector{Int} = findall(r.satisfied)

"""Indices (1-based, spec order) of constraints violated by some input."""
violated_indices(r::ConstraintSatResult)::Vector{Int} = findall(.!r.satisfied)

# Deterministic echo marker / assumption-literal name for constraint i.
_csat_label(i::Int)::String = "csat_$i"
_csat_assume(i::Int)::String = "csat_assume_$i"

"""
Build the Method 2 SMT-LIB2 query for a candidate.

Inlines each candidate as a `define-fun`, declares one assumption literal per
constraint, and emits `(echo …)` + `(check-sat-assuming …)` pairs so each
constraint can be checked in isolation within a single z3 process.

Args:
  spec: parsed SyGuS specification
  candidate_exprs: Dict mapping synth-fun name → SMT-LIB2 body expression

Returns the complete SMT-LIB2 query string.
"""
function generate_satisfaction_query(spec::Spec, candidate_exprs::Dict{String,String})::String
    if !isa(spec, Spec)
        error("spec is not a Spec object: $(typeof(spec))")
    end

    parts = String[]

    push!(parts, "(set-logic $(spec.logic))")

    # Preamble: sorts, datatypes, helper / uninterpreted functions in source order.
    if !isempty(spec.ordered_preamble)
        push!(parts, "")
        push!(parts, "; ── preamble (sorts, helpers, uninterpreted functions) ──")
        append!(parts, spec.ordered_preamble)
    end

    # Free variables (inputs) become existential constants for the violation search.
    if !isempty(spec.free_vars)
        push!(parts, "")
        for fv in spec.free_vars
            push!(parts, "(declare-const $(fv.name) $(fv.sort))")
        end
    end

    # Inline each candidate synthesis function as a define-fun.
    if !isempty(spec.synth_funs)
        push!(parts, "")
    end
    for sfun in spec.synth_funs
        candidate = get(candidate_exprs, sfun.name, nothing)
        candidate === nothing && continue

        param_names = [pname for (pname, _) in sfun.params]
        free_var_names = [fv.name for fv in spec.free_vars]
        candidate_subst = substitute_params(candidate, param_names, free_var_names)

        # If the target sort is Int but the candidate body is a Bool, coerce it.
        if sfun.sort == "Int" && _looks_like_bool(candidate_subst)
            candidate_subst = _wrap_bool_to_int(candidate_subst)
        end

        param_decls = join(["($(pname) $(sort))" for (pname, sort) in sfun.params], " ")
        push!(parts, "(define-fun $(sfun.name) ($param_decls) $(sfun.sort) $candidate_subst)")
    end

    # One assumption literal per constraint: assuming pᵢ forces a search for an
    # input that violates Cᵢ. Leaving the others unassumed keeps them vacuous.
    push!(parts, "")
    push!(parts, "; assumption literals: (check-sat-assuming (csat_assume_i)) tests constraint i")
    for (i, constraint) in enumerate(spec.constraints)
        push!(parts, "(declare-const $(_csat_assume(i)) Bool)")
        push!(parts, "(assert (=> $(_csat_assume(i)) (not $constraint)))")
    end

    # One isolated, sound check per constraint, sharing the solver session.
    push!(parts, "")
    for i in eachindex(spec.constraints)
        push!(parts, "(echo \"$(_csat_label(i))\")")
        push!(parts, "(check-sat-assuming ($(_csat_assume(i))))")
    end

    join(parts, "\n") * "\n"
end

"""
Parse the interleaved `echo`/`check-sat` output into a per-constraint verdict.

Output looks like (echo strings may or may not be quoted depending on z3 version):

    csat_1
    unsat
    csat_2
    sat
    ...

Returns a `Vector{Symbol}` of length `n` (`:unsat`, `:sat`, or `:unknown`).
"""
function _parse_satisfaction_output(out::String, n::Int)::Vector{Symbol}
    status = fill(:unknown, n)
    current = 0
    for raw in split(out, '\n')
        line = strip(strip(raw), ['"'])
        isempty(line) && continue

        m = match(r"^csat_(\d+)$", line)
        if m !== nothing
            current = parse(Int, m.captures[1])
            continue
        end

        if 1 <= current <= n
            if line == "sat"
                status[current] = :sat;     current = 0
            elseif line == "unsat"
                status[current] = :unsat;   current = 0
            elseif line == "unknown"
                status[current] = :unknown; current = 0
            end
        end
    end
    status
end

"""
Check, for each spec constraint, whether the candidate satisfies it for all inputs.

Runs Method 2: a single z3 process performing one `check-sat-assuming` per
constraint over a shared solver session.

Args:
  spec: parsed SyGuS specification
  candidate_exprs: Dict mapping synth-fun name → SMT-LIB2 body expression

Returns a `ConstraintSatResult`.
"""
function check_constraint_satisfaction(
    spec::Spec,
    candidate_exprs::Dict{String,String},
)::ConstraintSatResult
    n = length(spec.constraints)
    n == 0 && return ConstraintSatResult(String[], Bool[], Symbol[])

    query = generate_satisfaction_query(spec, candidate_exprs)
    out, exitcode, err_msg = _z3_exec(query)

    status = _parse_satisfaction_output(out, n)
    if any(==(:unknown), status)
        @debug "Z3: some constraints undetermined" exitcode err_msg out
    end

    satisfied = [s === :unsat for s in status]
    return ConstraintSatResult(copy(spec.constraints), satisfied, status)
end

"""
Convenience overload for a single synthesis function.

`check_constraint_satisfaction(spec, "max2", "(ite (< x0 x1) x1 x0)")`
"""
function check_constraint_satisfaction(
    spec::Spec,
    sfun_name::AbstractString,
    candidate_expr::AbstractString,
)::ConstraintSatResult
    check_constraint_satisfaction(spec, Dict{String,String}(String(sfun_name) => String(candidate_expr)))
end
