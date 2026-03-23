"""
semantic_smt_cegis.jl

CEGIS synthesis with semantic SMT-based verification using SyGuS specifications.

Usage:
    julia semantic_smt_cegis.jl [spec_file.sl]
"""

# ─────────────────────────────────────────────────────────────────────────────
# Environment setup
# ─────────────────────────────────────────────────────────────────────────────
import Pkg
const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
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

using HerbCore, HerbGrammar, HerbConstraints, HerbInterpret, HerbSearch, HerbSpecification

if !isdefined(Main, :CEGIS)
    include(joinpath(@__DIR__, "src", "CEGIS.jl"))
end
using .CEGIS

# Include supporting modules (order matters)
include("parse_sygus.jl")
include("rulenode_to_symbolics.jl")
include("semantic_smt_oracle.jl")
include("oracle_synth.jl")

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────
function create_symbolic_variables(var_names::Vector{Symbol})
    vars_dict = Dict{Symbol, Any}()
    var_syms = [Expr(:(::), v, :Real) for v in var_names]
    macro_expr = Expr(:macrocall, Symbol("@syms"), nothing, var_syms...)
    eval(macro_expr)
    for v in var_names
        vars_dict[v] = eval(v)
    end
    return vars_dict
end

function build_grammar_from_spec(vars::Vector{Symbol})
    grammar_str = "@csgrammar begin\n"
    for i in 5:5
        grammar_str *= "    Expr = $i\n"
    end
    for var in vars
        grammar_str *= "    Expr = $var\n"
    end
    grammar_str *= "    Expr = Expr + Expr\n"
    grammar_str *= "    Expr = Expr * Expr\n"
    grammar_str *= "    Expr = Expr < Expr\n"
    grammar_str *= "    Expr = Expr > Expr\n"
    grammar_str *= "    Expr = Expr >= Expr\n"
    grammar_str *= "    Expr = Expr <= Expr\n"
    grammar_str *= "end\n"
    return eval(Meta.parse(grammar_str))
end

# ─────────────────────────────────────────────────────────────────────────────
# Main execution
# ─────────────────────────────────────────────────────────────────────────────
spec_file = isempty(ARGS) ? "findidx_5_problem.sl" : ARGS[1]
if !isfile(spec_file)
    println("Error: Spec file not found: $spec_file")
    println("Usage: julia semantic_smt_cegis.jl [spec_file.sl]")
    exit(1)
end

println("Loading specification: $spec_file")
spec = parse_sygus(spec_file)
println("\nParsed SyGuS Specification:")
println(spec)
println()

sym_vars = create_symbolic_variables(spec.vars)
println("Created symbolic variables: $(collect(keys(sym_vars)))\n")

grammar = build_grammar_from_spec(spec.vars)
println("Created synthesis grammar with $(length(grammar.rules)) rules\n")

oracle = SemanticSMTOracle(spec, sym_vars, grammar)
println("Created SemanticSMTOracle for formal verification\n")

println(repeat("=", 80))
println("Starting CEGIS synthesis with SemanticSMTOracle")
println(repeat("=", 80))
println()

synth_out = synth_with_oracle(grammar, :Expr, oracle;
                              max_depth=8, max_enumerations=5_000_000)
result = synth_out.result
satisfied_examples = synth_out.satisfied_examples

# ─────────────────────────────────────────────────────────────────────────────
# Report results
# ─────────────────────────────────────────────────────────────────────────────
println()
println(repeat("=", 80))
println("Synthesis Results")
println(repeat("=", 80))
println("Status: $(result.status)")
println("Iterations: $(result.iterations)")
println("Counterexamples used: $(length(result.counterexamples))")
println("Best satisfied examples: $satisfied_examples")
println()

if result.program !== nothing
    println("✓ Synthesized Program:")
    println("  $(rulenode2expr(result.program, grammar))")
    println()
else
    println("✗ No program found within the resource limits")
end

println("Final Specification (IO Examples collected):")
for (i, example) in enumerate(result.counterexamples)
    println("  Example $i: input=$(example.input) => expected=$(example.expected_output)")
end
println()
println(repeat("=", 80))
