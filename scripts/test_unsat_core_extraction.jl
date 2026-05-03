#!/usr/bin/env julia
"""
Test script to verify unsatisfiable core extraction from Z3.
"""

CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

include(joinpath(CEGIS_SRC, "CEGIS.jl"))

function test_unsat_core()
    println("="^70)
    println("Testing Unsatisfiable Core Extraction")
    println("="^70)
    
    # Use a simple spec file with implications
    spec_file = joinpath(CEGIS_ROOT, "spec_files", "findidx_2_simple.sl")
    
    if !isfile(spec_file)
        println("ERROR: Spec file not found: $spec_file")
        return
    end
    
    # Parse specification
    println("\n[*] Parsing specification: $spec_file")
    spec = CEGIS.CEXGeneration.parse_spec_from_file(spec_file)
    println("[✓] Specification parsed")
    println("    Logic: $(spec.logic)")
    println("    Synth functions: $(length(spec.synth_funs))")
    println("    Constraints: $(length(spec.constraints))")
    
    # Test with a VALID candidate (should produce UNSAT with core)
    println("\n" * "-"^70)
    println("Test 1: VALID candidate (should be UNSAT with core)")
    println("-"^70)
    
    synth_func_name = spec.synth_funs[1].name
    valid_program = "ifelse(k < x0, 0, ifelse(k < x1, 1, 2))"
    
    println("\nProgram: $valid_program")
    candidates = Dict(synth_func_name => valid_program)
    
    query = CEGIS.CEXGeneration.generate_cex_query(spec, candidates)
    println("\nGenerated query (first 500 chars):")
    println(query[1:min(500, length(query))])
    println("...")
    
    println("\nSending to Z3...")
    result = CEGIS.CEXGeneration.verify_query(query)
    
    println("\n✓ Result Status: $(result.status)")
    
    if result.status == :unsat
        println("\n✓ UNSAT - Candidate is valid!")
        if !isempty(result.unsat_core)
            println("\nUnsatisfiable Core (minimal set of constraints proving validity):")
            for (idx, label) in enumerate(result.unsat_core)
                println("  [$idx] $label")
            end
        else
            println("\nNo unsat core extracted (Z3 may not have provided it)")
        end
    else
        println("Status was: $(result.status)")
    end
    
    # Test with an INVALID candidate (should produce SAT)
    println("\n" * "-"^70)
    println("Test 2: INVALID candidate (should be SAT)")
    println("-"^70)
    
    invalid_program = "0"  # Always returns 0, violating constraints
    
    println("\nProgram: $invalid_program")
    candidates = Dict(synth_func_name => invalid_program)
    
    query = CEGIS.CEXGeneration.generate_cex_query(spec, candidates)
    
    println("Sending to Z3...")
    result = CEGIS.CEXGeneration.verify_query(query)
    
    println("\n✓ Result Status: $(result.status)")
    
    if result.status == :sat
        println("\n✓ SAT - Counterexample found!")
        if !isempty(result.model)
            println("\nModel:")
            for (var, val) in result.model
                println("  $var = $val")
            end
        end
    else
        println("Status was: $(result.status)")
    end
    
    # Test using format_result
    println("\n" * "-"^70)
    println("Test 3: Formatted output using format_result")
    println("-"^70)
    
    println("\nFormatted result for valid program:")
    candidates = Dict(synth_func_name => valid_program)
    query = CEGIS.CEXGeneration.generate_cex_query(spec, candidates)
    result = CEGIS.CEXGeneration.verify_query(query)
    formatted = CEGIS.CEXGeneration.format_result(result, spec)
    println(formatted)
    
    println("\n" * "="^70)
    println("All tests completed!")
    println("="^70)
end

test_unsat_core()
