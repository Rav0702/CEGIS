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
    # Note: Z3 may output errors to stderr/stdout directly, which is expected
    result_str = ""
    error_occurred = false
    
    try
        result_str = unsafe_string(Z3.Libz3.Z3_eval_smtlib2_string(ctx.ctx, query))
    catch e
        # If Z3 throws an exception (e.g., parse error), treat as malformed query
        # This can happen with type mismatches or syntax errors
        # Return unknown to signal the candidate has a fundamental problem
        error_occurred = true
        result_str = ""
    end
    
    if error_occurred || isempty(result_str)
        # If Z3 threw an exception or returned empty, return unknown
        return Z3Result(:unknown, Dict{String, Any}())
    end
    
    # Check for Z3 error patterns - this needs to handle both line-based and inline errors
    if contains(result_str, "(error")
        # Z3 reported an error - this means the candidate has a fundamental problem
        # Return immediately with unknown status
        return Z3Result(:unknown, Dict{String, Any}())
    end
    
    # Parse Z3 response
    status = :unknown
    model = Dict{String, Any}()
    
    # Split response into lines and parse
    lines = split(result_str, '\n')
    
    # First pass: identify satisfiability status
    for line in lines
        line = strip(line)
        if line == "sat"
            status = :sat
        elseif line == "unsat"
            status = :unsat
        elseif line == "unknown"
            status = :unknown
        end
    end
    
    # If status is unsat, return immediately with empty model
    # (errors that follow are expected - get-value commands fail on unsat)
    if status == :unsat
        return Z3Result(:unsat, Dict{String, Any}())
    end
    
    # For sat status, try to extract model from non-error lines
    if status == :sat
        model_lines = String[]
        for line in lines
            line = strip(line)
            if !isempty(line) && !startswith(line, "(error") && line ∉ ("sat", "unsat", "unknown")
                push!(model_lines, line)
            end
        end
        
        # Parse model if we have data
        if !isempty(model_lines)
            model_str = join(model_lines, " ")
            _parse_model_line(model_str, model)
        end
    end
    
    Z3Result(status, model)
end

"""
Parse a model line from Z3 output.
Handles formats like: 
- ((x0 5) (x1 -3) (x2 0))  — plain integers
- ((x0 (- 5)) (x1 (- 3)))  — S-expression negatives
- (((fnd_sum x0 x1) 15))   — function call results
- (((fnd_sum_spec x0 x1) 0)) — spec function results
"""
function _parse_model_line(line::String, model::Dict)::Nothing
    # Parse S-expression negative numbers: (- 5) → -5
    sexp_neg_pattern = r"\((\w+)\s+\(\s*-\s+(\d+)\)\)"
    for match in eachmatch(sexp_neg_pattern, line)
        name = match.captures[1]
        val = -parse(Int, match.captures[2])
        model[name] = val
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
        val = -parse(Int, match.captures[2])
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
