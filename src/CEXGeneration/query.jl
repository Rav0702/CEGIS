"""
Generate SMT-LIB2 counterexample queries from specifications and candidate expressions.

Handles:
  - Substituting free variables with function parameters
  - Building check-sat queries for candidate verification
  - Generating queries with optional safety constraints (for invariant refinement)
"""

"""
Extract condition and expected output from an implication constraint.

Takes a constraint like: (=> (and (< x0 x1) (< k x0)) (= (findIdx x0 x1 k) 0))
Returns: (condition_expr, expected_output)
  Where condition_expr = "(and (< x0 x1) (< k x0))"
  And expected_output = "0"
"""
function parse_implication_constraint(constraint::String)::Union{Tuple{String, String}, Nothing}
    # Remove outer whitespace
    constraint = strip(constraint)
    
    # Must start with (=>
    !startswith(constraint, "(=>") && return nothing
    
    # Extract the parts: (=> condition consequent)
    # We need to carefully parse S-expressions
    
    # Find the position after "=>" where condition starts
    i = 4  # Skip "(=> "
    while i < length(constraint) && isspace(constraint[i])
        i += 1
    end
    cond_start = i
    
    # Find end of condition (when depth returns to 0)
    depth = 0
    cond_end = -1
    while i <= length(constraint)
        if constraint[i] == '('
            depth += 1
        elseif constraint[i] == ')'
            depth -= 1
            if depth == 0
                cond_end = i
                break
            end
        end
        i += 1
    end
    
    cond_end == -1 && return nothing
    condition = strip(constraint[cond_start:cond_end])
    
    # Extract consequent: (= (findIdx ...) expected_value)
    i = cond_end + 1
    while i < length(constraint) && isspace(constraint[i])
        i += 1
    end
    
    # The consequent starts here and should be (= ...)
    # Extract it until we find the matching close paren
    conseq_start = i
    depth = 0
    conseq_end = -1
    while i <= length(constraint)
        if constraint[i] == '('
            depth += 1
        elseif constraint[i] == ')'
            depth -= 1
            if depth == 0
                conseq_end = i
                break
            end
        end
        i += 1
    end
    
    conseq_end == -1 && return nothing
    
    # Now extract just the value from (= (findIdx x0 x1 k) VALUE)
    # Get everything between the last two closing parens
    consequent_str = strip(constraint[conseq_start:conseq_end])
    # consequent_str is like: (= (findIdx x0 x1 k) 0) or (= (fnd_sum x1 x2 x3) (+ x1 x2))
    
    # Find the value by parsing: after the function call, extract everything until the final paren
    # Remove the outer (= ... ) wrapper
    inner = strip(consequent_str[2:end-1])  # Remove (= ... )
    
    # Now inner is like: (fnd_sum x0 x1 k) 0  or  (fnd_sum x1 x2 x3) (+ x1 x2)
    # We need to extract the second part (everything after the closing paren of the first s-expr)
    
    # Find where the function call ends (when depth returns to 0)
    depth = 0
    func_end = -1
    for j in 1:length(inner)
        if inner[j] == '('
            depth += 1
        elseif inner[j] == ')'
            depth -= 1
            if depth == 0
                func_end = j
                break
            end
        end
    end
    
    func_end == -1 && return nothing
    
    # Everything after func_end is the expected value, strip whitespace
    expected_value = strip(inner[func_end+1:end])
    
    return (condition, expected_value)
end

"""
Build a spec output function from constraints.

Takes constraints like:
  (=> (and (< x0 x1) (< k x0)) (= (findIdx x0 x1 k) 0))
  (=> (and (< x0 x1) (>= k x0) (< k x1)) (= (findIdx x0 x1 k) 1))
  (=> (and (< x0 x1) (>= k x1)) (= (findIdx x0 x1 k) 2))

Returns a nested ite expression that computes the expected output:
  (ite cond1 out1 (ite cond2 out2 (ite cond3 out3 default)))
"""
function build_spec_function_body(constraints::Vector{String}, default_value::String="0")::String
    if isempty(constraints)
        return default_value
    end
    
    # Parse all constraints
    parsed = []
    for constraint in constraints
        result = parse_implication_constraint(constraint)
        if result !== nothing
            push!(parsed, result)
        end
    end
    
    if isempty(parsed)
        return default_value
    end
    
    # Build nested ite from the end backwards
    result = default_value
    for (i, (cond, expected_val)) in enumerate(reverse(parsed))
        # result = (ite cond expected_val previous_result)
        result = "(ite $cond $expected_val $result)"
    end
    
    result
end

"""
Generate a counterexample query verifying a candidate against a specification.

Returns SMT-LIB2 code that queries Z3 to find either:
  - A counterexample (unsatisfiable: candidate doesn't satisfy spec)
  - A valid model (satisfiable: candidate satisfies the constraint subset)

Now includes a spec_output function to determine what the correct output should be.
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
    
    # Define spec output function(s) - what the spec says the output should be
    # This is built from the constraints
    for sfun in spec.synth_funs
        param_decls = join(["($(pname) $(sort))" for (pname, sort) in sfun.params], " ")
        spec_body = build_spec_function_body(spec.constraints)
        defn = "(define-fun $(sfun.name)_spec ($param_decls) $(sfun.sort) $spec_body)"
        push!(query_parts, defn)
    end
    
    if !isempty(spec.synth_funs)
        push!(query_parts, "")
    end
    
    # Add constraints - NEGATED to find counterexamples
    # unsat means candidate satisfies all constraints
    # sat means the model is a concrete counterexample
    if !isempty(spec.constraints)
        constraint_list = join(spec.constraints, "\n  ")
        push!(query_parts, "(assert (not")
        push!(query_parts, "  (and")
        push!(query_parts, "    $constraint_list")
        push!(query_parts, "  )")
        push!(query_parts, "))")
    else
        push!(query_parts, "(assert false)   ; no constraints")
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
        push!(query_parts, "; candidate function value(s) at the counterexample point")
        for sfun in spec.synth_funs
            # Build function call with free variables as arguments
            args = join([fv.name for fv in spec.free_vars], " ")
            push!(query_parts, "(get-value (($(sfun.name) $args)))")
        end
        
        push!(query_parts, "")
        push!(query_parts, "; expected output from spec")
        for sfun in spec.synth_funs
            # Build spec function call with free variables as arguments
            args = join([fv.name for fv in spec.free_vars], " ")
            push!(query_parts, "(get-value (($(sfun.name)_spec $args)))")
        end
    end
    
    join(query_parts, "\n") * "\n"
end
