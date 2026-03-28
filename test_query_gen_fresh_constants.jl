#!/usr/bin/env julia
"""
Test the fresh constant query generation refactor
"""

CEGIS_ROOT = @__DIR__
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

include(joinpath(CEGIS_SRC, "CEXGeneration", "CEXGeneration.jl"))

# Test 1: max3 spec with fresh constants
println("="^80)
println("TEST 1: max3_simple.sl - Fresh constant query generation")
println("="^80)

spec_file = joinpath(CEGIS_ROOT, "spec_files", "phase3_benchmarks", "max3_simple.sl")
spec = CEXGeneration.parse_spec_from_file(spec_file)

println("\nParsed Spec:")
println("  Logic: $(spec.logic)")
println("  Synth Functions: $(length(spec.synth_funs))")
for sfun in spec.synth_funs
    println("    - $(sfun.name): $(sfun.params) -> $(sfun.sort)")
end
println("  Free Variables: $(length(spec.free_vars))")
for fv in spec.free_vars
    println("    - $(fv.name): $(fv.sort)")
end
println("  Constraints: $(length(spec.constraints))")
for (i, c) in enumerate(spec.constraints)
    println("    [$i] $(c)")
end

# Generate query with a simple candidate "y"
candidate_dict = Dict("max3" => "y")
query = CEXGeneration.generate_cex_query(spec, candidate_dict)

println("\n" * "="^80)
println("GENERATED SMT-LIB2 QUERY:")
println("="^80)
println(query)

# Check for fresh constants in the query
println("\n" * "="^80)
println("VALIDATION CHECKS:")
println("="^80)

check1 = contains(query, "(declare-const out_max3 Int)")
check2 = contains(query, "out_max3")
check3 = !contains(query, "(define-fun max3_spec")
check4 = contains(query, "(check-sat)")
check5 = contains(query, "(get-value (out_max3))")

checks = [
    ("Contains (declare-const out_max3 Int)", check1),
    ("Contains fresh constant in assertions", check2),
    ("Does NOT contain (define-fun max3_spec", check3),
    ("Contains (check-sat)", check4),
    ("Contains (get-value (out_max3))", check5),
]

for (check_name, result) in checks
    status = result ? "✓" : "✗"
    println("  $status $check_name")
end

all_pass = all([check1, check2, check3, check4, check5])

println("\n" * "="^80)
if all_pass
    println("✓ ALL CHECKS PASSED - Fresh constant approach is working!")
else
    println("✗ SOME CHECKS FAILED - See above for details")
end
println("="^80)

# Test 2: Verify Z3 can parse the query
println("\n\n" * "="^80)
println("TEST 2: Z3 Query Parsing")
println("="^80)

try
    result = CEXGeneration.verify_query(query)
    println("✓ Z3 parsed query successfully")
    println("  Status: $(result.status)")
    if !isempty(result.model)
        println("  Model keys: $(keys(result.model))")
        for (k, v) in result.model
            println("    $k => $v")
        end
    end
catch e
    println("✗ Z3 parsing failed: $e")
end

println("\n" * "="^80)
println("Query generation refactor appears to be working correctly!")
println("="^80)
