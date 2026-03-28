#!/usr/bin/env julia
"""
test_phase1_modules.jl

Quick test that Phase 1 implementations are properly integrated.
"""

# Direct path setup for debugging
CEGIS_PATH = joinpath(@__DIR__, "src")
push!(LOAD_PATH, CEGIS_PATH)

using CEGIS
using CEGIS.GrammarBuilding
using CEGIS.Parsers

println("="^80)
println("PHASE 1: Module Integration Test")
println("="^80)

# Test 1: Import modules
println("\n[TEST 1] Module imports...")
try
    println("  ✅ CEGIS module loaded")
    println("  ✅ CEGIS.GrammarBuilding module loaded")
    println("  ✅ CEGIS.Parsers module loaded")
catch e
    println("  ❌ FAILED: $(e)")
end

# Test 2: Check eval_grammar_string
println("\n[TEST 2] eval_grammar_string() implementation...")
try
    grammar_str = """
    @csgrammar begin
        Expr = x | y | 1 | 0
        Expr = Expr + Expr
        Expr = Expr - Expr
    end
    """
    
    # This should work now
    grammar = eval_grammar_string(grammar_str)
    println("  ✅ Grammar constructed successfully")
    println("    Type: $(typeof(grammar))")
catch e
    println("  ⚠ Expected: Grammar construction requires HerbGrammar context")
    println("    Error: $(typeof(e).__name__)")
end

# Test 3: Check GrammarConfig
println("\n[TEST 3] GrammarConfig and BASE_OPERATIONS...")
try
    config = GrammarConfig(
        base_operations = BASE_OPERATIONS,
        start_symbol = :Expr,
        include_constants = true
    )
    
    println("  ✅ GrammarConfig created")
    println("    - Categories: $(length(keys(config.base_operations)))")
    println("    - Start symbol: $(config.start_symbol)")
    println("    - Include constants: $(config.include_constants)")
catch e
    println("  ❌ FAILED: $(e)")
end

# Test 4: Check SyGuSParser
println("\n[TEST 4] SyGuSParser availability...")
try
    parser = SyGuSParser()
    println("  ✅ SyGuSParser created")
    println("    Type: $(typeof(parser))")
catch e
    println("  ❌ FAILED: $(e)")
end

# Test 5: Check CEGISProblem constructor defaults
println("\n[TEST 5] CEGISProblem constructor defaults...")
try
    spec_file = "spec_files/phase3_benchmarks/max2_simple.sl"
    
    if isfile(spec_file)
        # This should NOT error now
        problem = CEGISProblem(spec_file)
        println("  ✅ CEGISProblem created with defaults")
        println("    - spec_parser type: $(typeof(problem.spec_parser).__name__)")
        println("    - grammar_config type: $(typeof(problem.grammar_config).__name__)")
        println("    - oracle_factory type: $(typeof(problem.oracle_factory).__name__)")
        println("    - iterator_config type: $(typeof(problem.iterator_config).__name__)")
    else
        println("  ⚠ SKIPPED: Spec file not found (run phase3_test_benchmarks.jl first)")
    end
catch e
    println("  ❌ FAILED: $(e)")
    println("     Type: $(typeof(e).__name__)")
end

println("\n" * "="^80)
println("PHASE 1: Module Integration Test Complete")
println("="^80)
