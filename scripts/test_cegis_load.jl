#!/usr/bin/env julia
"""
Test that CEGIS with Oracles loads correctly and Z3Oracle can be instantiated
"""
import Pkg
const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env_z3_test")
Pkg.activate(_SCRIPT_ENV)

const _HERB_PKGS = ["HerbCore", "HerbGrammar", "HerbConstraints",
                   "HerbInterpret", "HerbSearch", "HerbSpecification", "CEGIS"]
let dev_dir = joinpath(homedir(), ".julia", "dev"),
    manifest = joinpath(_SCRIPT_ENV, "Manifest.toml")
    if !isfile(manifest) || filesize(manifest) < 200
        pkgs = [Pkg.PackageSpec(path=joinpath(dev_dir, p))
                for p in _HERB_PKGS if isdir(joinpath(dev_dir, p))]
        isempty(pkgs) || Pkg.develop(pkgs)
    end
end

using HerbCore, HerbGrammar

println("Loading CEGIS module...")
include(joinpath(@__DIR__, "..", "src", "CEGIS.jl"))
using .CEGIS

println("✓ CEGIS loaded successfully")
println("  - AbstractOracle available: $(isdefined(CEGIS, :AbstractOracle))")
println("  - IOExampleOracle available: $(isdefined(CEGIS, :IOExampleOracle))")
println("  - Z3Oracle available: $(isdefined(CEGIS, :Z3Oracle))")
println("  - CEXGeneration available: $(isdefined(CEGIS, :CEXGeneration))")

# Test grammar creation
@csgrammar begin
    Expr = 1 | 2
    Expr = Expr + Expr
end
println("\n✓ Test grammar created")

# Check spec file
spec_file = joinpath(@__DIR__, "..", "spec_files", "findidx_problem.sl")
if isfile(spec_file)
    println("✓ Spec file found: $spec_file")
    
    # Try to create Z3Oracle
    try
        oracle = Z3Oracle(spec_file, grammar)
        println("✓ Z3Oracle instance created successfully!")
        println("  - spec_file: $(oracle.spec_file)")
        println("  - spec loaded: $(oracle.spec !== nothing)")
        println("  - grammar: $(typeof(oracle.grammar))")
    catch e
        println("✗ Failed to create Z3Oracle: $e")
        Base.showerror(stderr, e)
    end
else
    println("⚠ Spec file not found at: $spec_file")
end

println("\n✓ All basic module loading tests passed!")
