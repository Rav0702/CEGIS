#!/usr/bin/env julia
"""
Benchmark Suite Validation and Synthesis Script

Runs synthesis on all benchmark specifications using 1M enumeration,
saves solutions to files.

Also verifies known expected solutions against specs for debugging.
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

# Known expected solutions for debugging verification
const EXPECTED_SOLUTIONS = Dict(
    "max_two" => Dict(
        "easy" => "ifelse(x > y, x, y)",
        "medium" => "ifelse(x > y, x, y)",
        "hard" => "ifelse(x > y, x, y)",
    ),
    "abs_value" => Dict(
        "easy" => "ifelse(x >= 0, x, -(x))",
        "medium" => "ifelse(x >= 0, x, -(x))",
        "hard" => "ifelse(x >= 0, x, -(x))",
    ),
    "conditional_sum" => Dict(
        "easy" => "ifelse((x + y) >= 10, x + y, 0)",
        "medium" => "ifelse(and(x > 0, y > 0, (x + y) >= 15), x + y, ifelse(and(x > 0, y <= 0, x >= 7), x, ifelse(and(x <= 0, y > 0, y >= 7), y, 0)))",
        "hard" => "ifelse(and(x > 0, y > 0, z > 0, (x + y + z) > 20), x + y + z, ifelse(and(x > 0, y > 0, (x + y) > 15), x + y, ifelse(and(x > 0, x >= 10), x, ifelse(and(y > 0, y >= 10), y, ifelse(and(z > 0, z >= 10), z, 0)))))",
    ),
    "find_max_three" => Dict(
        "easy" => "ifelse(x >= y, ifelse(x >= z, x, z), ifelse(y >= z, y, z))",
        "medium" => "ifelse(x >= y, ifelse(x >= z, x, z), ifelse(y >= z, y, z))",
        "hard" => "ifelse(x >= y, ifelse(x >= z, x, z), ifelse(y >= z, y, z))",
    ),
    "sign_function" => Dict(
        "easy" => "ifelse(x > 0, 1, ifelse(x = 0, 0, -1))",
        "medium" => "ifelse(x > 0, 1, ifelse(x = 0, 0, -1))",
        "hard" => "ifelse(x > 0, 1, ifelse(x = 0, 0, -1))",
    ),
    "clamp_value" => Dict(
        "easy" => "ifelse(x < 0, 0, ifelse(x > 10, 10, x))",
        "medium" => "ifelse(x < min_val, min_val, ifelse(x > max_val, max_val, x))",
        "hard" => "ifelse(x < soft_min, soft_min, ifelse(x > soft_max, soft_max, ifelse(x < hard_min, hard_min, ifelse(x > hard_max, hard_max, x))))",
    ),
)

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
        cegis_result_path = joinpath(@__DIR__, problem, "$(difficulty)_cegis_result.solution")
        
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
            
            # Save synthesized result to cegis_result file
            open(cegis_result_path, "w") do f
                write(f, "Problem: $problem\n")
                write(f, "Difficulty: $difficulty\n")
                write(f, "Status: $(result.status)\n")
                write(f, "Iterations: $(result.iterations)\n")
                write(f, "Counterexamples: $(length(result.counterexamples))\n")
                write(f, "Solution: $solution_str\n")
            end
            
            println("    ✓ Synthesized: $solution_str")
            println("    ✓ Iterations: $(result.iterations)")
            println("    ✓ Counterexamples: $(length(result.counterexamples))")
            
        catch e
            error_str = sprint(showerror, e)
            
            # Save error to file
            open(cegis_result_path, "w") do f
                write(f, "Problem: $problem\n")
                write(f, "Difficulty: $difficulty\n")
                write(f, "Status: ERROR\n")
                write(f, "Error: $(error_str)\n")
            end
            
            println("    ✗ ERROR: $(typeof(e).name)")
            println("    Details saved to $(difficulty)_cegis_result.solution")
        end
    end
    
    println()
end

println("="^80)
println(" Benchmark synthesis complete!")
println("="^80)
println("\nSynthesis results saved to benchmarks/{problem}/{difficulty}_cegis_result.solution")

# Now verify expected solutions for debugging
println("\n" * "="^80)
println("VERIFYING EXPECTED SOLUTIONS AGAINST SPECS")
println("="^80 * "\n")

"""Verify a program against a spec using Z3. Returns (status_string, z3_result, model)."""
function verify_debug_solution_full(spec_file::String, program_str::String)
    try
        spec = CEGIS.CEXGeneration.parse_spec_from_file(spec_file)
        synth_func_name = spec.synth_funs[1].name
        candidates = Dict(synth_func_name => program_str)
        query = CEGIS.CEXGeneration.generate_cex_query(spec, candidates)
        z3_result = CEGIS.CEXGeneration.verify_query(query)
        
        if z3_result.status == :unsat
            return ("VERIFIED", z3_result, nothing)
        elseif z3_result.status == :sat
            return ("VIOLATED", z3_result, z3_result.model)
        else
            return ("UNKNOWN", z3_result, nothing)
        end
    catch e
        return ("ERROR: $(typeof(e).name)", nothing, nothing)
    end
end

"""Parse solution from file and extract the program string."""
function parse_solution_file(solution_path::String)::Union{String, Nothing}
    if !isfile(solution_path)
        return nothing
    end
    try
        content = open(solution_path) do f; read(f, String) end
        for line in split(content, "\n")
            if startswith(line, "Solution:")
                return strip(line[10:end])
            end
        end
    catch
        return nothing
    end
    return nothing
end

for problem in PROBLEMS
    if !haskey(EXPECTED_SOLUTIONS, problem)
        println("⚠ No expected solutions defined for $problem, skipping verification")
        continue
    end
    
    println("━" * repeat("━", 78) * "━")
    println("Problem: $problem")
    println("━" * repeat("━", 78) * "━")
    
    expected_sols = EXPECTED_SOLUTIONS[problem]
    
    for difficulty in DIFFICULTIES
        spec_path = joinpath(@__DIR__, problem, "$difficulty.sl")
        solution_path = joinpath(@__DIR__, problem, "$difficulty.solution")
        
        if !haskey(expected_sols, difficulty)
            println("\n  [$difficulty] No expected solution defined")
            continue
        end
        
        program_str = expected_sols[difficulty]
        println("\n  [$difficulty]")
        print("    Verifying: $program_str")
        flush(stdout)
        
        # Run Z3 verification
        status_str, z3_result, model = verify_debug_solution_full(spec_path, program_str)
        
        # Build verification details
        verification_details = ""
        if status_str == "VERIFIED"
            verification_details = "    ✓ VERIFIED: All constraints satisfied\n"
        elseif status_str == "VIOLATED"
            verification_details = "    ✗ VIOLATED: Found counterexample\n"
            if model !== nothing && !isempty(model)
                verification_details *= "      Counterexample model:\n"
                for (var, val) in model
                    verification_details *= "        $var = $val\n"
                end
            end
        else
            verification_details = "    ⚠ $status_str\n"
        end
        
        # Save debug solution file with full verification output
        open(solution_path, "w") do f
            write(f, "Problem: $problem\n")
            write(f, "Difficulty: $difficulty\n")
            write(f, "Type: DEBUG SOLUTION (Expected)\n")
            write(f, "Status: $status_str\n")
            write(f, "Solution: $program_str\n")
            write(f, "\n")
            write(f, "Verification Result:\n")
            write(f, "$verification_details")
            if z3_result !== nothing
                write(f, "Z3 Status: $(z3_result.status)\n")
                if !isempty(z3_result.model)
                    write(f, "Z3 Model:\n")
                    for (var, val) in z3_result.model
                        write(f, "  $var = $val\n")
                    end
                end
            end
        end
        
        print(verification_details)
    end
    
    println()
end

println("="^80)
println(" Verification complete!")
println("="^80)
println("\nExpected solutions verified and saved to benchmarks/{problem}/{difficulty}.solution")
println("Synthesis results saved to benchmarks/{problem}/{difficulty}_cegis_result.solution")

