"""
test_rulenode_to_symbolics.jl

Unit tests for rulenode_to_symbolics translator.
Tests conversion of various RuleNode structures to Symbolics expressions.

Run from CEGIS/ directory:
    julia test_rulenode_to_symbolics.jl
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

# Test counter
tests_passed = 0
tests_failed = 0

function test_case(name, f)
    global tests_passed, tests_failed
    try
        f()
        println("✓ $name")
        tests_passed += 1
    catch e
        println("✗ $name")
        println("  Error: $e")
        tests_failed += 1
    end
end

println(repeat("=", 60))
println("RuleNode-to-Symbolics Translator Tests")
println(repeat("=", 60) * "\n")

# ──────────────────────────────────────────────────────────────────────────────
# Test 1: Simple Grammar with Basic Operations
# ──────────────────────────────────────────────────────────────────────────────

@csgrammar begin
    Int = x
    Int = 1 | 2 | 3
    Int = Int + Int
    Int = Int - Int
    Int = Int * Int
end

var_map = build_symbolic_context([:x])
@variables x::Real

test_case("Variable x translates to symbolic variable", () -> begin
    program = RuleNode(1)  # x
    result = rulenode_to_symbolic(program, grammar, var_map)
    @assert isequal(result, x) "Expected x, got $result"
end)

test_case("Constant integer translates correctly", () -> begin
    program = RuleNode(2)  # 1
    result = rulenode_to_symbolic(program, grammar, var_map)
    @assert isequal(simplify(result - 1), 0) "Expected constant 1"
end)

test_case("Addition translates to Symbolics +", () -> begin
    # x + 1
    program = RuleNode(6, [RuleNode(1), RuleNode(2)])
    result = rulenode_to_symbolic(program, grammar, var_map)
    expected = x + 1
    @assert isequal(simplify(result - expected), 0) "Expected x + 1"
end)

test_case("Subtraction translates to Symbolics -", () -> begin
    # x - 1
    program = RuleNode(7, [RuleNode(1), RuleNode(2)])
    result = rulenode_to_symbolic(program, grammar, var_map)
    expected = x - 1
    @assert isequal(simplify(result - expected), 0) "Expected x - 1"
end)

test_case("Multiplication translates to Symbolics *", () -> begin
    # x * 2
    program = RuleNode(8, [RuleNode(1), RuleNode(3)])
    result = rulenode_to_symbolic(program, grammar, var_map)
    expected = x * 2
    @assert isequal(simplify(result - expected), 0) "Expected 2x"
end)

test_case("Nested expressions evaluate correctly", () -> begin
    # (x + 1) * 2
    inner = RuleNode(6, [RuleNode(1), RuleNode(2)])  # x + 1
    program = RuleNode(8, [inner, RuleNode(3)])       # (x + 1) * 2
    result = rulenode_to_symbolic(program, grammar, var_map)
    expected = (x + 1) * 2
    @assert isequal(simplify(result - expected), 0) "Expected (x+1)*2"
end)

# ──────────────────────────────────────────────────────────────────────────────
# Test 2: Grammar with Comparisons
# ──────────────────────────────────────────────────────────────────────────────

@csgrammar begin
    Bool = x > 5
    Bool = x < 3
    Bool = x == 2
    Bool = x >= 4
    Bool = x <= 6
    Int = x
    Int = 1 | 2
end

var_map2 = build_symbolic_context([:x])

test_case("Greater than comparison translates", () -> begin
    program = RuleNode(1)  # x > 5
    result = rulenode_to_symbolic(program, grammar, var_map2)
    @assert isequal(result, x > 5) "Expected comparison x > 5"
end)

test_case("Less than comparison translates", () -> begin
    program = RuleNode(2)  # x < 3
    result = rulenode_to_symbolic(program, grammar, var_map2)
    @assert isequal(result, x < 3) "Expected comparison x < 3"
end)

test_case("Equality comparison translates", () -> begin
    program = RuleNode(3)  # x == 2
    result = rulenode_to_symbolic(program, grammar, var_map2)
    @assert isequal(result, x == 2) "Expected equality x == 2"
end)

# ──────────────────────────────────────────────────────────────────────────────
# Test 3: Multiple Variables
# ──────────────────────────────────────────────────────────────────────────────

@csgrammar begin
    Int = x
    Int = y
    Int = 1 | 2
    Int = Int + Int
end

var_map3 = build_symbolic_context([:x, :y])
@variables y::Real

test_case("Multiple variables in context", () -> begin
    # y as first symbol
    program = RuleNode(2)  # y
    result = rulenode_to_symbolic(program, grammar, var_map3)
    @assert isequal(result, y) "Expected variable y"
end)

test_case("Expression with multiple variables", () -> begin
    # x + y
    program = RuleNode(7, [RuleNode(1), RuleNode(2)])
    result = rulenode_to_symbolic(program, grammar, var_map3)
    expected = x + y
    @assert isequal(simplify(result - expected), 0) "Expected x + y"
end)

# ──────────────────────────────────────────────────────────────────────────────
# Test 4: Power/Exponentiation
# ──────────────────────────────────────────────────────────────────────────────

@csgrammar begin
    Int = x
    Int = 2 | 3
    Int = Int ^ Int
    Int = Int * Int
end

var_map4 = build_symbolic_context([:x])

test_case("Exponentiation translates to Symbolics ^", () -> begin
    # x ^ 2
    program = RuleNode(3, [RuleNode(1), RuleNode(2)])
    result = rulenode_to_symbolic(program, grammar, var_map4)
    expected = x ^ 2
    # Simplify to compare
    diff = simplify(result - expected)
    @assert isequal(diff, 0) || iszero(diff) "Expected x^2, got $result"
end)

# ──────────────────────────────────────────────────────────────────────────────
# Test 5: Variable Context Building
# ──────────────────────────────────────────────────────────────────────────────

test_case("build_symbolic_context creates correct mapping", () -> begin
    vm = build_symbolic_context([:a, :b, :c])
    @assert haskey(vm, :a) "Missing variable a"
    @assert haskey(vm, :b) "Missing variable b"
    @assert haskey(vm, :c) "Missing variable c"
    @assert length(vm) == 3 "Expected 3 variables"
end)

# ──────────────────────────────────────────────────────────────────────────────
# Test 6: Integration with Symbolics
# ──────────────────────────────────────────────────────────────────────────────

@csgrammar begin
    Int = x
    Int = 1 | 2 | 3
    Int = Int + Int
    Int = Int * Int
end

var_map6 = build_symbolic_context([:x])

test_case("Converted expression can be used with Symbolics operations", () -> begin
    program = RuleNode(6, [RuleNode(1), RuleNode(2)])  # x + 1
    sym_expr = rulenode_to_symbolic(program, grammar, var_map6)
    
    # Use with Symbolics operations
    expanded = expand(sym_expr)
    simplified = simplify(expanded)
    
    # Just verify these don't error
    @assert expanded !== nothing "Expand failed"
    @assert simplified !== nothing "Simplify failed"
end)

test_case("Converted expression can be substituted", () -> begin
    program = RuleNode(6, [RuleNode(1), RuleNode(2)])  # x + 1
    sym_expr = rulenode_to_symbolic(program, grammar, var_map6)
    
    # Substitute x with a value
    result = substitute(sym_expr, Dict(x => 5))
    @assert isequal(result, 6) "Expected substitution to give 6"
end)

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────

println()
println(repeat("=", 60))
println("Test Summary")
println(repeat("=", 60))
println("Passed: $tests_passed")
println("Failed: $tests_failed")
if tests_failed == 0
    println("\n✓ All tests passed!")
else
    println("\n✗ Some tests failed")
    exit(1)
end
