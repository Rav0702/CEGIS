"""
Run from the CEGIS/ directory:

    julia smt_cegis.jl
"""

import Pkg

const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
const _MANIFEST    = joinpath(_SCRIPT_ENV, "Manifest.toml")

_needs_setup() = !isfile(_MANIFEST) ||
                 !any(contains("ConflictAnalysis.jl"), eachline(_MANIFEST))

if _needs_setup()
    isdir(_SCRIPT_ENV) && rm(_SCRIPT_ENV; recursive=true)
    mkpath(_SCRIPT_ENV)
end

Pkg.activate(_SCRIPT_ENV)

if _needs_setup()
    dev_dir = joinpath(homedir(), ".julia", "dev")
    pkg_dirs = Dict(
        "HerbCore"         => "HerbCore",
        "HerbGrammar"      => "HerbGrammar",
        "HerbConstraints"  => "HerbConstraints",
        "HerbInterpret"    => "HerbInterpret",
        "HerbSearch"       => "HerbSearch",
        "HerbSpecification"=> "HerbSpecification",
        "ConflictAnalysis" => "ConflictAnalysis.jl",
    )
    pkgs = [Pkg.PackageSpec(path=joinpath(dev_dir, dir))
            for (_, dir) in pkg_dirs if isdir(joinpath(dev_dir, dir))]
    isempty(pkgs) || Pkg.develop(pkgs)
end

using HerbCore
using HerbGrammar
using HerbConstraints
using HerbInterpret
using HerbSearch
using HerbSpecification
import ConflictAnalysis

grammar = @csgrammar begin
    Expr = x
    Expr = y
    Expr = (0            := (y == 0))
    Expr = (1            := (y == 1))
    Expr = (Expr + Expr  := (y == x1 + x2))
    Expr = (Expr - Expr  := (y == x1 - x2))
    Expr = (Expr * Expr  := (y == x1 * x2))
    Expr = ifelse(Cond, Expr, Expr)
    Cond = Expr < Expr
    Cond = Expr == Expr
    Cond = !Cond
end

start_symbol = :Expr

# 2. Initial examples

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

# 4. Helper: parse a number

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

# 5. SMT-LIB display via ConflictAnalysis.infer_spec
#
# infer_spec(candidate, grammar, example) -> SpecModel
#   .bank        : maps abstract sub-expressions to SMT variable names (eN)
#   .cons_id_map : named structural constraints derived from grammar := specs
#   .assigns     : concrete value assertions from example inputs/output
#
# smt_vars       -> "(declare-fun eN () Int)" lines
# smt_translate_cons -> "(assert (! (...) :named C_k_j))" lines
# smt_assigns    -> "(assert (= eN value))" lines

function print_smt_for_example(candidate, grammar, ex::IOExample, idx::Int)
    model = ConflictAnalysis.infer_spec(candidate, grammar, ex)

    println("; Example $idx: $(ex.in) -> $(ex.out)")

    print(ConflictAnalysis.smt_vars(model.bank))

    cons_smt = ConflictAnalysis.smt_translate_cons(model.cons_id_map)
    isempty(strip(cons_smt)) ?
        println("; (no structural constraints for this candidate)") :
        print(cons_smt)

    assigns_smt = ConflictAnalysis.smt_assigns(model.assigns)
    isempty(strip(assigns_smt)) ?
        println("; (no value assignments — rule may lack a semantic spec)") :
        print(assigns_smt)

    println("(check-sat)")
    println("; sat   = consistent (no MUC conflict on this example)")
    println("; unsat = conflict detected, MUC would extract the unsatisfiable core")
    println()
end

function print_smt_spec(candidate, grammar, examples)
    println()
    println("; SMT-LIB 2 via ConflictAnalysis.infer_spec")
    println("; Candidate : $(rulenode2expr(candidate, grammar))")
    println("; RuleNode  : $candidate")
    println()
    println("(set-logic QF_LIA)")
    println("(set-option :produce-unsat-cores true)")
    println()
    for (i, ex) in enumerate(examples)
        print_smt_for_example(candidate, grammar, ex, i)
    end
end

# 6. Main interactive CEGIS loop

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

    # Print SMT spec
    print_smt_spec(candidate, grammar, examples)

    # Ask user
    print("Is this program correct for ALL inputs? [yes/no/quit]: ")
    answer = lowercase(strip(readline()))

    if answer in ("q", "quit")
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

    # Forbid current candidate
    addconstraint!(grammar, Forbidden(deepcopy(candidate)))
    println("  Forbidden constraint added for current candidate.")
end

println("\nLoop finished.")
