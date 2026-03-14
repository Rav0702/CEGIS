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

Copied-from-synth style search loop with oracle integration.

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
    max_iterations   :: Int = 100,
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
        _, score = HerbSearch.evaluate(
            problem,
            expr,
            grammar2symboltable(grammar, mod),
            shortcircuit = false,
            allow_evaluation_errors = allow_evaluation_errors,
        )
        return round(Int, score * length(problem.spec))
    end

    for iter in 1:max_iterations
        if time() - start_time > max_time
            return (
                result = CEGISResult(CEGIS.cegis_timeout, global_best_program, iter - 1, counterexamples),
                satisfied_examples = global_best_satisfied,
            )
        end

        solver = GenericSolver(grammar, start_symbol; max_depth=max_depth)
        uniform_solver_ref = Ref{Union{HerbConstraints.UniformSolver, Nothing}}(nothing)
        iterator = BFSIterator(; solver=solver, uniform_solver_ref=uniform_solver_ref)

        # ---- Copied synth core (search_procedure.jl) ----
        local_round_start = time()
        symboltable = grammar2symboltable(grammar, mod)

        best_score = 0
        best_program = nothing
        found_counterexample = false
        println("[iter=$iter]")

        for (i, candidate_program) in enumerate(iterator)
            expr = rulenode2expr(candidate_program, grammar)

            score = if isempty(problem.spec)
                1.0
            else
                _, s = HerbSearch.evaluate(
                    problem,
                    expr,
                    symboltable,
                    shortcircuit = shortcircuit,
                    allow_evaluation_errors = allow_evaluation_errors,
                )
                s
            end

            if score == 1
                candidate_program = freeze_state(candidate_program)
                candidate_expr = rulenode2expr(candidate_program, grammar)
                println("[iter=$iter] candidate: $candidate_expr")

                current_satisfied = count_satisfied_examples(candidate_program)
                if current_satisfied >= global_best_satisfied
                    global_best_satisfied = current_satisfied
                    global_best_program = candidate_program
                end

                oracle_problem = CEGISProblem(
                    grammar,
                    start_symbol,
                    problem.spec,
                    (_candidate, _grammar) -> VerificationResult(CEGIS.verified, nothing),
                )
                cx = extract_counterexample(oracle, oracle_problem, candidate_program)

                if cx === nothing
                    return (
                        result = CEGISResult(CEGIS.cegis_success, candidate_program, iter, counterexamples),
                        satisfied_examples = current_satisfied,
                    )
                end

                push!(counterexamples, cx)
                added_example = IOExample(cx.input, cx.expected_output)
                push!(problem.spec, added_example)

                println("[iter=$iter] added IO counterexample: in=$(added_example.in), out=$(added_example.out), candidate_out=$(cx.actual_output), spec size=$(length(problem.spec))")
                found_counterexample = true
                break
            elseif score >= best_score
                best_score = score
                best_program = freeze_state(candidate_program)

                current_satisfied = count_satisfied_examples(best_program)
                if current_satisfied >= global_best_satisfied
                    global_best_satisfied = current_satisfied
                    global_best_program = best_program
                end
            end

            if i > max_enumerations || time() - local_round_start > max_time
                break
            end
        end
        # ---- End copied synth core ----

        if found_counterexample
            continue
        end

        if best_program === nothing
            return (
                result = CEGISResult(CEGIS.cegis_failure, global_best_program, iter, counterexamples),
                satisfied_examples = global_best_satisfied,
            )
        end
    end

    return (
        result = CEGISResult(CEGIS.cegis_timeout, global_best_program, max_iterations, counterexamples),
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

    synth_out = synth_with_oracle(grammar, start_symbol, oracle; max_iterations = 20, max_depth = 5)
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
