"""
oracle_synth.jl

Run from CEGIS/ directory:

    julia oracle_synth.jl

This script copies the core HerbSearch.synth structure and extends it with
oracle-driven CEGIS behavior:
- start from an empty IO problem,
- synthesize candidate programs,
- ask an AbstractOracle for a counterexample,
- add the counterexample to the synthesis spec,
- continue until verified.
"""

import Pkg

const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
Pkg.activate(_SCRIPT_ENV)

const _HERB_PKGS = [
    "HerbCore", "HerbGrammar", "HerbConstraints",
    "HerbInterpret", "HerbSearch", "HerbSpecification", "CEGIS",
]
let dev_dir = joinpath(homedir(), ".julia", "dev"),
    manifest = joinpath(_SCRIPT_ENV, "Manifest.toml")
    if !isfile(manifest) || filesize(manifest) < 200
        pkgs = [Pkg.PackageSpec(path=joinpath(dev_dir, p))
                for p in _HERB_PKGS if isdir(joinpath(dev_dir, p))]
        isempty(pkgs) || Pkg.develop(pkgs)
    end
end

using HerbCore
using HerbGrammar
using HerbConstraints
using HerbInterpret
using HerbSearch
using HerbSpecification

if !isdefined(Main, :CEGIS)
    include(joinpath(@__DIR__, "src", "CEGIS.jl"))
end
using .CEGIS

# Custom constraint type for IO examples
"""
    IOExampleConstraint <: AbstractLocalConstraint

A constraint that enforces a program must produce a specific output for a given input.
"""
struct IOExampleConstraint <: AbstractLocalConstraint
    input::Dict{Symbol, Any}
    expected_output::Any
end

"""
    create_io_constraint(cx::Counterexample)::IOExampleConstraint

Convert a counterexample to an IOExampleConstraint that can be posted to the solver.
"""
function create_io_constraint(cx::Counterexample)::IOExampleConstraint
    return IOExampleConstraint(cx.input, cx.expected_output)
end

"""
    check_io_constraint(program::RuleNode, grammar::AbstractGrammar, 
                       constraint::IOExampleConstraint, symboltable, mod)::Bool

Check if a program satisfies an IOExampleConstraint.
"""
function check_io_constraint(
    program::RuleNode,
    grammar::AbstractGrammar,
    constraint::IOExampleConstraint,
    symboltable,
    mod;
    allow_evaluation_errors::Bool = false
)::Bool
    expr = rulenode2expr(program, grammar)
    try
        problem = Problem(IOExample[IOExample(constraint.input, constraint.expected_output)])
        score = HerbSearch.evaluate(
            problem,
            expr,
            symboltable,
            shortcircuit = false,
            allow_evaluation_errors = allow_evaluation_errors,
        )
        return score == 1.0
    catch
        return false
    end
end

