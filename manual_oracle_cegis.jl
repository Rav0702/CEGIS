"""
manual_oracle_cegis.jl

Run from CEGIS/ directory:

    julia manual_oracle_cegis.jl

Builds IO examples for target behavior:
    x > 5 ? x^2 : x
then initializes `IOExampleOracle` and runs `synth_with_oracle`.
"""

import Pkg

const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
Pkg.activate(_SCRIPT_ENV)

const _HERB_PKGS = [
    "HerbCore", "HerbGrammar", "HerbConstraints",
    "HerbInterpret", "HerbSearch", "HerbSpecification", "CEGIS",
]
let dev_dir = joinpath(homedir(), ".julia", "dev"),
    manifest = joinpath(_SCRIPT_ENV, "Manifest.toml")
    if !isfile(manifest) || filesize(manifest) < 200
        pkgs = [Pkg.PackageSpec(path=joinpath(dev_dir, p))
                for p in _HERB_PKGS if isdir(joinpath(dev_dir, p))]
        isempty(pkgs) || Pkg.develop(pkgs)
    end
end

using HerbGrammar
using HerbSpecification

if !isdefined(Main, :CEGIS)
    include(joinpath(@__DIR__, "src", "CEGIS.jl"))
end
using .CEGIS

include("oracle_synth.jl")

# Grammar can express: ifelse(5 < x, x * x, x)
grammar = @csgrammar begin
    Expr = x
    Expr = 0
    Expr = 1
    Expr = 5
    Expr = Expr + Expr
    Expr = Expr - Expr
    Expr = Expr * Expr
    Expr = ifelse(Cond, Expr, Expr)

    Cond = Expr < Expr
end

start_symbol = :Expr

target(x) = x > 5 ? x^2 : x

# Held-out oracle examples.
xs = collect(-3:12)
examples = IOExample[IOExample(Dict{Symbol,Any}(:x => x), target(x)) for x in xs]
oracle = IOExampleOracle(examples)

result = synth_with_oracle(
    grammar,
    start_symbol,
    oracle;
    max_iterations = 40,
    max_depth = 6,
    max_enumerations = 200_000,
)

println("Status: $(result.status)")
println("Iterations: $(result.iterations)")
println("Counterexamples used: $(length(result.counterexamples))")

if result.program !== nothing
    println("Program: $(rulenode2expr(result.program, grammar))")
end
