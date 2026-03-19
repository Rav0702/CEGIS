"""
rulenode_smt_verification_demo.jl

Demonstrates using the RuleNode-to-Symbolics translator with SymbolicSMT
for formal verification of synthesized programs.

Run from CEGIS/ directory:
    julia rulenode_smt_verification_demo.jl
"""

import Pkg

const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
Pkg.activate(_SCRIPT_ENV)

const _HERB_PKGS = [
    "HerbCore", "HerbGrammar", "HerbConstraints",
    "HerbInterpret", "HerbSearch", "HerbSpecification",
    "SymbolicSMT",
]
let dev_dir = joinpath(homedir(), ".julia", "dev"),
    manifest = joinpath(_SCRIPT_ENV, "Manifest.toml")
    if !isfile(manifest) || filesize(manifest) < 200
        pkgs = [Pkg.PackageSpec(path=joinpath(dev_dir, p))
                for p in _HERB_PKGS if isdir(joinpath(dev_dir, p))]
        isempty(pkgs) || Pkg.develop(pkgs)
    end
end

using HerbCore
using HerbGrammar
using HerbInterpret
using HerbSearch
using HerbSpecification
using Symbolics
using SymbolicSMT
using SymbolicUtils

include("rulenode_to_symbolics.jl")

println("===== RuleNode to Symbolics Translator Demo =====\n")

# ──────────────────────────────────────────────────────────────────────────────
# Define Grammar
# ──────────────────────────────────────────────────────────────────────────────

@csgrammar begin
    Int = x
    Int = 0 | 1 | 2 | 3 | 4 | 5
    Int = Int + Int
    Int = Int * Int
    Int = Int - Int
end

println("Grammar defined:")
println("  Int = x | (0..5) | Int+Int | Int*Int | Int-Int\n")

# ──────────────────────────────────────────────────────────────────────────────
# Build symbolic context
# ──────────────────────────────────────────────────────────────────────────────

var_map = build_symbolic_context([:x])
@variables x::Real

println("Symbolic variable created: x\n")

# ──────────────────────────────────────────────────────────────────────────────
# Create some example RuleNodes and convert them
# ──────────────────────────────────────────────────────────────────────────────

println(repeat("=", 60))
println("EXAMPLE PROGRAMS")
println(repeat("=", 60) * "\n")

# Example 1: Just the variable x
# Rule index depends on grammar structure
# For this grammar: x should be rule 1
program1 = RuleNode(1)  # x
expr1 = rulenode_to_symbolic(program1, grammar, var_map)
println("Program 1: x")
println("  Symbolic: $expr1\n")

# Example 2: Constant (e.g., 2)
program2 = RuleNode(3)  # 2 (one of the constants)
expr2 = rulenode_to_symbolic(program2, grammar, var_map)
println("Program 2: 2")
println("  Symbolic: $expr2\n")

# Example 3: x + 1
# structure: Add node with children [x, 1]
program3 = RuleNode(7, [RuleNode(1), RuleNode(2)])  # x + 0 or similar
try
    expr3 = rulenode_to_symbolic(program3, grammar, var_map)
    println("Program 3: x + constant")
    println("  Symbolic: $expr3\n")
catch e
    println("Program 3: Could not convert (rule indices may differ)")
    println("  Error: $e\n")
end

# ──────────────────────────────────────────────────────────────────────────────
# Formal Verification Example
# ──────────────────────────────────────────────────────────────────────────────

println(repeat("=", 60))
println("FORMAL VERIFICATION EXAMPLE")
println(repeat("=", 60) * "\n")

println("Setup:")
println("  Constraints: x >= 0, x <= 10")
println("  Specification: output = x + 2\n")

# Create constraints
constraints = Constraints([
    x >= 0,
    x <= 10
])

# Create specification: output should equal x + 2
spec = x + 2

# Test if (output ≠ x + 2) is satisfiable when x is in [0, 10]
# This checks if there's an input where the program violates the spec
negated_spec = !spec  # This would be for checking violations

println("Checking if program x satisfies spec (x + 2):")
result = issatisfiable(!(x == x + 2), constraints)
println("  Result: $(result)\n")

# Try another spec: maybe x + x = 2*x
println("Checking if (x + x = 2*x) can be satisfied:")
result2 = issatisfiable((x + x == 2*x) & (x >= 0), constraints)
println("  Result: $(result2)\n")

# ──────────────────────────────────────────────────────────────────────────────
# Synthesis + Verification Workflow
# ──────────────────────────────────────────────────────────────────────────────

println(repeat("=", 60))
println("SYNTHESIS + VERIFICATION WORKFLOW")
println(repeat("=", 60) * "\n")

println("Goal: Synthesize program that computes 2*x for x >= 0\n")

# Training examples
examples = IOExample[
    IOExample(Dict(:x => 0), 0),
    IOExample(Dict(:x => 1), 2),
    IOExample(Dict(:x => 2), 4),
    IOExample(Dict(:x => 3), 6),
]

println("Training examples:")
for ex in examples
    println("  f($(ex.in[:x])) = $(ex.out)")
end
println()

# Create problem
problem = Problem(examples)

# Synthesize one solution
iterator = BFSIterator(grammar, :Int, max_depth=5)
solution, _ = synth(problem, iterator)

if solution !== nothing
    # Convert to symbolic expression
    try
        solution_sym = rulenode_to_symbolic(solution, grammar, var_map)
        println("Synthesized program: $(rulenode2expr(solution, grammar))")
        println("Symbolic form: $solution_sym\n")
        
        # Now verify with SMT: does (solution = 2*x) hold for all x in [0, 10]?
        println("Verifying: Does synthesized program equal 2*x for all x in [0, 10]?")
        
        smt_constraints = Constraints([x >= 0, x <= 10])
        smt_spec = 2 * x
        
        # Check if there exists an x where program ≠ spec
        is_correct = !issatisfiable(solution_sym != smt_spec, smt_constraints)
        println("  Verification: $(is_correct ? "✓ PASS" : "✗ FAIL")\n")
        
    catch e
        println("Could not verify synthesized program:")
        println("  Error: $e\n")
    end
else
    println("No solution found.\n")
end

println(repeat("=", 60))
println("Demo complete!")
println("Use rulenode_to_symbolic() to convert programs for SMT verification")
