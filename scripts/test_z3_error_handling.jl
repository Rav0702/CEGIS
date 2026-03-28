"""
Test script to verify Z3 error handling for type mismatches.

This uses the main CEGIS module environment to test error handling.
"""

import Pkg
Pkg.activate("../")

# Use Revise if available to pick up recent changes
try
    using Revise
    println("[INFO] Using Revise for live reloading")
catch
    println("[INFO] Revise not available - will use standard recompilation")
end

# Import CEGIS which includes CEXGeneration
include("../src/CEGIS.jl")

# Test 1: Query with type mismatch error
println("\n=== TEST 1: Query with Z3 type mismatch error ===")
malformed_query = """
(set-logic LIA)
(declare-const x Int)
(declare-const y Int)
(define-fun bad_func ((x Int) (y Int)) Int (< x y))
(declare-const out Int)
(assert (= out out))
(check-sat)
"""

println("Query (first 10 lines):")
for line in split(malformed_query, "\n")[1:5]
    println("  $line")
end
println("  ...")
println("\nProcessing...")

# This should detect the error and return :unknown status
result = CEGIS.CEXGeneration.verify_query(malformed_query)
println("Status: $(result.status)")
println("Model: $(result.model)")

if result.status == :unknown
    println("✓ PASS: Error was detected and handled correctly (status :unknown)")
else
    println("✗ FAIL: Expected :unknown status but got $(result.status)")
end

# Test 2: Valid query
println("\n=== TEST 2: Valid query (should work) ===")
valid_query = """
(set-logic LIA)
(declare-const x Int)
(declare-const y Int)
(assert (and (> x 5) (> y 3)))
(check-sat)
(get-value (x y))
"""

println("Query:")
println(valid_query)
println("\nProcessing...")

result = CEGIS.CEXGeneration.verify_query(valid_query)
println("Status: $(result.status)")
println("Model: $(result.model)")

if result.status == :sat
    println("✓ PASS: Valid query returned :sat status")
else
    println("✗ FAIL: Expected :sat status but got $(result.status)")
end

println("\n=== Tests Complete ===")
