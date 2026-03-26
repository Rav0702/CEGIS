"""
Generate SMT-LIB2 counterexample queries from specifications and candidate expressions.

Handles:
  - Substituting free variables with function parameters
  - Building check-sat queries for candidate verification
  - Generating queries with optional safety constraints (for invariant refinement)
"""

"""
Substitute free variable names in a candidate expression with function parameter names.
Replaces xi with yi where yi is the ith parameter (0-indexed).

# Example
    substitute_params("(+ x1 x2)", ["y1", "y2"], ["x1", "x2"]) → "(+ y1 y2)"
"""
function substitute_params(
    expr::String, param_names::Vector{String},
    free_var_names::Vector{String},
)::String
    result = expr
    
    # Simple substitution: replace each free variable with its corresponding parameter
    for (i, var_name) in enumerate(free_var_names)
        param = param_names[i]
        # Use word boundaries to avoid partial matches
        # Replace var_name that appears as a complete identifier (surrounded by non-alphanumerics)
        result = replace(result, Regex("\\b" * var_name * "\\b") => param)
    end
    
    result
end

"""
Generate a counterexample query verifying a candidate against a specification.

Returns SMT-LIB2 code that queries Z3 to find either:
  - A counterexample (unsatisfiable: candidate doesn't satisfy spec)
  - A valid model (satisfiable: candidate satisfies the constraint subset)
"""
function generate_query(spec::Spec, candidate_exprs::Dict{String,String})::String
    if !isa(spec, Spec)
        error("spec is not a Spec object: $(typeof(spec))")
    end
    
    query_parts = String[]
    
    push!(query_parts, "(set-logic $(spec.logic))")
    
    # Declare free variables using declare-const (not declare-fun)
    for fv in spec.free_vars
        decl = "(declare-const $(fv.name) $(fv.sort))"
        push!(query_parts, decl)
    end
    
    if !isempty(spec.free_vars)
        push!(query_parts, "")
    end
    
    # Define synthesis functions with candidate expressions
    # NOTE: Do NOT declare them first - only define them
    for sfun in spec.synth_funs
        candidate = get(candidate_exprs, sfun.name, nothing)
        if candidate !== nothing
            param_names = [pname for (pname, _) in sfun.params]
            free_var_names = [fv.name for fv in spec.free_vars]
            candidate_subst = substitute_params(candidate, param_names, free_var_names)
            
            param_decls = join(["($(pname) $(sort))" for (pname, sort) in sfun.params], " ")
            defn = "(define-fun $(sfun.name) ($param_decls) $(sfun.sort) $candidate_subst)"
            push!(query_parts, defn)
        end
    end
    
    if !isempty(spec.synth_funs)
        push!(query_parts, "")
    end
    
    # Add constraints
    if !isempty(spec.constraints)
        constraint_list = join(spec.constraints, "\n  ")
        push!(query_parts, "(assert (and")
        push!(query_parts, "  $constraint_list")
        push!(query_parts, "))")
    else
        push!(query_parts, "(assert true)")
    end
    
    push!(query_parts, "")
    push!(query_parts, "(check-sat)")
    
    # Add value extraction commands
    if !isempty(spec.free_vars)
        push!(query_parts, "")
        push!(query_parts, "; free-variable assignments")
        var_list = join([fv.name for fv in spec.free_vars], " ")
        push!(query_parts, "(get-value ($var_list))")
    end
    
    if !isempty(spec.synth_funs)
        push!(query_parts, "")
        push!(query_parts, "; synthesised function value(s) at the counterexample point")
        for sfun in spec.synth_funs
            # Build function call with free variables as arguments
            args = join([fv.name for fv in spec.free_vars], " ")
            push!(query_parts, "(get-value (($(sfun.name) $args)))")
        end
    end
    
    join(query_parts, "\n") * "\n"
end
