"""
manual_benchmark_oracle_cegis.jl

Run from CEGIS/ directory:

    julia manual_benchmark_oracle_cegis.jl

This script loads a benchmark problem from HerbBenchmarks, constructs an
IOExampleOracle from its examples, and runs synth_with_oracle.
"""

import Pkg

const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
Pkg.activate(_SCRIPT_ENV)

const _HERB_PKGS = [
    "HerbCore", "HerbGrammar", "HerbConstraints",
    "HerbInterpret", "HerbSearch", "HerbSpecification",
    "CEGIS", "HerbBenchmarks",
]
let dev_dir = joinpath(homedir(), ".julia", "dev"),
    manifest = joinpath(_SCRIPT_ENV, "Manifest.toml")
    if !isfile(manifest) || filesize(manifest) < 200
        pkgs = [Pkg.PackageSpec(path=joinpath(dev_dir, p))
                for p in _HERB_PKGS if isdir(joinpath(dev_dir, p))]
        isempty(pkgs) || Pkg.develop(pkgs)
    end

    # Ensure benchmark package and its dependencies are available.
    benchmark_path = joinpath(@__DIR__, "..", "HerbBenchmarks.jl")
    if isdir(benchmark_path)
        Pkg.develop(Pkg.PackageSpec(path=benchmark_path))
    end
    Pkg.instantiate()
end

using HerbGrammar
using HerbBenchmarks

if !isdefined(Main, :CEGIS)
    include(joinpath(@__DIR__, "src", "CEGIS.jl"))
end
using .CEGIS

include("oracle_synth.jl")

# Pick a benchmark module whose primitives are directly callable in expressions.
benchmark_module = HerbBenchmarks.PBE_BV_Track_2018

identifiers = HerbBenchmarks.get_all_identifiers(benchmark_module)
identifier = sort(identifiers)[1]
pair = HerbBenchmarks.get_problem_grammar_pair(benchmark_module, identifier)
examples = pair.problem.spec
oracle = IOExampleOracle(examples; mod = benchmark_module)

println("Benchmark module: $(pair.benchmark_name)")
println("Problem identifier: $(pair.identifier)")
println("Number of oracle examples: $(length(examples))")

synth_out = synth_with_oracle(
    pair.grammar,
    :Start,
    oracle;
    max_depth = 5,
    max_enumerations = 5_000_000,
    mod = benchmark_module,
    iterator_type = :bfs,   # :mh, :sa, :bfs, :dfs
)
result = synth_out.result
satisfied_examples = synth_out.satisfied_examples

println("Status: $(result.status)")
println("Iterations: $(result.iterations)")
println("Counterexamples used: $(length(result.counterexamples))")
println("Best satisfied examples: $satisfied_examples")

