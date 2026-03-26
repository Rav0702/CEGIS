#!/usr/bin/env julia
"""
Example 2: Caching with Serialization

Demonstrates:
  - Parsing and serializing a specification for caching
  - Loading a cached specification
  - Generating multiple queries from the same spec (efficient workflow)
"""

using CEXGeneration

if length(ARGS) < 1
    println("Usage: example_caching.jl <spec.sl> [candidate_expr1 candidate_expr2 ...]")
    println("Example: julia example_caching.jl spec.sl \"x+1\" \"x-1\" \"0\"")
    exit(1)
end

spec_file = ARGS[1]
cache_file = replace(spec_file, r"\.sl$" => ".parsed.jl")
candidates_list = ARGS[2:end]

# Step 1: Parse or load from cache
spec = if isfile(cache_file)
    println("Loading cached specification from $cache_file")
    deserialize_spec(cache_file)
else
    println("Parsing specification from $spec_file")
    spec = parse_spec_from_file(spec_file)
    println("Saving cache to $cache_file")
    serialize_spec(spec, cache_file)
    spec
end

println("Loaded specification:")
println("  Logic: $(spec.logic)")
println("  Synthesis targets: $(join([f.name for f in spec.synth_funs], ", "))")
println("  Constraints: $(length(spec.constraints))")

if isempty(spec.synth_funs)
    println("Error: No synthesis targets found")
    exit(1)
end

# Step 2: Generate queries for multiple candidates
synth_name = spec.synth_funs[1].name

if isempty(candidates_list)
    candidates_list = ["0", "1", "x", "x + 1", "if x = 0 then 1 else 0"]
end

for (idx, candidate_expr) in enumerate(candidates_list)
    println("\n--- Candidate $idx: $candidate_expr ---")
    try
        candidates = Dict(synth_name => candidate_expr)
        query = generate_cex_query(spec, candidates)
        
        output_file = "query_$(idx).smt2"
        open(output_file, "w") do f
            write(f, query)
        end
        
        println("✓ Generated: $output_file")
    catch e
        println("✗ Error: $e")
    end
end

println("\nTo verify all queries:")
println("  for f in query_*.smt2; do z3 \$f; done")
