"""
Arborist (GA) over Herb's internal program representation — minimal demo.

Herb represents programs as `RuleNode` trees over a grammar; `rulenode2expr`
turns a tree into the Julia `Expr` Herb interprets. 

  • genome      — `RuleNodeGenome` (a `RuleNode` + its grammar), already defined
                  in CEGIS.GeneticSearch; `serialize` = `rulenode2expr` string.
  • operators   — `GrammarSubtreeMutation` / `GrammarSubtreeCrossover`: typed,
                  grammar-valid subtree edits reused from CEGIS.GeneticSearch.
  • fitness     — a tiny IO-example evaluator (NO Z3): fitness = number of
                  examples the program gets wrong (lower is better; 0 = solved).
  • population  — Arborist's `solve` calls the `_initialize_population` method
                  defined for `RuleNodeGenome`, which samples random trees with
                  Herb's `rand(RuleNode, grammar, symbol, depth)`.

Target: f(a, b) = max(a, b).

Run: julia --project=. arborist_herb_demo.jl
"""

using CEGIS
using CEGIS.GeneticSearch
using HerbCore, HerbGrammar, HerbInterpret
import Arborist
using Random

Random.seed!(1)

grammar = @csgrammar begin
    Expr     = a | b                        
    Expr     = Expr + Expr
    Expr     = Expr - Expr
    Expr    = Expr * Expr
    Expr    = Expr / Expr
    Expr     = ifelse(BoolExpr, Expr, Expr)
    BoolExpr = Expr < Expr
    BoolExpr = Expr > Expr
end
const START   = :Expr
const SYMTAB  = grammar2symboltable(grammar, Main)

const EXAMPLES = [
    (Dict{Symbol,Any}(:a => a, :b => b), max(a, b))
    for a in -3:3 for b in -3:3
]


struct IOExampleEvaluator <: Arborist.AbstractEvaluator
    grammar::AbstractGrammar
    start_symbol::Symbol
    max_depth::Int
end

Arborist.input_signature(::IOExampleEvaluator)  = Dict{Symbol,DataType}(:a => Int, :b => Int)
Arborist.output_signature(::IOExampleEvaluator) = Dict{Symbol,DataType}(:out => Int)

function Arborist.evaluate_genome(g::RuleNodeGenome, ::IOExampleEvaluator)::Float64
    expr = rulenode2expr(g.tree, grammar)
    wrong = 0
    for (input, expected) in EXAMPLES
        out = try
            execute_on_input(SYMTAB, expr, input)
        catch
            return Inf
        end
        out == expected || (wrong += 1)
    end
    return Float64(wrong)
end

evaluator = IOExampleEvaluator(grammar, START, 4)

problem = Arborist.GPProblem(evaluator, RuleNodeGenome; seed=1)
algorithm = Arborist.GeneticProgramming(
    pop_size      = 60,
    generations   = 40,
    elitism       = 2,
    mutation_rate = 0.6,
    crossover_rate= 0.3,
    bloat_penalty = 1e-3,
    selection     = Arborist.TournamentSelection(3),
    mutation_ops  = Arborist.AbstractMutationOperator[
        GrammarSubtreeMutation(grammar, 3, 6),
    ],
    crossover_ops = Arborist.AbstractCrossoverOperator[
        GrammarSubtreeCrossover(grammar, 6),
    ],
    parallel      = false,
)

println("="^70)
println("Arborist GA over Herb RuleNode/Expr — target: max(a, b)")
println("="^70)
println("grammar rules : ", length(grammar.rules))
println("IO examples   : ", length(EXAMPLES))
println()

callback = (gen, best_fitness, best) -> gen % 5 == 0 &&
    println("  [gen $gen] best fitness = $(round(best_fitness, digits=4)) : $(Arborist.serialize(best))")

result = Arborist.solve(problem, algorithm; verbose=false, callback=callback)

println()
println("─"^70)
best = result.best_genome
println("best program  : ", rulenode2expr(best.tree, grammar))
println("best fitness  : ", round(result.best_fitness, digits=4), "  (0 -> all examples correct)")
println("complexity    : ", Int(Arborist.complexity(best)), " nodes")
println("─"^70)

