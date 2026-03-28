#!/usr/bin/env julia

import Pkg
Pkg.activate(".")

include("src/CEXGeneration/CEXGeneration.jl")
using .CEXGeneration

spec = parse_spec_from_file("spec_files/findidx_problem.sl")
println("Spec parsed:")
println("  Logic: $(spec.logic)")
println("  Synth Funs: $(length(spec.synth_funs))")
println("  Constraints: $(length(spec.constraints))")
for (i, c) in enumerate(spec.constraints)
    println("  [$i] $c")
end

candidates = Dict("fnd_sum" => "5")
query = generate_cex_query(spec, candidates)
println("\n=== QUERY ===")
println(query)