"""
    synth_with_oracle(grammar, start_symbol, oracle; ...)

Copied-from-synth style search loop with oracle integration.

Differences from HerbSearch.synth:
- keeps a mutable IO-example `Problem` initialized as empty,
- when a candidate fits current examples (`score == 1`), it is checked by the oracle,
- if oracle returns a counterexample, the spec is expanded and search restarts,
- if oracle returns nothing, synthesis succeeds.

Keyword arguments:
- `iterator_type::Symbol = :mh` — search strategy to use.
  Supported values: `:mh` (Metropolis-Hastings), `:sa` (Simulated Annealing),
  `:bfs` (breadth-first), `:dfs` (depth-first).
- `max_depth`, `max_time`, `max_enumerations` — search limits.
- `mod::Module` — module used for symbol table construction (so that
  grammar functions like `bvnot_cvc` can be resolved).
"""
function synth_with_oracle(
    grammar      :: AbstractGrammar,
    start_symbol :: Symbol,
    oracle       :: AbstractOracle;
    max_depth        :: Int = 5,
    max_time         :: Float64 = Inf,
    max_enumerations :: Int = 50_000,
    shortcircuit     :: Bool = true,
    allow_evaluation_errors :: Bool = false,
    mod::Module = Main,
    iterator_type :: Symbol = :mh,
)
    start_time = time()

    problem = Problem(IOExample[])
    counterexamples = Counterexample[]
    global_best_program = nothing
    global_best_satisfied = 0

    count_satisfied_examples(candidate_program::RuleNode)::Int = begin
        isempty(problem.spec) && return 0
        expr = rulenode2expr(candidate_program, grammar)
        score = HerbSearch.evaluate(
            problem,
            expr,
            grammar2symboltable(grammar, mod),
            shortcircuit = false,
            allow_evaluation_errors = allow_evaluation_errors,
        )
        return round(Int, score * length(problem.spec))
    end

    symboltable = grammar2symboltable(grammar, mod)
    
    # Safe evaluation function that handles errors gracefully.
    # Note: `expr` is typed as `Any` because rulenode2expr can return literals
    # (e.g. UInt64) as well as Expr objects, depending on the grammar.
    # The stochastic iterator also internally calls grammar2symboltable(grammar)
    # without the `mod` argument, so we ignore the `tab` it passes in and use
    # our own pre-built `symboltable` that was created with the correct module.
    safe_eval = (_tab, expr, input::Dict{Symbol, Any}) -> begin
        try
            return execute_on_input(symboltable, expr, input)
        catch e
            # Return NaN on evaluation error (missing function, runtime error, etc.)
            return NaN
        end
    end
    
    # Cost function for stochastic iterators (MH / SA).
    # Receives Vector of (expected, actual) tuples from all examples.
    # Returns numeric cost (lower is better).
    cost_fn = (results) -> begin
        cost = 0.0
        for (expected, actual) in results
            is_nan = try
                isnan(actual)
            catch
                false
            end
            if is_nan
                # Evaluation failed, high penalty
                cost += 1000.0
            else
                # Penalize incorrect outputs
                cost += (actual != expected) ? 1.0 : 0.0
            end
        end
        return cost
    end
    
    # Build iterator based on selected type.
    # Supported types:
    #   :mh  -> MHSearchIterator  (stochastic Metropolis-Hastings)
    #   :sa  -> SASearchIterator  (stochastic Simulated Annealing)
    #   :bfs -> BFSIterator       (exhaustive breadth-first search)
    #   :dfs -> DFSIterator       (exhaustive depth-first search)
    
    iterator = if iterator_type === :mh
        MHSearchIterator(
            grammar,
            start_symbol,
            problem.spec,
            cost_fn;
            max_depth=max_depth,
            initial_temperature=1.0,
            evaluation_function=safe_eval,
        )
    elseif iterator_type === :sa
        SASearchIterator(
            grammar,
            start_symbol,
            problem.spec,
            cost_fn;
            max_depth=max_depth,
            initial_temperature=1.0,
            evaluation_function=safe_eval,
        )
    elseif iterator_type === :bfs
        BFSIterator(grammar, start_symbol; max_depth=max_depth)
    elseif iterator_type === :dfs
        DFSIterator(grammar, start_symbol; max_depth=max_depth)
    else
        error("Unknown iterator_type $(repr(iterator_type)). Supported: :mh, :sa, :bfs, :dfs")
    end
    
    iter = 0
    num_enumerated_total = 0
    
    # ---- Copied synth core (search_procedure.jl) ----
    for candidate_program in iterator
        num_enumerated_total += 1
        
        if time() - start_time > max_time
            return (
                result = CEGISResult(CEGIS.cegis_timeout, global_best_program, iter, counterexamples),
                satisfied_examples = global_best_satisfied,
            )
        end
        
        # Log every 100000 enumerations
        if num_enumerated_total % 100000 == 0
            println("[enum=$num_enumerated_total] spec size=$(length(problem.spec))")
        end
        
        expr = rulenode2expr(candidate_program, grammar)

        score = if isempty(problem.spec)
            1.0
        else
            HerbSearch.evaluate(
                problem,
                expr,
                symboltable,
                shortcircuit = shortcircuit,
                allow_evaluation_errors = allow_evaluation_errors,
            )
        end

        if score == 1
            candidate_program = freeze_state(candidate_program)
            candidate_expr = rulenode2expr(candidate_program, grammar)
            
            # Log candidate program
            println("[enum=$num_enumerated_total] Found candidate: $candidate_expr")

            current_satisfied = count_satisfied_examples(candidate_program)
            if current_satisfied >= global_best_satisfied
                global_best_satisfied = current_satisfied
                global_best_program = candidate_program
            end

            # Check candidate against all posted IO constraints
            # violates_constraint = false

            # for constraint in get_state(solver).active_constraints
            #     if constraint isa IOExampleConstraint
            #         if !check_io_constraint(
            #             candidate_program,
            #             grammar,
            #             constraint,
            #             symboltable,
            #             mod,
            #             allow_evaluation_errors = allow_evaluation_errors,
            #         )
            #             violates_constraint = true
            #             break
            #         end
            #     end
            # end

            # if violates_constraint
            #     continue
            # end

            oracle_problem = CEGISProblem(
                grammar,
                start_symbol,
                problem.spec,
                (_candidate, _grammar) -> VerificationResult(CEGIS.verified, nothing),
            )
            cx = extract_counterexample(oracle, oracle_problem, candidate_program)

            if cx === nothing
                println("[enum=$num_enumerated_total] SUCCESS: Found candidate satisfying all examples!")
                return (
                    result = CEGISResult(CEGIS.cegis_success, candidate_program, iter, counterexamples),
                    satisfied_examples = current_satisfied,
                )
            end

            push!(counterexamples, cx)
            added_example = IOExample(cx.input, cx.expected_output)
            push!(problem.spec, added_example)
            
            iter += 1
            println("[iter=$iter] enum=$num_enumerated_total, Added IO counterexample, spec size now=$(length(problem.spec))")
            
            # Continue with next candidate
            continue
        end

        if num_enumerated_total > max_enumerations
            break
        end
    end
    # ---- End copied synth core ----

    println("[enum=$num_enumerated_total] iterator exhausted, aborting search")
    return (
        result = CEGISResult(CEGIS.cegis_failure, global_best_program, iter, counterexamples),
        satisfied_examples = global_best_satisfied,
    )
