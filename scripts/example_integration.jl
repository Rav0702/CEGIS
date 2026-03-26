#!/usr/bin/env julia
"""
Example 3: Programmatic API Integration

Demonstrates:
  - Using CEXGeneration as a library within Julia code
  - Verifying candidates programmatically
  - Integration pattern for CEGIS loop
"""

using CEXGeneration

"""
Verify a candidate solution against a specification.
Returns (satisfiable::Bool, model::String) after running Z3.
"""
function verify_candidate(spec_file::String, synth_name::String, candidate::String)
    # 1. Parse specification
    spec = parse_spec_from_file(spec_file)
    
    # 2. Generate query
    candidates_dict = Dict(synth_name => candidate)
    query = generate_cex_query(spec, candidates_dict)
    
    # 3. Write query to temporary file
    temp_query = "/tmp/verify_query.smt2"
    open(temp_query, "w") do f
        write(f, query)
    end
    
    # 4. Run Z3 (requires z3 in PATH)
    try
        result = read(`z3 $temp_query`, String)
        is_sat = contains(result, "sat")
        return is_sat, result
    catch e
        @warn "Z3 execution failed: $e"
        return false, ""
    end
end

# Example usage
if length(ARGS) >= 2
    spec_file = ARGS[1]
    synth_name = ARGS[2]
    candidate = ARGS[3]
    
    println("Verifying candidate: $candidate")
    sat, model = verify_candidate(spec_file, synth_name, candidate)
    
    println(sat ? "✓ Satisfiable (candidate is valid)" : "✗ Unsatisfiable (counterexample found)")
    if !isempty(model)
        println("\nModel/Output:")
        println(model)
    end
else
    println("Usage Examples:")
    println()
    println("Example 1 - Check if candidate is valid:")
    println("  julia example_integration.jl spec.sl max_func \"if x > y then x else y\"")
    println()
    println("Example 2 - Direct API in Julia code:")
    println("  spec = CEXGeneration.parse_spec_from_file(\"spec.sl\")")
    println("  query = CEXGeneration.generate_cex_query(spec, Dict(\"f\" => \"x + 1\"))")
    println()
end
