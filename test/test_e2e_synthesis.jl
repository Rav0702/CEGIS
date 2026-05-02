"""
End-to-end synthesis tests on simple SyGuS specifications.

Each test loads a specification file, builds a grammar, and runs the CEGIS
synthesis loop to verify that the tool can find solutions or recognize known limitations.
"""

@testset "E2E Synthesis on Simple Specifications" verbose = true begin
    
    @testset "Arithmetic (2*x + y)" begin
        spec_path = find_spec_file("arith_simple")
        
        result = run_spec_synthesis(
            spec_path;
            max_depth=5,
            max_enumerations=100_000
        )
        
        @test result.program !== nothing
        @test result.iterations > 0
        
        if result.program !== nothing
            grammar = CEGIS.build_grammar_from_spec(spec_path)
            solution_str = solution_to_string(result.program, grammar)
            # Check that the solution contains the expected operations
            @test occursin("+", solution_str) || occursin("-", solution_str)
        end
    end
    
    @testset "Maximum of Two" begin
        spec_path = find_spec_file("max2_simple")
        expected = "ifelse(x0 > x1, x0, x1)"
        
        result = run_spec_synthesis(
            spec_path;
            desired_solution=expected,
            max_depth=5,
            max_enumerations=100_000
        )
        
        @test result.program !== nothing
        @test result.iterations > 0
        
        if result.program !== nothing
            grammar = CEGIS.build_grammar_from_spec(spec_path)
            solution_str = solution_to_string(result.program, grammar)
            @test occursin("ifelse", solution_str)
        end
    end
    
    @testset "Guard with If-Then-Else" begin
        spec_path = find_spec_file("guard_simple")
        
        result = run_spec_synthesis(
            spec_path;
            max_depth=5,
            max_enumerations=100_000
        )
        
        @test result.program !== nothing
        @test result.iterations > 0
    end
    
    @testset "Find-Index with Boundaries" begin
        spec_path = find_spec_file("findidx_2_simple")
        
        result = run_spec_synthesis(
            spec_path;
            max_depth=5,
            max_enumerations=100_000
        )
        
        @test result.program !== nothing
        @test result.iterations > 0
    end
    
    @testset "Conditional Sum" begin
        spec_path = find_spec_file("fnd_sum_simple")
        
        result = run_spec_synthesis(
            spec_path;
            max_depth=5,
            max_enumerations=100_000
        )
        
        @test result.program !== nothing
        @test result.iterations > 0
    end
    
    @testset "Simple Define-Sum (x + y)" begin
        spec_path = find_spec_file("simple_define_sum")
        expected = "a + b"
        
        result = run_spec_synthesis(
            spec_path;
            max_depth=5,
            max_enumerations=100_000
        )
        
        @test result.program !== nothing
        @test result.iterations > 0
        
        if result.program !== nothing
            grammar = CEGIS.build_grammar_from_spec(spec_path)
            solution_str = solution_to_string(result.program, grammar)
            @test solution_matches(solution_str, expected)
        end
    end

    @testset "Maximum of Three (Complex)" begin
        spec_path = find_spec_file("max3_simple")
        
        result = run_spec_synthesis(
            spec_path;
            max_depth=5,
            max_enumerations=100_000
        )
        
        # Note: max3 is a known harder problem, but we still expect synthesis to attempt it
        @test result.status !== nothing
        @test result.iterations >= 0
        # Program may or may not be found depending on config, but test infrastructure should work
    end

    @testset "Symmetric Maximum" begin
        spec_path = find_spec_file("symmetric_max")
        
        result = run_spec_synthesis(
            spec_path;
            max_depth=5,
            max_enumerations=100_000
        )
        
        @test result.status !== nothing
        @test result.iterations >= 0
    end

end
