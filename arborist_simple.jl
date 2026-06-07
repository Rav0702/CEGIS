"""
Simplified Arborist playground for quick experimentation.

Target: Find f(x) = x² (a quadratic function)

Modify this script to experiment with:
1. Different target functions (change y_train)
2. Different operators (add to fset)
3. Different population sizes and generations
4. Custom evaluators

Run: julia --project=. arborist_simple.jl
"""

using Arborist
using Random

Random.seed!(123)

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION — Modify these to experiment
# ══════════════════════════════════════════════════════════════════════════════

# Training data: change this to experiment with different target functions
x_data = Float32.([-5:1.0:5...])
y_data = x_data .^ 2  # Target: f(x) = x²

pop_size = 30
generations = 40
time_per_eval_ns = 500_000_000

# ══════════════════════════════════════════════════════════════════════════════

println("╔" * "═"^68 * "╗")
println("║ Arborist ExprGenome: Simple Program Synthesis Playground" * " "^11 * "║")
println("╚" * "═"^68 * "╝")
println()

# Describe the problem
println("Problem: Find a program that computes f(x) = x²")
println("Training data: x ∈ [-5, -4, ..., 4, 5]")
println("Population: $pop_size | Generations: $generations")
println()

# Create function set
fset = FunctionSet(Set{Arborist.FunctionDetails}())
Arborist.add!(fset, :+, 2, Float32, Float32)  # Addition
Arborist.add!(fset, :-, 2, Float32, Float32)  # Subtraction
Arborist.add!(fset, :*, 2, Float32, Float32)  # Multiplication

println("Available operators: +, -, *")
println()

# Prepare data for TableFitnessEvaluator
n = length(x_data)
input_rows = [Dict(:x => x_data[i]) for i in 1:n]
output_rows = [Dict(:y => y_data[i]) for i in 1:n]

evaluator = TableFitnessEvaluator(
    Dict(:x => Float32),              # Input columns
    Dict(:y => Float32),              # Output columns
    input_rows,
    output_rows;
    time_limit_ns=time_per_eval_ns
)

# Create and solve the problem
problem = GPProblem(
    evaluator,
    ExprGenome;
    function_set=fset,
    num_temps=1,  # Number of temp variables available
    seed=123
)

algorithm = GeneticProgramming(
    pop_size=pop_size,
    generations=generations,
    mutation_rate=0.3,
    crossover_rate=0.7,
    elitism=1
)

println("Evolving...")
result = solve(problem, algorithm; verbose=false)

println()
println("─"^70)
println("RESULT")
println("─"^70)
println()
println("Fitness: $(result.best_fitness) (higher is better)")
println("Complexity: $(Int(complexity(result.best_genome))) nodes")
println()

try
    expr_str = Arborist.serialize(result.best_genome)
    if length(expr_str) > 150
        println("Expression:")
        println(expr_str)
    else
        println("Expression: $expr_str")
    end
catch
    println("Expression: (could not serialize)")
end

println()
println("─"^70)
println("NEXT STEPS")
println("─"^70)
println()
println("To experiment, modify:")
println("  • y_data = ... (change target function)")
println("  • Arborist.add!(fset, ...) (add operators like :/ or custom functions)")
println("  • pop_size, generations (adjust evolution parameters)")
println()
println("To see evolve in real-time, add verbose=true to solve():")
println("  result = solve(problem, algorithm; verbose=true)")
println()
