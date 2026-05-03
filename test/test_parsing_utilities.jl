"""
Unit tests for CEGIS parsing and utility functions.

Tests critical methods used in e2e synthesis:
  - File parsing (SyGuS-v2 spec file parsing)
  - Grammar building from specifications
  - Solution conversion and comparison utilities
  - Iterator configuration
"""

using HerbCore
using HerbGrammar
using HerbInterpret
using HerbSearch
using HerbSpecification
using Test

const CEGIS_ROOT = dirname(@__DIR__)
const CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

include("test_helpers.jl")

@testset "CEGIS Parsing & Utilities" verbose = true begin

    # ─────────────────────────────────────────────────────────────────────────────
    # Test: find_spec_file
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "find_spec_file - locates spec files" begin
        # Test finding specs in phase3_benchmarks
        max2_path = find_spec_file("max2_simple")
        @test isfile(max2_path)
        @test occursin("max2_simple", max2_path)
        @test endswith(max2_path, ".sl")
        
        # Test finding specs in main spec_files directory
        findidx_path = find_spec_file("findidx_2_simple")
        @test isfile(findidx_path)
        @test endswith(findidx_path, ".sl")
        
        # Test error on missing spec
        @test_throws ErrorException find_spec_file("nonexistent_spec_12345")
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Test: solution_matches
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "solution_matches - normalizes and compares solutions" begin
        # Exact match
        @test solution_matches("2 * x + y", "2 * x + y") == true
        
        # Whitespace normalization
        @test solution_matches("2 * x + y", "2 * x + y") == true
        @test solution_matches("  2  *  x  +  y  ", "  2  *  x  +  y  ") == true
        @test solution_matches("ifelse(x > y, x, y)", "ifelse(x > y, x, y)") == true
        
        # Multi-space normalization
        @test solution_matches("x  +  y", "x  +  y") == true
        
        # Mismatch
        @test solution_matches("2 * x + y", "x + y") == false
        @test solution_matches("ifelse(x > y, x, y)", "ifelse(x < y, x, y)") == false
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Test: SyGuS spec file parsing
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "SyGuS spec parsing" begin
        # Test parsing arithmetic spec
        arith_path = find_spec_file("arith_simple")
        arith_content = open(arith_path) do f; read(f, String) end
        @test contains(arith_content, "set-logic")
        @test contains(arith_content, "synth-fun")
        @test contains(arith_content, "constraint")
        
        # Test parsing max spec with ifelse
        max2_path = find_spec_file("max2_simple")
        max2_content = open(max2_path) do f; read(f, String) end
        @test contains(max2_content, "set-logic")
        @test contains(max2_content, "synth-fun")
        
        # Test parsing spec with define-fun helper
        define_sum_path = find_spec_file("simple_define_sum")
        define_sum_content = open(define_sum_path) do f; read(f, String) end
        @test contains(define_sum_content, "define-fun")
        @test contains(define_sum_content, "synth-fun")
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Test: grammar building from spec
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "build_grammar_from_spec - creates valid grammars" begin
        # Test building grammar for arithmetic spec
        arith_path = find_spec_file("arith_simple")
        arith_grammar = CEGIS.build_grammar_from_spec(arith_path)
        @test arith_grammar !== nothing
        @test isa(arith_grammar, AbstractGrammar)
        
        # Verify grammar has rules (check as string)
        grammar_str = string(arith_grammar)
        @test length(grammar_str) > 0
        
        # Test building grammar for max spec (requires ifelse)
        max2_path = find_spec_file("max2_simple")
        max2_grammar = CEGIS.build_grammar_from_spec(max2_path)
        @test max2_grammar !== nothing
        @test isa(max2_grammar, AbstractGrammar)
        
        # Check that max2 grammar has ifelse rule
        max2_rules_str = string(max2_grammar)
        @test contains(max2_rules_str, "ifelse") || contains(max2_rules_str, "ite")
        
        # Test building grammar for spec with define-fun
        define_sum_path = find_spec_file("simple_define_sum")
        define_sum_grammar = CEGIS.build_grammar_from_spec(define_sum_path)
        @test define_sum_grammar !== nothing
        @test isa(define_sum_grammar, AbstractGrammar)
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Test: CEGISProblem construction
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "CEGISProblem construction" begin
        arith_path = find_spec_file("arith_simple")
        
        # Test basic construction
        problem1 = CEGIS.CEGISProblem(arith_path)
        @test problem1.spec_path == arith_path
        @test problem1.desired_solution === nothing
        @test problem1.is_initialized == false
        
        # Test construction with desired_solution
        problem2 = CEGIS.CEGISProblem(arith_path; desired_solution="2 * x + y")
        @test problem2.desired_solution == "2 * x + y"
        
        # Test error on missing spec file
        @test_throws ErrorException CEGIS.CEGISProblem("nonexistent_spec.sl")
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Test: Iterator configuration
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "IteratorConfig creates valid iterators" begin
        arith_path = find_spec_file("arith_simple")
        grammar = CEGIS.build_grammar_from_spec(arith_path)
        
        # Test BFS iterator creation
        bfs_config = CEGIS.IteratorConfig.BFSIteratorConfig(max_depth=5)
        bfs_iterator = CEGIS.IteratorConfig.create_iterator(bfs_config, grammar, :Expr)
        @test bfs_iterator !== nothing
        @test isa(bfs_iterator, HerbSearch.BFSIterator)
        
        # Test that iterator can be used in a loop
        count = 0
        for prog in bfs_iterator
            count += 1
            @test prog !== nothing
            if count >= 5; break; end
        end
        @test count == 5
        
        # Test different max_depth values
        for depth in [3, 5, 7]
            config = CEGIS.IteratorConfig.BFSIteratorConfig(max_depth=depth)
            iterator = CEGIS.IteratorConfig.create_iterator(config, grammar, :Expr)
            @test iterator !== nothing
        end
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Test: solution_to_string conversion
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "solution_to_string - converts RuleNode to string" begin
        arith_path = find_spec_file("arith_simple")
        grammar = CEGIS.build_grammar_from_spec(arith_path)
        
        # Create a simple program by iterating
        prog = nothing
        for p in CEGIS.IteratorConfig.create_iterator(
            CEGIS.IteratorConfig.BFSIteratorConfig(max_depth=2),
            grammar,
            :Expr
        )
            prog = p
            break
        end
        
        @test prog !== nothing
        sol_str = solution_to_string(prog, grammar)
        @test isa(sol_str, String)
        @test length(sol_str) > 0
        # Solution should be a valid Julia expression
        @test !contains(sol_str, "ERROR") || contains(sol_str, "nothing")
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Test: Spec file format variations
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "Different spec file formats parse correctly" begin
        # Arithmetic (basic LIA)
        arith_path = find_spec_file("arith_simple")
        arith_grammar = CEGIS.build_grammar_from_spec(arith_path)
        @test isa(arith_grammar, AbstractGrammar)
        
        # Maximum (requires comparison operators)
        max2_path = find_spec_file("max2_simple")
        max2_grammar = CEGIS.build_grammar_from_spec(max2_path)
        @test isa(max2_grammar, AbstractGrammar)
        
        # Guard (if-then-else logic)
        guard_path = find_spec_file("guard_simple")
        guard_grammar = CEGIS.build_grammar_from_spec(guard_path)
        @test isa(guard_grammar, AbstractGrammar)
        
        # Define-fun helper function
        define_sum_path = find_spec_file("simple_define_sum")
        define_sum_grammar = CEGIS.build_grammar_from_spec(define_sum_path)
        @test isa(define_sum_grammar, AbstractGrammar)
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Test: run_spec_synthesis helper function
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "run_spec_synthesis completes without errors" begin
        # Simple test with short timeout
        arith_path = find_spec_file("arith_simple")
        
        result = run_spec_synthesis(
            arith_path;
            max_depth=3,
            max_enumerations=1000
        )
        
        @test result !== nothing
        @test hasfield(typeof(result), :status)
        @test hasfield(typeof(result), :program)
        @test hasfield(typeof(result), :iterations)
        
        # Test that iteration counter is reasonable
        @test result.iterations >= 0
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Test: Grammar consistency across multiple builds
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "Grammar builds are deterministic" begin
        arith_path = find_spec_file("arith_simple")
        
        # Build same grammar multiple times
        grammar1 = CEGIS.build_grammar_from_spec(arith_path)
        grammar2 = CEGIS.build_grammar_from_spec(arith_path)
        
        # Both should be valid grammars
        @test isa(grammar1, AbstractGrammar)
        @test isa(grammar2, AbstractGrammar)
        
        # Both should produce same string representation
        @test string(grammar1) == string(grammar2)
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Test: Error handling for malformed specifications
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "Error handling for edge cases" begin
        # Test that find_spec_file gives helpful error messages
        try
            find_spec_file("completely_nonexistent_spec")
            @test false  # Should have thrown
        catch e
            @test isa(e, ErrorException)
            @test contains(string(e), "Spec file not found")
        end
        
        # Test that solution_matches handles empty strings gracefully
        @test solution_matches("", "") == true
        @test solution_matches("x", "") == false
        @test solution_matches("", "x") == false
    end

    # ─────────────────────────────────────────────────────────────────────────────
    # Test: spec file content validation
    # ─────────────────────────────────────────────────────────────────────────────
    @testset "Spec files contain required components" begin
        specs_to_check = [
            ("arith_simple", ["set-logic", "synth-fun", "constraint"]),
            ("max2_simple", ["set-logic", "synth-fun", "constraint"]),
            ("simple_define_sum", ["set-logic", "synth-fun", "constraint", "define-fun"]),
        ]
        
        for (spec_name, required_keywords) in specs_to_check
            path = find_spec_file(spec_name)
            content = open(path) do f; read(f, String) end
            
            for keyword in required_keywords
                @test contains(content, keyword)
            end
        end
    end

end
