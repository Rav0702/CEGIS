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

        # Check if we're using SemanticSMTOracle (which works with symbolic expressions)
        # For symbolic oracles, skip normal evaluation and go straight to verification
        is_semantic_oracle = string(typeof(oracle)) == "SemanticSMTOracle"
        
        score = if is_semantic_oracle
            # For SemanticSMTOracle, always score 1.0 (symbolic expressions are always "valid" structurally)
            # The oracle will verify correctness semantically
            1.0
        elseif isempty(problem.spec)
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

            # STANDARD CEGIS APPROACH:
            # 1. First check candidate against all accumulated IOExamples
            # 2. Only if it passes all, call the oracle for verification
            
            # Check candidate against all IOExamples in problem.spec
            passes_all_examples = true
            if !isempty(problem.spec)
                for io_example in problem.spec
                    try
                        result = HerbSearch.evaluate(
                            Problem(IOExample[io_example]),
                            candidate_expr,
                            symboltable,
                            shortcircuit = false,
                            allow_evaluation_errors = false,
                        )
                        if result != 1.0  # Doesn't satisfy this example
                            passes_all_examples = false
                            break
                        end
                    catch
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

            push!(counterexamples, cx)
            added_example = IOExample(cx.input, cx.expected_output)
            push!(problem.spec, added_example)
            
            println("[enum=$num_enumerated_total] Oracle counterexample: input=$(cx.input), expected=$(cx.expected_output)")
            
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