end

# -----------------------------------------------------------------------------
# Example usage
# -----------------------------------------------------------------------------
if abspath(PROGRAM_FILE) == @__FILE__
    grammar = @csgrammar begin
        Expr = x
        Expr = y
        Expr = 0
        Expr = 1
        Expr = Expr + Expr
        Expr = Expr - Expr
        Expr = Expr * Expr
    end

    start_symbol = :Expr

    held_out_examples = IOExample[
        IOExample(Dict{Symbol,Any}(:x => 1, :y => 2), 3),
        IOExample(Dict{Symbol,Any}(:x => 4, :y => 5), 9),
        IOExample(Dict{Symbol,Any}(:x => 10, :y => -3), 7),
        IOExample(Dict{Symbol,Any}(:x => 0, :y => 0), 0),
    ]

    oracle = IOExampleOracle(held_out_examples)

    synth_out = synth_with_oracle(grammar, start_symbol, oracle; max_depth = 5)
    result = synth_out.result
    satisfied_examples = synth_out.satisfied_examples

    if result.status == CEGIS.cegis_success
        println("Success in $(result.iterations) iteration(s)")
        println("Program: $(rulenode2expr(result.program, grammar))")
    elseif result.status == CEGIS.cegis_failure
        println("Failed after $(result.iterations) iteration(s)")
    else
        println("Timed out after $(result.iterations) iteration(s)")
    end

    println("Counterexamples collected: $(length(result.counterexamples))")
    println("Best satisfied examples: $satisfied_examples")
end
