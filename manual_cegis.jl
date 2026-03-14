"""
manual_cegis.jl

Run from the CEGIS/ directory:

    julia manual_cegis.jl

On the first run it resolves and dev-links the local Herb packages into
CEGIS/.script_env/ — this takes a moment. Subsequent runs skip that step.
"""

import Pkg

const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
Pkg.activate(_SCRIPT_ENV)   # creates the dir if it doesn't exist


const _HERB_PKGS = [
    "HerbCore", "HerbGrammar", "HerbConstraints",
    "HerbInterpret", "HerbSearch", "HerbSpecification",
]
let dev_dir = joinpath(homedir(), ".julia", "dev"),
    manifest  = joinpath(_SCRIPT_ENV, "Manifest.toml")
    if !isfile(manifest) || filesize(manifest) < 200
        pkgs = [Pkg.PackageSpec(path=joinpath(dev_dir, p))
                for p in _HERB_PKGS if isdir(joinpath(dev_dir, p))]
        isempty(pkgs) || Pkg.develop(pkgs)
    end
end

using HerbCore           # RuleNode, AbstractRuleNode
using HerbGrammar        # @csgrammar, rulenode2expr, addconstraint!
using HerbConstraints    # Forbidden
using HerbInterpret      # execute_on_input
using HerbSearch         # BFSIterator, GenericSolver, freeze_state
using HerbSpecification  # IOExample

# 1. Grammar

grammar = @csgrammar begin
    Expr = x
    Expr = y
    Expr = 0
    Expr = 1
    Expr = Expr + Expr
    Expr = Expr - Expr
    Expr = Expr * Expr
    Expr = ifelse(Cond, Expr, Expr)

    Cond = Expr < Expr
    Cond = Expr == Expr
    Cond = !Cond
end

start_symbol = :Expr

# 2. Initial examples  (seed the synthesizer with at least one IO pair)

examples = IOExample[
    IOExample(Dict{Symbol,Any}(:x => 1, :y => 2), 3),
]

# 3. Helper: synthesize

function do_synthesize(grammar, start_symbol, examples; max_depth=5, max_enumerations=50_000)
    solver   = GenericSolver(grammar, start_symbol; max_depth=max_depth)
    ref      = Ref{Union{HerbConstraints.UniformSolver, Nothing}}(nothing)
    iterator = BFSIterator(; solver=solver, uniform_solver_ref=ref)
    symtab   = grammar2symboltable(grammar)
    for (i, candidate) in enumerate(iterator)
        i > max_enumerations && break
        expr = rulenode2expr(candidate, grammar)
        sat  = all(ex -> execute_on_input(symtab, expr, ex.in) == ex.out, examples)
        sat && return freeze_state(candidate)
    end
    return nothing
end

# 4. Helper: parse a number typed by the user

function read_number(prompt::String)
    while true
        print(prompt)
        raw = strip(readline())
        try
            return parse(Int, raw)
        catch
            println("  Not a valid integer, try again.")
        end
    end
end

# 5. Main interactive CEGIS loop

println("Interactive CEGIS loop (manual counterexample mode)")
println("Grammar variables: x, y  (integers)")
println("Type 'q' or 'quit' at any yes/no prompt to abort.\n")

max_iterations = 30

for iteration in 1:max_iterations
    println("\nIteration $iteration")

    # Synthesis
    candidate = do_synthesize(grammar, start_symbol, examples)

    if candidate === nothing
        println("Synthesis failed: no program satisfies all examples.")
        println("  Current examples: $(length(examples))")
        break
    end

    expr = rulenode2expr(candidate, grammar)
    println("Synthesized program : $expr")
    println("RuleNode            : $candidate")

    # Ask user
    print("\nIs this program correct for ALL inputs? [yes/no/quit]: ")
    answer = lowercase(strip(readline()))

    if answer in ("q", "quit", "exit")
        println("Aborted by user.")
        break
    end

    if answer in ("y", "yes")
        println("\nSynthesis succeeded in $iteration iteration(s).")
        println("  Final program: $expr")
        println("  RuleNode     : $candidate")
        exit(0)
    end

    # Collect counterexample
    println("\nProvide a counterexample (integer inputs for x and y, then the expected output).")
    x_val        = read_number("  x = ")
    y_val        = read_number("  y = ")
    expected_out = read_number("  expected output = ")

    # Evaluate what the candidate actually produces on this input
    symboltable = grammar2symboltable(grammar)
    actual_out  = try
        execute_on_input(symboltable, expr, Dict{Symbol,Any}(:x => x_val, :y => y_val))
    catch e
        println("  (evaluation error: $e — recording counterexample anyway)")
        nothing
    end

    println("  Candidate output : $actual_out  |  Expected: $expected_out")

    if actual_out == expected_out
        println("  Warning: the candidate actually gives the right answer on this input.")
        println("  Adding it to the spec anyway (your call).")
    end

    # Grow spec
    new_example = IOExample(Dict{Symbol,Any}(:x => x_val, :y => y_val), expected_out)
    push!(examples, new_example)
    println("  Spec now has $(length(examples)) example(s).")

    # Forbid current candidate — ensures the synthesizer cannot return the exact same program again,
    # even if it still satisfies all examples in the spec.
    addconstraint!(grammar, Forbidden(deepcopy(candidate)))
    println("  Forbidden constraint added for current candidate.")
end

println("\nLoop finished.")
