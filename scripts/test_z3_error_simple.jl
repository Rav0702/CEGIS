#!/usr/bin/env julia
"""
Minimal test to verify Z3 error handling is working correctly.
"""

CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

println("[TEST] Loading CEGIS module...")
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

println("[TEST] Testing Z3 error handling...")

# Test query with type mismatch (Bool in Int function)
test_query = """
(set-logic LIA)
(declare-const x Int)
(declare-const y Int)
(define-fun bad_func ((x Int) (y Int)) Int (< x y))
(declare-const out Int)
(assert (= out out))
(check-sat)
(get-value (out))
"""

println("\n[TEST] Query with type error:")
println(test_query)

try
    result = CEGIS.CEXGeneration.verify_query(test_query)
    println("\n[TEST] Result status: $(result.status)")
    println("[TEST] Result model: $(result.model)")

    if result.status == :unknown
        println("\n✓ SUCCESS: Z3 error was detected correctly")
        println("           Status = :unknown (error case)")
        println("           This candidate will be skipped by oracle")
    else
        println("\n✗ FAILURE: Expected :unknown but got $(result.status)")
    end
catch e
    println("\n✗ EXCEPTION: $e")
    println("Stacktrace:")
    showerror(stdout, e)
    println()
end

