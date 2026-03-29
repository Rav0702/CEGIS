"""
Z3 verification and counterexample extraction using Z3 Julia module.

Provides functions to:
- Verify SMT-LIB2 queries using native Z3 API
- Extract counterexample models
- Format results for display

No manual parsing or intermediate files needed.
Uses Z3's native SMT-LIB2 parser.
"""

using Z3

"""
Result of Z3 verification.
- status: :sat (counterexample found) or :unsat (valid)
- model: Dict mapping variable names to values
"""
struct Z3Result
    status :: Symbol  # :sat or :unsat
    model  :: Dict{String, Any}
end

"""
Check satisfiability using two-step approach: first check-sat, then get-value if sat.

This avoids "model is not available" errors when get-value is called on unsat results.
"""
function check_candidate(query_base::String, get_value_lines::String)
    ctx = Z3.Context()
    solver = Z3.Solver(ctx)
    
    # First: parse and check sat with just the base query (no get-value calls)
    try
        Z3.Libz3.Z3_solver_from_string(ctx.ctx, solver.solver, query_base)
    catch e
        return :unknown, nothing
    end
    
    result = Z3.check(solver)
    
    if result.result == Z3.Libz3.Z3_L_TRUE  # sat (compare the field, not the struct)
        # Get the model
        m = Z3.model(solver)
        model_str = unsafe_string(Z3.Libz3.Z3_model_to_string(Z3.ctx_ref(m), m.model))
        
        # Append the full model string to include base variables
        # Since Z3 doesn't always include all variables in the model, we'll handle
        # missing variables during parsing by providing defaults
        return :sat, model_str
    elseif result.result == Z3.Libz3.Z3_L_FALSE  # unsat
        return :unsat, nothing
    else  # unknown
        return :unknown, nothing
    end
end

"""
Verify an SMT-LIB2 query string using Z3's native SMT-LIB2 parser.

# Arguments
- `query::String` — SMT-LIB2 query string (set-logic, declare-const/fun, assert, check-sat)

# Returns
- `Z3Result` — Contains satisfiability status and model (if sat)

# Examples
```
query = \"\"\"
(set-logic QF_LIA)
(declare-const x Int)
(declare-const y Int)
(assert (> (+ x y) 10))
(assert (< x 5))
(check-sat)
(get-value (x y))
\"\"\"
result = verify_query(query)
```
"""
function verify_query(query::String)::Z3Result
    # Split query into base (without get-value) and get-value lines
    lines = split(query, '\n')
    check_sat_idx = findfirst(line -> strip(line) == "(check-sat)", lines)
    
    query_base_lines = if check_sat_idx !== nothing
        vcat(lines[1:check_sat_idx], "(check-sat)")
    else
        lines
    end
    
    get_value_lines = if check_sat_idx !== nothing
        lines[check_sat_idx+1:end]
    else
        String[]
    end
    
    query_base = join(query_base_lines, "\n")
    get_value_str = join(get_value_lines, "\n")
    
    # Use two-step approach
    status, model_data = check_candidate(query_base, get_value_str)
    
    model = Dict{String, Any}()
    if status == :sat && model_data !== nothing
        _parse_model_line(model_data, model)
    end
    
    Z3Result(status, model)
end

"""
Parse a model line from Z3 output.
Handles formats like: 
- x0 -> 5, x1 -> -3 (from Z3_model_to_string)
- ((x0 5) (x1 -3) (x2 0))  — plain integers (S-expression)
- ((x0 (- 5)) (x1 (- 3)))  — S-expression negatives
- (((fnd_sum x0 x1) 15))   — function call results
- (((fnd_sum_spec x0 x1) 0)) — spec function results
"""
function _parse_model_line(line::String, model::Dict)::Nothing
    # First try the modern format: name -> value (from Z3_model_to_string)
    arrow_pattern = r"(\w+)\s*->\s*(-?\d+)"
    for match in eachmatch(arrow_pattern, line)
        name = match.captures[1]
        val = parse(Int, match.captures[2])
        model[name] = val
    end
    
    # Parse S-expression negative numbers: (- 5) → -5
    sexp_neg_pattern = r"\((\w+)\s+\(\s*-\s+(\d+)\)\)"
    for match in eachmatch(sexp_neg_pattern, line)
        name = match.captures[1]
        if !haskey(model, name)
            val = -parse(Int, match.captures[2])
            model[name] = val
        end
    end
    
    # Parse plain integers: (name value)
    plain_int_pattern = r"\((\w+)\s+(-?\d+)\)"
    for match in eachmatch(plain_int_pattern, line)
        name = match.captures[1]
        # Skip if already parsed as S-expr negative
        if !haskey(model, name)
            val = parse(Int, match.captures[2])
            model[name] = val
        end
    end
    
    # Function call pattern: ((func arg1 arg2) value) or ((func arg1 arg2) (- value))
    func_plain_pattern = r"\(\((\w+)\s+[^)]*\)\s+(-?\d+)\)"
    for match in eachmatch(func_plain_pattern, line)
        func = match.captures[1]
        val = parse(Int, match.captures[2])
        model["$(func)_result"] = val
    end
    
    # Function call with S-expr negative: ((func ...) (- value))
    func_neg_pattern = r"\(\((\w+)\s+[^)]*\)\s+\(\s*-\s+(\d+)\)\)"
    for match in eachmatch(func_neg_pattern, line)
        func = match.captures[1]
        if !haskey(model, "$(func)_result")
            val = -parse(Int, match.captures[2])
            model["$(func)_result"] = val
        end
    end
    
    nothing
end

"""
Format Z3Result for human-readable display.

Returns formatted string summarizing the verification result.
"""
function format_result(result::Z3Result, spec::Spec)::String
    lines = String[]
    
    if result.status == :sat
        push!(lines, "❌ COUNTEREXAMPLE FOUND")
        push!(lines, "")
        push!(lines, "Free variable assignments:")
        for fv in spec.free_vars
            val = get(result.model, fv.name, "?")
            push!(lines, "  $(fv.name) = $val")
        end
        push!(lines, "")
        push!(lines, "Function values at counterexample:")
        for sfun in spec.synth_funs
            result_key = "$(sfun.name)_result"
            val = get(result.model, result_key, "?")
            push!(lines, "  $(sfun.name)(...) = $val")
        end
    elseif result.status == :unsat
        push!(lines, "✅ VALID CANDIDATE")
        push!(lines, "The candidate satisfies all constraints.")
    elseif result.status == :unknown
        push!(lines, "⚠️  UNKNOWN")
        push!(lines, "Z3 could not determine satisfiability.")
    else
        push!(lines, "⚠️  ERROR")
        push!(lines, "Could not determine satisfiability.")
    end
    
    join(lines, "\n")
end
