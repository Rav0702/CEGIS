"""
Generate SMT-LIB2 counterexample queries from specifications and candidate expressions.

Uses fresh constants to represent valid outputs from the spec, enabling generic
counterexample finding across all constraint types (implications, inequalities, I/O examples).

Handles:
  - Substituting free variables with function parameters
  - Building check-sat queries for candidate verification
  - Declaring fresh constants for spec constraint verification
"""

"""
Get the fresh constant name for a synthesis function.

A fresh constant represents "what output the spec says is valid at this input point".

Example: sfun.name = "max3" -> fresh_const_name = "out_max3"
"""
function get_fresh_const_name(sfun::SynthFun)::String
    "out_$(sfun.name)"
end

"""
Substitute all calls to a synthesis function with a fresh constant.

Replaces function calls like (max3 x y z) with the fresh constant name.

Args:
  constraint: String representation of a constraint (or any S-expression)
  sfun_name: Name of the synthesis function (e.g., "max3")
  fresh_const_name: Name of the fresh constant (e.g., "out_max3")

Returns:
  Modified constraint with all calls to sfun_name replaced by fresh_const_name

Example:
  constraint = "(>= (max3 x y z) x)"
  substitute_synth_calls(constraint, "max3", "out_max3")
  => "(>= out_max3 x)"
"""
function substitute_synth_calls(
    constraint::String,
    sfun_name::String,
    fresh_const_name::String,
)::String
    result = constraint
    
    # Replace (sfun_name ...) calls with fresh_const_name
    i = 1
    output = Char[]
    
    while i <= length(result)
        # Look for (sfun_name pattern
        if i < length(result) && result[i] == '(' && i + length(sfun_name) <= length(result)
            # Check if this is (sfun_name
            substring = result[i+1:min(i+length(sfun_name), length(result))]
            
            if substring == sfun_name
                # Check if it's followed by space or close paren (ensuring it's a complete function name)
                if i + length(sfun_name) + 1 <= length(result)
                    next_char = result[i + length(sfun_name) + 1]
                    if next_char == ' ' || next_char == ')'
                        # This is a function call - find the matching close paren
                        paren_depth = 1
                        j = i + 2
                        while j <= length(result) && paren_depth > 0
                            if result[j] == '('
                                paren_depth += 1
                            elseif result[j] == ')'
                                paren_depth -= 1
                            end
                            j += 1
                        end
                        
                        # j is now one past the closing paren of the function call
                        # Replace (sfun_name ...) with fresh_const_name
                        append!(output, collect(fresh_const_name))
                        i = j
                        continue
                    end
                end
            end
        end
        
        # No match, just append the character
        push!(output, result[i])
        i += 1
    end
    
    join(output)
end

"""
Substitute free variables with function parameters in an expression.

Replaces free variable names with their corresponding parameter names.

Args:
  expr: Expression string (e.g. candidate from synthesis)
  param_names: Names of function parameters (e.g., ["x", "y", "z"])
  free_var_names: Names of free variables (e.g., ["x1", "x2", "x3"])

Returns:
  Modified expression with free variables replaced by parameters
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
Detect if an SMT-LIB2 expression is likely a boolean (comparison or logical operator).

Note: `ite` (ifelse) is NOT included because it returns Int when both branches are Int.
Only operators that inherently return Bool are checked.
"""
function _looks_like_bool(expr::String)::Bool
    expr = strip(expr)
    # Check for boolean operators at the top level
    # Note: "ite" is excluded - it returns Int if branches are Int
    bool_ops = ["=", "<", ">", "<=", ">=", "and", "or", "not", "distinct"]
    if startswith(expr, "(")
        # Extract operator name
        i = 2
        while i <= length(expr) && expr[i] != ' ' && expr[i] != ')'
            i += 1
        end
        op = expr[2:i-1]
        return op ∈ bool_ops
    end
    false
end

"""
Wrap a boolean expression in (ite expr 1 0) to convert to Int.
"""
function _wrap_bool_to_int(expr::String)::String
    if _looks_like_bool(expr)
        return "(ite $expr 1 0)"
    end
    expr
end

