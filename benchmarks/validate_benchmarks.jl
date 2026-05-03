#!/usr/bin/env julia
"""
Benchmark Suite Validation and Synthesis Script

Runs synthesis on all benchmark specifications using 1M enumeration,
saves solutions to files.
"""

using Test

const CEGIS_ROOT = dirname(@__DIR__)
const CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

# Import HerbGrammar so @csgrammar macro is available in Main
using HerbGrammar

# Include test helpers for synthesis functions
include(joinpath(CEGIS_ROOT, "test", "test_helpers.jl"))

# Benchmark problems
const PROBLEMS = [
    "max_two",
    "abs_value",
    "conditional_sum",
    "find_max_three",
    "sign_function",
    "clamp_value",
]

const DIFFICULTIES = ["easy", "medium", "hard"]

# Validate all specs first
@testset "Benchmark Suite Validation" verbose = true begin
    for problem in PROBLEMS
        @testset "$problem problem" begin
            for difficulty in DIFFICULTIES
                spec_path = joinpath(@__DIR__, problem, "$difficulty.sl")
                
                @test isfile(spec_path)
                content = open(spec_path) do f; read(f, String) end
                @test contains(content, "set-logic")
                @test contains(content, "synth-fun")
                @test contains(content, "constraint")
                @test contains(content, "check-synth")
                @test contains(content, "LIA")
                
                readme_path = joinpath(@__DIR__, problem, "README.md")
                @test isfile(readme_path)
                readme_content = open(readme_path) do f; read(f, String) end
                @test contains(readme_content, "Problem Description")
                @test contains(readme_content, "Expected Solution")
            end
        end
    end
end

println("\n" * "="^80)
println("RUNNING SYNTHESIS ON ALL BENCHMARKS (1M enumeration)")
println("="^80 * "\n")

# Run synthesis on each benchmark
for problem in PROBLEMS
    println("━" * repeat("━", 78) * "━")
    println("Problem: $problem")
    println("━" * repeat("━", 78) * "━")
    
    for difficulty in DIFFICULTIES
        spec_path = joinpath(@__DIR__, problem, "$difficulty.sl")
        solution_path = joinpath(@__DIR__, problem, "$difficulty.solution")
        
        println("\n  [$difficulty]")
        flush(stdout)
        
        try
            result = run_spec_synthesis(
                spec_path;
                max_depth=5,
                max_enumerations=1_000_000
            )
            
            grammar = CEGIS.build_grammar_from_spec(spec_path)
            solution_str = solution_to_string(result.program, grammar)
            
            # Save solution to file
            open(solution_path, "w") do f
                write(f, "Problem: $problem\n")
                write(f, "Difficulty: $difficulty\n")
                write(f, "Status: $(result.status)\n")
                write(f, "Iterations: $(result.iterations)\n")
                write(f, "Counterexamples: $(length(result.counterexamples))\n")
                write(f, "Solution: $solution_str\n")
            end
            
            println("    ✓ Solution: $solution_str")
            println("    ✓ Iterations: $(result.iterations)")
            println("    ✓ Counterexamples: $(length(result.counterexamples))")
            
        catch e
            error_str = sprint(showerror, e)
            
            # Save error to file
            open(solution_path, "w") do f
                write(f, "Problem: $problem\n")
                write(f, "Difficulty: $difficulty\n")
                write(f, "Status: ERROR\n")
                write(f, "Error: $(error_str)\n")
            end
            
            println("    ✗ ERROR: $(typeof(e).name)")
            println("    Details saved to $difficulty.solution")
        end
    end
    
    println()
end

println("="^80)
println("✅ Benchmark synthesis complete!")
println("="^80)
println("\nSolution files saved to benchmarks/{problem}/{difficulty}.solution")

