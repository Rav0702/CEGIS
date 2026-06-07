"""
Arborist.jl playground script for genetic programming experiments.

This script demonstrates Arborist's genetic programming framework with a simple
symbolic regression problem: evolve a program to compute f(x) = 2x + 1.

Run with: julia --project=. arborist_playground.jl
"""

using Arborist
using Random

# Seed for reproducibility
Random.seed!(42)

println("=" ^ 70)
println("Arborist.jl Playground — Program Synthesis via ExprGenome")
println("=" ^ 70)
println()

# ──────────────────────────────────────────────────────────────────────────────
# Example: ExprGenome (AST-based program synthesis)
# ──────────────────────────────────────────────────────────────────────────────

println("Example: ExprGenome (Julia AST-based program synthesis)")
println("-" ^ 70)

# Create training data for f(x) = 2x + 1
x_train = Float32.(collect(-5:1.0:5))
y_train = 2 .* x_train .+ 1

println("Target: f(x) = 2x + 1")
println("Training points: $(length(x_train))")
println("Sample data:")
for i in 1:min(5, length(x_train))
    println("  f($(x_train[i])) = $(y_train[i])")
end
println()

# Create function set for ExprGenome
fset = FunctionSet(Set{Arborist.FunctionDetails}())
Arborist.add!(fset, :+, 2, Float32, Float32)
Arborist.add!(fset, :-, 2, Float32, Float32)
Arborist.add!(fset, :*, 2, Float32, Float32)
Arborist.add!(fset, :/, 2, Float32, Float32)

println("Function set: +, -, *, /")
println()

# Create evaluator for ExprGenome using table format
# Map variable name to type: Dict(:x => Float32)
input_cols = Dict(:x => Float32)
output_cols = Dict(:y => Float32)

# Create input/output rows (each is a dict of variable → value)
n_samples = length(x_train)
input_rows = [Dict(:x => x_train[i]) for i in 1:n_samples]
output_rows = [Dict(:y => y_train[i]) for i in 1:n_samples]

evaluator = TableFitnessEvaluator(
    input_cols,
    output_cols,
    input_rows,
    output_rows;
    time_limit_ns=500_000_000  # 0.5 seconds per evaluation max
)

# Create the problem with ExprGenome
problem = GPProblem(
    evaluator,
    ExprGenome;
    function_set=fset,
    num_temps=2,  # Number of temporary variables available
    seed=42
)

# Configure the genetic algorithm
algorithm = GeneticProgramming(
    pop_size=20,
    generations=30,
    mutation_rate=0.3,
    crossover_rate=0.7,
    elitism=1
)

println("Genetic algorithm configuration:")
println("  Population size: 20")
println("  Generations: 30")
println("  Mutation rate: 0.3")
println("  Crossover rate: 0.7")
println()

println("Running genetic programming evolution...")
println("(This may take 30-60 seconds...)")
flush(stdout)

result = solve(problem, algorithm; verbose=false)

println("✓ Evolution complete!")
println()
println("Best solution found:")
println("  Fitness score: $(result.best_fitness)")
try
    expr_str = Arborist.serialize(result.best_genome)
    # Truncate if too long
    if length(expr_str) > 100
        println("  Expression: $(expr_str[1:97])...")
    else
        println("  Expression: $expr_str")
    end
catch
    println("  Expression: (could not serialize)")
end
println("  Complexity: $(Int(complexity(result.best_genome))) nodes")
println()

# ──────────────────────────────────────────────────────────────────────────────
# Additional Resources
# ──────────────────────────────────────────────────────────────────────────────

println()
println("=" ^ 70)
println("Next Steps & Exploration")
println("=" ^ 70)
println()
println("1. **Arborist Source Code**")
println("   Location: ~/.julia/dev/Arborist/")
println()
println("2. **Check Out the Examples**")
println("   - examples/feynman_regression.jl — Large symbolic regression benchmark")
println("   - examples/sorting.jl — Program synthesis (sorting algorithm evolution)")
println("   - examples/bin_packing.jl — NP-hard problem solving")
println()
println("3. **Genome Types Available in Arborist**")
println("   - TreeGenome — Expression trees (requires DynamicExpressions)")
println("   - ExprGenome — Julia AST programs (what we just used)")
println("   - GraphGenome — NEAT-style neural network topology evolution")
println("   - AntGenome — Agent control programs (artificial ant trail)")
println("   - ADFGenome — Automatically Defined Functions (Koza-style)")
println()
println("4. **Customization Ideas**")
println("   - Add more operators: sqrt, abs, sin, cos, etc.")
println("   - Change target function (try quadratic, cubic, etc.)")
println("   - Increase/decrease pop_size and generations")
println("   - Use different selection: TournamentSelection, LexicaseSelection")
println("   - Enable speciation for multi-objective optimization (NSGA-II)")
println()
println("5. **Evaluation Strategies**")
println("   - TableFitnessEvaluator — What we used (table input/output)")
println("   - TreeFitnessEvaluator — For numeric arrays (needs DynamicExpressions)")
println("   - Custom evaluator — Implement Arborist.AbstractEvaluator")
println()
println("Happy hacking! 🧬")
