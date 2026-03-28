#!/usr/bin/env julia
"""
Debug script to check what constraints are being parsed from max3.sl
"""

CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

using HerbCore, HerbGrammar, HerbSearch, HerbSpecification, HerbInterpret
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

const BENCHMARK_DIR = joinpath(dirname(@__DIR__), "spec_files", "phase3_benchmarks")
spec_path = joinpath(BENCHMARK_DIR, "max3_simple.sl")

cexgen = getfield(Main, :CEGIS) |> m -> getfield(m, :CEXGeneration)
spec = cexgen.parse_spec_from_file(spec_path)

println("Specification for max3:")
println("  Logic: $(spec.logic)")
println("  Synth functions: $(length(spec.synth_funs))")
for sfun in spec.synth_funs
    println("    - $(sfun.name)$(sfun.params) -> $(sfun.sort)")
end

println("\n  Free variables: $(length(spec.free_vars))")
for fv in spec.free_vars
    println("    - $(fv.name): $(fv.sort)")
end

println("\n  Constraints: $(length(spec.constraints))")
for (i, constraint) in enumerate(spec.constraints)
    println("    $i: $(constraint)")
end

println("\n\nGenerated spec function body:")
spec_body = cexgen.query.build_spec_function_body(spec.constraints)
println(spec_body)

println("\n\nFull query:")
query = cexgen.generate_cex_query(spec, Dict("max3" => "x"))
println(query)
