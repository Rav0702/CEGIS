#!/usr/bin/env julia
"""
Quick test of z3_smt_cegis.jl to verify basic structure and loading
"""

println("Testing Z3 CEGIS Script Structure...")
println()

# Check if the script file exists and is readable
script_path = joinpath(@__DIR__, "z3_smt_cegis.jl")
@assert isfile(script_path) "Script file not found: $script_path"
println("✓ Script file found: $script_path")

# Check if we can find a spec file
spec_file = joinpath(@__DIR__, "..", "spec_files", "findidx_problem.sl")
if isfile(spec_file)
    println("✓ Spec file available: $spec_file")
else
    println("⚠ Default spec file not found (but script will handle this)")
end

# Try to parse the script to check syntax
script_code = read(script_path, String)
try
    Meta.parse(script_code)
    println("✓ Script syntax is valid")
catch e
    println("✗ Script syntax error: $e")
    exit(1)
end

println()
println("✓ All structural checks passed!")
println()
println("To run the full synthesis:")
if isfile(spec_file)
    println("  julia scripts/z3_smt_cegis.jl")
    println("  or with custom parameters:")
    println("  julia scripts/z3_smt_cegis.jl ../spec_files/findidx_problem.sl 8 5000000")
else
    println("  julia scripts/z3_smt_cegis.jl <spec_file.sl> [max_depth] [max_enumerations]")
end
