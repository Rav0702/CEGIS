#!/usr/bin/env julia

# Test if the module loads correctly
const _CEGIS_DIR = joinpath(@__DIR__, "..")
const _CEX_GEN_MODULE = joinpath(_CEGIS_DIR, "src", "CEXGeneration", "CEXGeneration.jl")

println("Loading CEXGeneration from: $_CEX_GEN_MODULE")

try
    include(_CEX_GEN_MODULE)
    using .CEXGeneration
    
    println("✓ Module loaded successfully")
    println("Exported functions: $(names(CEXGeneration))")
    
    # Test if private functions exist
    println("\nChecking private functions:")
    println("_parse_declare_const defined: ", isdefined(CEXGeneration, Symbol("_parse_declare_const")))
    
    # Try to call it
    result = CEXGeneration._parse_declare_const("(declare-const x1 Int)")
    println("✓ _parse_declare_const works: $result")
    
catch e
    println("✗ Error loading module: $e")
    import Stacktrace
    showerror(stdout, e, stacktrace())
end
