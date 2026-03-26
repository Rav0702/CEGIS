#!/usr/bin/env julia
"""
verify_with_z3.jl

End-to-end verification using Z3 Julia module directly (no subprocess calls).

Usage:
    julia verify_with_z3.jl <spec.sl> <function_name> <candidate_expr>

Example:
    julia verify_with_z3.jl ../spec_files/findidx_problem.sl fnd_sum "x1 + 1"

Output shows:
    ✅ VALID CANDIDATE - All constraints satisfied
    OR
    ❌ COUNTEREXAMPLE - Specific variable assignments that violate constraints
"""

import Pkg

# First ensure Z3 is available
try
    using Z3
catch
    println("Installing Z3.jl...")
    Pkg.add("Z3")
    using Z3
end

const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
const _CEGIS_DIR = joinpath(@__DIR__, "..")

Pkg.activate(_SCRIPT_ENV)

let cegis_dev = _CEGIS_DIR
    manifest = joinpath(_SCRIPT_ENV, "Manifest.toml")
    if !isfile(manifest) || filesize(manifest) < 200
        Pkg.develop(Pkg.PackageSpec(path=cegis_dev))
    end
end

const _CEX_GEN_MODULE = joinpath(_CEGIS_DIR, "src", "CEXGeneration", "CEXGeneration.jl")
include(_CEX_GEN_MODULE)
using .CEXGeneration

function main()
    if length(ARGS) < 3
        println("Usage: julia verify_with_z3.jl <spec.sl> <function_name> <candidate_expr>")
        println()
        println("Examples:")
        println("  julia verify_with_z3.jl spec.sl f \"x + 1\"")
        println("  julia verify_with_z3.jl ../spec_files/findidx_problem.sl fnd_sum \"x1 + 1\"")
        exit(1)
    end

    spec_file = ARGS[1]
    func_name = ARGS[2]
    candidate_expr = ARGS[3]

    # Step 1: Parse specification
    println("📖 Parsing: $spec_file")
    spec = try
        parse_spec_from_file(spec_file)
    catch e
        println("   ✗ Error: $e")
        exit(1)
    end
    println("   ✓ Success: $(join([f.name for f in spec.synth_funs], ", "))")

    # Step 2: Generate query
    println()
    println("🔧 Generating Z3 query for: $(candidate_expr)")
    query = try
        candidates = Dict(func_name => candidate_expr)
        generate_cex_query(spec, candidates)
    catch e
        println("   ✗ Error: $e")
        exit(1)
    end
    println("   ✓ Generated")

    # Step 3: Run Z3 directly (no files)
    println()
    println("⚙️  Running Z3 via Julia API...")
    result = try
        verify_query(query)
    catch e
        println("   ✗ Error: $e")
        Base.showerror(stdout, e)
        exit(1)
    end

    # Step 4: Display results
    println()
    println(format_result(result, spec))
    
    # Exit with appropriate code
    exit(result.status == :unsat ? 0 : 1)
end

main()
