#!/usr/bin/env julia
"""
Example 1: Basic Usage with CEXGeneration Module

Demonstrates:
  - Parsing a SyGuS specification
  - Generating a query with a candidate solution
  - Writing the query to a file
"""

using CEXGeneration

# Example usage
if length(ARGS) < 2
    println("Usage: example_basic.jl <spec.sl> <candidate_expr>")
    println("Example: julia example_basic.jl spec.sl \"x + 1\"")
    exit(1)
end

spec_file = ARGS[1]
candidate_expr = ARGS[2]

# 1. Parse the specification
spec = parse_spec_from_file(spec_file)

println("Parsed specification:")
println("  Logic: $(spec.logic)")
println("  Synthesis targets: $(join([f.name for f in spec.synth_funs], ", "))")
println("  Free variables: $(join([v.name for v in spec.free_vars], ", "))")
println("  Constraints: $(length(spec.constraints))")

# 2. Identify the main synthesis function to verify
if isempty(spec.synth_funs)
    println("Error: No synthesis targets found in specification")
    exit(1)
end

synth_name = spec.synth_funs[1].name
candidates = Dict(synth_name => candidate_expr)

# 3. Generate the query
query = generate_cex_query(spec, candidates)

# 4. Write to file with UTF-8 encoding
output_file = replace(spec_file, r"\.sl$" => "_query.smt2")
open(output_file, "w") do f
    write(f, query)
end

println("\nGenerated query written to: $output_file")
println("\nTo check satisfiability:")
println("  z3 $output_file")
