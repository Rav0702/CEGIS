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

"""
    evaluate_symbolic_expr_on_example(expr, io_example::IOExample, sym_vars::Dict)

Evaluate a symbolic/mathematical expression against an IOExample.

For symbolic expressions from the grammar, this evaluates them by substituting
the input variables and checking if the result matches the expected output.

Returns true if the expression satisfies the example, false otherwise.
"""
function evaluate_symbolic_expr_on_example(expr, io_example::IOExample, sym_vars::Dict)
    try
        # Substitute input values into the expression
        substituted = Symbolics.substitute(expr, io_example.in)
        
        # Try to simplify and evaluate
        result = try
            Symbolics.simplify(substituted)
        catch
            substituted
        end
        
        # Convert result to comparable value
        result_value = if result isa Number
            result
        else
            try
                Float64(result)
            catch
                return false
            end
        end
        
        # Check if result matches expected output
        expected = io_example.out
        expected_value = if expected isa Number
            expected
        else
            try
                Float64(expected)
            catch
                return false
            end
        end
        
        # Use approximate equality for floats
        if result_value isa Float64 && expected_value isa Float64
            return abs(result_value - expected_value) < 1e-9
        else
            return result_value == expected_value
        end
    catch e
        return false
    end
end

"""
    synth_with_oracle(grammar, start_symbol, oracle; ...)

Synthesis loop with oracle-driven CEGIS behavior.

Differences from HerbSearch.synth:
- keeps a mutable IO-example `Problem` initialized as empty,
- when a candidate fits current examples (`score == 1`), it is checked by the oracle,
- if oracle returns a counterexample, the spec is expanded and search restarts,
- if oracle returns nothing, synthesis succeeds.
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
    mod::Module = Main
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

    solver = GenericSolver(grammar, start_symbol; max_depth=max_depth)
    iterator = BFSIterator(; solver=solver, max_depth=max_depth)
    
    iter = 0
    num_enumerated_total = 0
    symboltable = grammar2symboltable(grammar, mod)
    
    # ---- Copied synth core (search_procedure.jl) ----
    for candidate_program in iterator
        num_enumerated_total += 1
        
        # Check max_enumerations FIRST, before any continues that would bypass it
        if num_enumerated_total > max_enumerations
            println("[enum=$num_enumerated_total] Reached max_enumerations limit ($max_enumerations)")
            break
        end
        
        if time() - start_time > max_time
            return (
                result = CEGISResult(CEGIS.cegis_timeout, global_best_program, iter, counterexamples),
                satisfied_examples = global_best_satisfied,
            )
        end
        
        # Log every 10000 enumerations with candidate details
        if num_enumerated_total % 10000 == 0
            expr_log = rulenode2expr(candidate_program, grammar)
            println("[enum=$num_enumerated_total] checking: $expr_log | spec size=$(length(problem.spec))")
        end
        
        expr = rulenode2expr(candidate_program, grammar)

        # Evaluate candidate against accumulated IOExamples
        # Start with high score; will be reduced if examples fail
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
            # println("[enum=$num_enumerated_total] Found candidate: $candidate_expr")

            current_satisfied = count_satisfied_examples(candidate_program)
            if current_satisfied >= global_best_satisfied
                global_best_satisfied = current_satisfied
                global_best_program = candidate_program
            end

            # STANDARD CEGIS APPROACH:
            # 1. First check candidate against all accumulated IOExamples
            # 2. Only if it passes all, call the oracle for verification
            
            # For symbolic oracles, verify candidate against accumulated IOExamples
            # by substituting input values and checking outputs
            passes_all_examples = true
            if !isempty(problem.spec)
                for io_example in problem.spec
                    try
                        # Try to evaluate the candidate by substituting input values
                        # For symbolic expressions, use Symbolics.substitute and simplify
                        substituted = try
                            Symbolics.substitute(candidate_expr, io_example.in)
                        catch
                            # If substitution fails, try generic evaluation
                            try
                                symboltable_example = copy(symboltable)
                                for (var, val) in io_example.in
                                    symboltable_example[var] = val
                                end
                                eval(symboltable_example, candidate_expr)
                            catch
                                # If both fail, assume it doesn't satisfy the example
                                throw(ErrorException("Could not evaluate candidate"))
                            end
                        end
                        
                        # Simplify the result if possible
                        result_value = try
                            simplified = Symbolics.simplify(substituted)
                            if simplified isa Number
                                Float64(simplified)
                            else
                                Float64(simplified)
                            end
                        catch
                            Float64(substituted)
                        end
                        
                        # Compare with expected output
                        expected_value = if io_example.out isa Number
                            Float64(io_example.out)
                        else
                            io_example.out
                        end
                        
                        # Check equality (with some tolerance for floats)
                        is_equal = false
                        if result_value isa Float64 && expected_value isa Float64
                            is_equal = abs(result_value - expected_value) < 1e-9
                        else
                            is_equal = (result_value == expected_value)
                        end
                        
                        if !is_equal
                            passes_all_examples = false
                            break
                        end
                    catch
                        # If evaluation fails, assume example is not satisfied
                        passes_all_examples = false
                        break
                    end
                end
            end
            
            # If candidate fails any IOExample, skip Z3 oracle and continue to next candidate
            if !passes_all_examples
                continue
            end
            
            # Candidate passes all IOExamples - now call oracle for verification/counterexample search
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

            # Check if this counterexample input is already in the specification
            is_duplicate_input = false
            for existing_example in problem.spec
                if existing_example.in == cx.input
                    is_duplicate_input = true
                    println("[enum=$num_enumerated_total] SKIP: Counterexample input already in spec: $(cx.input)")
                    break
                end
            end
            
            # Only add if it's a new input
            if !is_duplicate_input
                push!(counterexamples, cx)
                added_example = IOExample(cx.input, cx.expected_output)
                push!(problem.spec, added_example)
                
                println("[enum=$num_enumerated_total] Oracle counterexample: input=$(cx.input), expected=$(cx.expected_output)")
                
                iter += 1
                println("[iter=$iter] enum=$num_enumerated_total, Added IO counterexample, spec size now=$(length(problem.spec))")
            else
                println("[enum=$num_enumerated_total] Duplicate counterexample ignored, continuing enumeration")
            end
            
            # Continue with next candidate
            continue
        end
    end
    # ---- End copied synth core ----

    if global_best_program !== nothing
        best_expr = rulenode2expr(global_best_program, grammar)
        println("[enum=$num_enumerated_total] Best program found: $best_expr (satisfied $global_best_satisfied examples)")
    else
        println("[enum=$num_enumerated_total] No candidate program found")
    end
    
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
