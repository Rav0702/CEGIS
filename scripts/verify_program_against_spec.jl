#!/usr/bin/env julia
"""
    verify_program_against_spec.jl

Verifies that a given program satisfies the constraints defined in a specification file
by constructing Z3 queries.

Usage:
    julia verify_program_against_spec.jl spec_file program [program2]

Examples:
    julia verify_program_against_spec.jl ../spec_files/findidx_2_simple.sl "ifelse(k < x0, 0, ifelse(k < x1, 1, 2))"
    julia verify_program_against_spec.jl ../spec_files/findidx_2_simple.sl "ifelse(k < x0, 0, ifelse(k < x1, 1, 2))" "ifelse(k < x0, 0, 2)"
"""

CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

using HerbCore, HerbGrammar, HerbSearch, HerbSpecification, HerbInterpret, Symbolics
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

function verify_program(spec_file::String, program_str::String, program_name::String = "Program")
    """Verify a single program against a specification using Z3."""
    println("\n" * "="^70)
    println("Verifying: $program_name")
    println("Specification: $(basename(spec_file))")
    println("Program: $program_str")
    println("="^70)
    
    try
        # Parse the specification file using CEXGeneration
        spec = CEGIS.CEXGeneration.parse_spec_from_file(spec_file)
        println("\n[✓] Specification parsed")
        println("    Logic: $(spec.logic)")
        println("    Synth functions: $(length(spec.synth_funs))")
        for synth_fun in spec.synth_funs
            println("      - $(synth_fun.name): $(synth_fun.params) -> $(synth_fun.sort)")
        end
        
        # Get the synthesis function name (usually first one)
        if isempty(spec.synth_funs)
            error("No synthesis function found in specification")
        end
        
        synth_func_name = spec.synth_funs[1].name
        
        # Build candidates dictionary with the program
        candidates = Dict(synth_func_name => program_str)
        
        println("\n[*] Constructing Z3 query to verify: $synth_func_name = $program_str")
        
        # Generate the Z3 query
        query = CEGIS.CEXGeneration.generate_cex_query(spec, candidates)
        
        println("\n[✓] Query constructed ($(length(query)) bytes)")
        println(query[1:length(query)])
  
        
        # Verify the query with Z3
        println("\n[*] Sending query to Z3...")
        result = CEGIS.CEXGeneration.verify_query(query)
        
        println("\n[✓] Z3 response: $(result.status)")
        
        if result.status == :unsat
            println("\n✓ VERIFIED: Program satisfies all specification constraints!")
            return (name=program_name, valid=true, error=nothing, z3_result=result)
        elseif result.status == :sat
            println("\n✗ COUNTEREXAMPLE: Program does NOT satisfy the specification")
            if result.model !== nothing && !isempty(result.model)
                println("   Model variables:")
                for (var, val) in result.model
                    println("     $var = $val")
                end
            end
            return (name=program_name, valid=false, error="Specification violated", z3_result=result)
        else
            println("\n? UNKNOWN: Z3 returned unknown status: $(result.status)")
            return (name=program_name, valid=false, error="Z3 status: $(result.status)", z3_result=result)
        end
        
    catch e
        println("[✗] Error during verification: $e")
        return (name=program_name, valid=false, error="Error: $e", z3_result=nothing)
    end
end


function main()
    if length(ARGS) < 2
        println("""
        Usage: julia verify_program_against_spec.jl <spec_file> <program1> [program2] [...]
        
        Verifies that given programs satisfy Z3 constraints from a specification file.
        
        Examples:
            julia verify_program_against_spec.jl ../spec_files/findidx_2_simple.sl \\
                "ifelse(k < x0, 0, ifelse(k < x1, 1, 2))"
                
            julia verify_program_against_spec.jl ../spec_files/findidx_2_simple.sl \\
                "ifelse(k < x0, 0, ifelse(k < x1, 1, 2))" \\
                "ifelse(k < x0, 0, 2)"
        """)
        exit(1)
    end
    
    spec_file = ARGS[1]
    programs = ARGS[2:end]
    
    # Resolve spec file path
    if !isabspath(spec_file)
        spec_file = joinpath(dirname(@__DIR__), spec_file)
    end
    
    println("\n" * "="^70)
    println("PROGRAM VERIFICATION AGAINST SPECIFICATION")
    println("="^70)
    
    results = []
    
    for (i, program) in enumerate(programs)
        program_name = length(programs) > 1 ? "Program $i" : "Program"
        result = verify_program(spec_file, program, program_name)
        push!(results, result)
    end
    
    # Print summary
    println("\n" * "="^70)
    println("SUMMARY")
    println("="^70)
    
    for result in results
        status = result.valid ? "✓ VERIFIED" : "✗ REFUTED"
        println("  $status: $(result.name)")
        if result.error !== nothing
            println("           $(result.error)")
        end
    end
    
    verified_count = sum(r.valid for r in results)
    println("\nVerified programs: $verified_count / $(length(results))")
    
end

main()

