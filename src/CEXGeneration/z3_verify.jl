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
    ctx = Z3.Context()
    solver = Z3.Solver(ctx)
    
    # Use Z3's native SMT-LIB2 parser - this handles all parsing automatically
    # Parse the query string into ASTs
    result_str = try
        unsafe_string(Z3.Libz3.Z3_eval_smtlib2_string(ctx.ctx, query))
    catch e
        error("Z3 parse error: $e")
    end
    
    # Execute all assertions in the query by parsing through solver context
    # The query should contain (check-sat) and (get-value ...) commands
    # We need to manually parse the response
    
    status = :unknown
    model = Dict{String, Any}()
    
    # Parse Z3 response
    lines = split(result_str, '\n')
    
    # First pass: collect all non-sat/unsat/unknown lines to reconstruct model
    model_lines = String[]
    for line in lines
        line = strip(line)
        
        if line == "sat"
            status = :sat
        elseif line == "unsat"
            status = :unsat
        elseif line == "unknown"
            status = :unknown
        elseif !isempty(line)
            # Collect all other lines as potential model data
            push!(model_lines, line)
        end
    end
    
    # Reconstruct model from lines (handle multi-line output)
    if status == :sat && !isempty(model_lines)
        model_str = join(model_lines, " ")
        _parse_model_line(model_str, model)
    end
    
    Z3Result(status, model)
end

"""
Parse a model line from Z3 output.
Handles formats like: ((x1 10) (x2 5) (x3 0)) or ((x1 10) (x2 5) ((fnd_sum x1 x2 x3) 15))
"""
function _parse_model_line(line::String, model::Dict)::Nothing
    # Simple variable pattern: (name value)
    var_pattern = r"\((\w+)\s+(-?\d+)\)"
    for match in eachmatch(var_pattern, line)
        name = match.captures[1]
        val = parse(Int, match.captures[2])
        model[name] = val
    end
    
    # Function call pattern: ((func arg1 arg2) value) 
    func_pattern = r"\(\((\w+)\s+[^)]*\)\s+(-?\d+)\)"
    for match in eachmatch(func_pattern, line)
        func = match.captures[1]
        val = parse(Int, match.captures[2])
        model["$(func)_result"] = val
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