"""
Generate a counterexample query verifying a candidate against a specification.

Uses fresh constants to represent valid outputs according to the spec constraints.
All constraints are applied to fresh constants, then the candidate is checked
against these spec constraints. This approach works for all constraint types
generically (implications, inequalities, I/O examples, mixed).

Returns SMT-LIB2 code that queries Z3 to find either:
  - sat: A counterexample (candidate violates at least one spec constraint)
  - unsat: Candidate satisfies all spec constraints at this input point

Args:
  spec: Parsed SyGuS specification
  candidate_exprs: Dict mapping function names to SMT-LIB2 expressions

Returns:
  Complete SMT-LIB2 query string with (check-sat) and (get-value) commands
"""
function generate_query(spec::Spec, candidate_exprs::Dict{String,String})::String
    if !isa(spec, Spec)
        error("spec is not a Spec object: $(typeof(spec))")
    end
    
    query_parts = String[]
    
    # Set logic
    push!(query_parts, "(set-logic $(spec.logic))")
    
    # Preamble: sorts, datatypes, helper functions (define-fun, define-funs-rec), uninterpreted functions
    # These must be included so that function definitions are available when constraints are evaluated
    if !isempty(spec.ordered_preamble)
        push!(query_parts, "")
        push!(query_parts, "; ── preamble (sorts, helpers, uninterpreted functions) ──")
        for preamble_item in spec.ordered_preamble
            push!(query_parts, preamble_item)
        end
    end
    
    # Declare free variables (inputs) using declare-const
    if !isempty(spec.free_vars)
        push!(query_parts, "")
    end
    for fv in spec.free_vars
        decl = "(declare-const $(fv.name) $(fv.sort))"
        push!(query_parts, decl)
    end
    
    if !isempty(spec.free_vars)
        push!(query_parts, "")
    end
    
    # Define candidate synthesis functions with their expressions
    for sfun in spec.synth_funs
        candidate = get(candidate_exprs, sfun.name, nothing)
        if candidate !== nothing
            param_names = [pname for (pname, _) in sfun.params]
            free_var_names = [fv.name for fv in spec.free_vars]
            candidate_subst = substitute_params(candidate, param_names, free_var_names)
            
            # CHECK: If target sort is Int but candidate looks like Bool, wrap it
            if sfun.sort == "Int" && _looks_like_bool(candidate_subst)
                candidate_subst = _wrap_bool_to_int(candidate_subst)
            end
            
            param_decls = join(["($(pname) $(sort))" for (pname, sort) in sfun.params], " ")
            defn = "(define-fun $(sfun.name) ($param_decls) $(sfun.sort) $candidate_subst)"
            push!(query_parts, defn)
        end
    end
    
    if !isempty(spec.synth_funs)
        push!(query_parts, "")
    end
    
    # Declare fresh constants for each synthesis function
    # These represent "what output the spec says is valid at this input point"
    for sfun in spec.synth_funs
        fresh_name = get_fresh_const_name(sfun)
        push!(query_parts, "(declare-const $fresh_name $(sfun.sort))")
    end
    
    if !isempty(spec.synth_funs)
        push!(query_parts, "")
    end
    
    # Assert spec constraints with fresh constants substituted
    # This tells Z3: "for any valid output satisfying the spec, these constraints must hold"
    for sfun in spec.synth_funs
        fresh_name = get_fresh_const_name(sfun)
        
        # Only process constraints that mention this function
        constraints_for_func = filter(c -> contains(c, "($(sfun.name)"), spec.constraints)
        
        if !isempty(constraints_for_func)
            push!(query_parts, "; Spec constraints for $(sfun.name) (valid outputs: $fresh_name)")
            for constraint in constraints_for_func
                # Replace function calls with fresh constant
                spec_constraint = substitute_synth_calls(constraint, sfun.name, fresh_name)
                push!(query_parts, "(assert $spec_constraint)")
            end
            push!(query_parts, "")
        end
    end
    
    # Now assert that the candidate violates at least one constraint
    # This is how we find counterexamples: unsat = candidate is correct, sat = we found a counterexample
    if !isempty(spec.constraints)
        constraint_list = join(spec.constraints, "\n  ")
        push!(query_parts, "; Check if candidate violates any constraint")
        push!(query_parts, "(assert (not")
        push!(query_parts, "  (and")
        push!(query_parts, "    $constraint_list")
        push!(query_parts, "  )")
        push!(query_parts, "))")
    else
        push!(query_parts, "(assert false)   ; no constraints to verify")
    end
    
    push!(query_parts, "")
    push!(query_parts, "(check-sat)")
    
    # Extract values to see the counterexample
    if !isempty(spec.free_vars)
        push!(query_parts, "")
        push!(query_parts, "; Free variable values at counterexample")
        var_list = join([fv.name for fv in spec.free_vars], " ")
        push!(query_parts, "(get-value ($var_list))")
    end
    
    # Extract candidate and spec values for comparison
    if !isempty(spec.synth_funs)
        push!(query_parts, "")
        push!(query_parts, "; Candidate output(s)")
        for sfun in spec.synth_funs
            args = join([fv.name for fv in spec.free_vars], " ")
            push!(query_parts, "(get-value (($(sfun.name) $args)))")
        end
        
        push!(query_parts, "")
        push!(query_parts, "; Valid spec output(s) - what the spec says is correct")
        for sfun in spec.synth_funs
            fresh_name = get_fresh_const_name(sfun)
            push!(query_parts, "(get-value ($fresh_name))")
        end
    end
    
    join(query_parts, "\n") * "\n"
end
