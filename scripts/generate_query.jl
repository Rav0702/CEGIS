#!/usr/bin/env julia
"""
generate_query.jl

Direct script using CEXGeneration's 2-method API to generate counterexample queries.

Run from the scripts/ directory:

    julia generate_query.jl ../spec_files/findidx_problem.sl fnd_sum "x + 1"

Usage:
    julia generate_query.jl <spec.sl> <function_name> <candidate_expr> [output.smt2]

Examples:
    julia generate_query.jl spec.sl f "x + 1"
    julia generate_query.jl spec.sl max "if x > y then x else y" query.smt2
    julia generate_query.jl ../spec_files/findidx_problem.sl fnd_sum "x + 1"
"""

import Pkg

# Set up module environment
const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
const _CEGIS_DIR = joinpath(@__DIR__, "..")

Pkg.activate(_SCRIPT_ENV)

let cegis_dev = _CEGIS_DIR
    manifest = joinpath(_SCRIPT_ENV, "Manifest.toml")
    if !isfile(manifest) || filesize(manifest) < 200
        # Develop CEGIS package locally
        Pkg.develop(Pkg.PackageSpec(path=cegis_dev))
    end
end

# Include the CEXGeneration module directly
const _CEX_GEN_MODULE = joinpath(_CEGIS_DIR, "src", "CEXGeneration", "CEXGeneration.jl")
include(_CEX_GEN_MODULE)
using .CEXGeneration

function main()
    if length(ARGS) < 3
        println("Usage: julia generate_query.jl <spec.sl> <function_name> <candidate_expr> [output.smt2]")
        println()
        println("Examples:")
        println("  julia generate_query.jl spec.sl f \"x + 1\"")
        println("  julia generate_query.jl spec.sl max \"if x > y then x else y\" query.smt2")
        exit(1)
    end

    spec_file = ARGS[1]
    func_name = ARGS[2]
    candidate_expr = ARGS[3]
    output_file = length(ARGS) >= 4 ? ARGS[4] : "query.smt2"

    # Variable to hold the parsed spec
    spec = nothing
    query = nothing

    # ─────────────────────────────────────────────────────────────────────────
    # API Method 1: Parse the specification file
    # ─────────────────────────────────────────────────────────────────────────
    println("📖 Parsing specification: $spec_file")
    try
        spec = parse_spec_from_file(spec_file)
        println("   ✓ Parsed successfully")
        println("   ├─ Logic: $(spec.logic)")
        println("   ├─ Functions: $(join([f.name for f in spec.synth_funs], ", "))")
        println("   ├─ Variables: $(join([v.name for v in spec.free_vars], ", "))")
        println("   └─ Constraints: $(length(spec.constraints))")
    catch e
        println("   ✗ Parse error: $e")
        exit(1)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # API Method 2: Generate counterexample query
    # ─────────────────────────────────────────────────────────────────────────
    println()
    println("🔍 Generating counterexample query")
    println("   Function: $func_name")
    println("   Candidate: $candidate_expr")
    try
        candidates = Dict(func_name => candidate_expr)
        query = generate_cex_query(spec, candidates)
        println("   ✓ Query generated successfully")
    catch e
        println("   ✗ Query generation error: $e")
        println("\nFull error trace:")
        showerror(stdout, e)
        println()
        exit(1)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Write query to file
    # ─────────────────────────────────────────────────────────────────────────
    println()
    println("📝 Writing query to file: $output_file")
    try
        open(output_file, "w") do f
            write(f, query)
        end
        println("   ✓ File written successfully")
        query_lines = length(split(query, '\n'))
        println("   └─ Lines: $query_lines")
    catch e
        println("   ✗ File write error: $e")
        exit(1)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Summary and next steps
    # ─────────────────────────────────────────────────────────────────────────
    println()
    println("✅ Complete!")
    println()
    println("Next steps:")
    println("  1. Verify with Z3:")
    println("     z3 $output_file")
    println()
    println("  2. View the generated query:")
    println("     cat $output_file")
end

main()
