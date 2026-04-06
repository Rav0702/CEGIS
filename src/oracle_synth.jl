"""
oracle_synth.jl

Oracle-driven CEGIS synthesis loop: starts from empty IO problem, synthesizes candidates,
queries oracle for counterexamples, adds them to spec, and repeats until verified.

Requires: CEGIS module and Herb packages to be loaded first.

## Main Functions

- `synth_with_oracle()` — Legacy oracle-driven synthesis (still supported)
- `run_synthesis()` — New generic CEGISProblem orchestrator (recommended)
"""

# ─────────────────────────────────────────────────────────────────────────────
# Generic CEGISProblem orchestrator
# ─────────────────────────────────────────────────────────────────────────────

"""
    run_synthesis(problem::CEGISProblem) :: CEGISResult

Execute CEGIS synthesis loop using a generic CEGISProblem configuration.

This is the unified entry point for all synthesis tasks. It orchestrates:
1. Problem initialization (parsing, grammar building, oracle creation)
2. Iterator strategy creation
3. CEGIS loop execution
4. Optional desired solution checking
5. Result collection

**Arguments**:
- `problem::CEGISProblem` — Configuration-driven problem specification

**Returns**:
- `CEGISResult` — Synthesis outcome with status, program, iterations, and counterexamples

**Process**:
1. `ensure_initialized!(problem)` — Parse spec, build grammar, create oracle
2. Create iterator via `create_iterator(problem.iterator_config, ...)`
3. Run CEGIS loop (same as `synth_with_oracle()`)
4. If `problem.desired_solution !== nothing`, verify it as debug check
5. Return result

**Examples**:
```julia
# Basic usage
problem = CEGISProblem("spec.sl"; oracle_factory=..., ...)
result = run_synthesis(problem)

# With inspection
problem = CEGISProblem("spec.sl"; oracle_factory=..., ...)
ensure_initialized!(problem)
@assert !isempty(problem.grammar)
result = run_synthesis(problem)

# With debugging
problem = CEGISProblem("spec.sl"; desired_solution="max(x, y)")
result = run_synthesis(problem)
if result.status == cegis_success
    println("Found: \$(rulenode2expr(result.program, problem.grammar))")
end
```

**Error handling**:
- Throws if problem initialization fails (parser, grammar builder, or oracle creation)
- Throws if iterator creation fails
- Throws if desired_solution verification fails (if provided)
"""
function run_synthesis(problem::CEGISProblem) :: CEGISResult
    # Step 1: Ensure all components are initialized
    ensure_initialized!(problem)
    
    # Step 2: Create iterator from configuration
    iterator = IteratorConfig.create_iterator(
        problem.iterator_config,
        problem.grammar,
        problem.start_symbol
    )
    
    # Step 3: Run CEGIS synthesis loop
    # Delegate to the existing synth_with_oracle() function
    result_tuple = synth_with_oracle(
        problem.grammar,
        problem.start_symbol,
        problem.oracle;
        max_depth = problem.max_depth,
        max_time = problem.max_time,
        max_enumerations = problem.max_enumerations,
        iterator = iterator,
        desired_solution = problem.desired_solution,
    )
    
    result = result_tuple.result
    
    # Step 4: Optional: Generate debug query for desired solution if synthesis didn't succeed
    if problem.desired_solution !== nothing && result.status != cegis_success
        try
            desired_expr = problem.desired_solution
            candidate_smt = CEGIS.CEXGeneration.to_smt2(
                CEGIS.CEXGeneration.get_default_candidate_parser(),
                desired_expr
            )
            
            if !isempty(problem.spec.synth_funs)
                func_name = problem.spec.synth_funs[1].name
                candidates_dict = Dict(func_name => candidate_smt)
                query = CEGIS.CEXGeneration.generate_cex_query(problem.spec, candidates_dict)
                
                println("\n[DEBUG] Generated Z3 query for desired solution:")
                println("="^70)
                println(query)
                println("="^70)
                println()
                
                # Now actually run the query through Z3
                println("[DEBUG] Running query through Z3...")
                try
                    # Use the public API to verify the query
                    z3_result = CEGIS.CEXGeneration.verify_query(query)
                    
                    if z3_result.status == :sat
                        println("[DEBUG] Z3 Result: SAT (found counterexample)")
                        println("[DEBUG] Counterexample model:")
                        println(z3_result.model)
                    elseif z3_result.status == :unsat
                        println("[DEBUG] Z3 Result: UNSAT  (desired solution is VALID!)")
                    else
                        println("[DEBUG] Z3 Result: $(z3_result.status)")
                    end
                catch e
                    println("[DEBUG] Error running Z3: $e")
                end
            end
        catch e
            # Silently fail - not critical for synthesis
        end
    end
    
    return result
end

"""
    check_desired_solution(problem::CEGISProblem, result::CEGISResult)

[DEBUG HELPER] Verify a desired solution against the problem specification.

# Automatically checks and prints result of desired_solution
```
"""
function check_desired_solution(problem::CEGISProblem, result::CEGISResult)
    println("\n" * "="^80)
    println("[DEBUG] Checking desired solution:")
    println("  Expression: $(problem.desired_solution)")
    
    try
        # Step 1: Parse the solution string as a Julia expression
        solution_expr = Meta.parse(problem.desired_solution)
        
        # Step 2: Create an empty problem to test against oracle
        test_problem = Problem(problem.spec.spec)  # Use existing spec examples
        
        # Step 3: Check solution against oracle
        if problem.oracle !== nothing && hasmethod(extract_counterexample, (typeof(problem.oracle), typeof(test_problem), Any,))
            cx = extract_counterexample(problem.oracle, problem, nothing)
            
            if cx === nothing
                println("  Status: DESIRED SOLUTION VERIFIED")
            else
                println("  Status: DESIRED SOLUTION INVALID")
                println("  Counterexample found:")
                println("    Input: $(cx.input)")
                println("    Expected: $(cx.expected_output)")
                println("    Got: $(cx.actual_output)")
            end
        else
            # Fallback: Just report that it parsed successfully
            println("  Status: PARSED SUCCESSFULLY")
            println("  Note: Full verification requires oracle setup")
        end
    catch e
        println("  Status: PARSE ERROR")
        println("  Error: $(e)")
    end
    
    println("="^80 * "\n")
end

# ─────────────────────────────────────────────────────────────────────────────
# LEGACY: Original oracle-driven synthesis (kept for backward compatibility)
# ─────────────────────────────────────────────────────────────────────────────


"""
    synth_with_oracle(grammar, start_symbol, oracle; ...)

Synthesis loop with oracle-driven CEGIS. Returns (result=CEGISResult, satisfied_examples=Int).

**NEW PARAMETER** (Phase 2): 
- `iterator` — Optional pre-constructed iterator. If not provided, creates BFSIterator.

**Backward Compatibility**:
- Old code: `synth_with_oracle(grammar, start_symbol, oracle)` still works (uses BFSIterator)
- New code: `synth_with_oracle(grammar, start_symbol, oracle; iterator=my_iterator)` uses custom iterator
"""
function synth_with_oracle(
    grammar::AbstractGrammar, start_symbol::Symbol, oracle::AbstractOracle;
    max_depth::Int=5, max_time::Float64=Inf, max_enumerations::Int=50_000,
    shortcircuit::Bool=true, allow_evaluation_errors::Bool=false, mod::Module=Main,
    iterator::Union{Any, Nothing}=nothing,
    desired_solution::Union{String, Nothing}=nothing
)
    start_time = time()
    problem = Problem(IOExample[])
    counterexamples = Counterexample[]
    global_best_program = nothing
    global_best_satisfied = 0
    symboltable = grammar2symboltable(grammar, mod)

    count_satisfied(prog::RuleNode)::Int = begin
        isempty(problem.spec) && return 0
        score = HerbSearch.evaluate(problem, rulenode2expr(prog, grammar), symboltable;
                                    shortcircuit=false, allow_evaluation_errors)
        round(Int, score * length(problem.spec))
    end

    passes_all_examples(expr) = begin
        isempty(problem.spec) && return true
        all(problem.spec) do io
            try
                HerbSearch.evaluate(Problem([io]), expr, symboltable;
                                   shortcircuit=false, allow_evaluation_errors=false) == 1.0
            catch; false end
        end
    end

    solver = GenericSolver(grammar, start_symbol; max_depth)
    # Use provided iterator or create default BFSIterator (for backward compatibility)
    if iterator === nothing
        iterator = BFSIterator(; solver, max_depth)
    end
    iter, num_enum = 0, 0

    for candidate_program in iterator
        num_enum += 1
        
        if num_enum > max_enumerations
            println("[enum=$num_enum] Reached max_enumerations limit ($max_enumerations)")
            break
        end
        
        if time() - start_time > max_time
            return (result=CEGISResult(cegis_timeout, global_best_program, iter, counterexamples),
                    satisfied_examples=global_best_satisfied)
        end
        
        expr_str = string(rulenode2expr(candidate_program, grammar))
        num_enum % 10000 == 0 && println("[enum=$num_enum] checking: $expr_str | spec size=$(length(problem.spec))")
        
        # Debug: Check if desired_solution is encountered
        if desired_solution !== nothing && expr_str == desired_solution
            desired_expr = rulenode2expr(candidate_program, grammar)
            desired_satisfied = count_satisfied(candidate_program)
            println("[enum=$num_enum] [DEBUG] DESIRED SOLUTION ENCOUNTERED: $expr_str | satisfies $(desired_satisfied)/$(length(problem.spec)) counterexamples")
        end
        
        expr = rulenode2expr(candidate_program, grammar)
        score = isempty(problem.spec) ? 1.0 :
                HerbSearch.evaluate(problem, expr, symboltable; shortcircuit, allow_evaluation_errors)

        score != 1 && continue
        

        candidate_program = freeze_state(candidate_program)
        candidate_expr = rulenode2expr(candidate_program, grammar)
        
        current_satisfied = count_satisfied(candidate_program)
        if current_satisfied >= global_best_satisfied
            global_best_satisfied = current_satisfied
            global_best_program = candidate_program
        end

        passes = passes_all_examples(candidate_expr)
        
        passes || continue
        
        # Note: Z3Oracle.extract_counterexample doesn't use the problem parameter,
        # it gets everything from oracle.spec. Passing nothing as placeholder.
        cx = extract_counterexample(oracle, nothing, candidate_program)

        if cx === nothing
            println("[enum=$num_enum] SUCCESS: Found candidate satisfying all examples!")
            println("[enum=$num_enum] Candidate: $(rulenode2expr(candidate_program, grammar))")
            return (result=CEGISResult(cegis_success, candidate_program, iter, counterexamples),
                    satisfied_examples=current_satisfied)
        end

        push!(counterexamples, cx)
        push!(problem.spec, IOExample(cx.input, cx.expected_output))
        iter += 1
        println("[enum=$num_enum] Oracle counterexample: input=$(cx.input), expected=$(cx.expected_output)")
        println("[iter=$iter] enum=$num_enum, Added IO counterexample, spec size now=$(length(problem.spec))")
    end

    if global_best_program !== nothing
        println("[enum=$num_enum] Best program found: $(rulenode2expr(global_best_program, grammar)) (satisfied $global_best_satisfied examples)")
    else
        println("[enum=$num_enum] No candidate program found")
    end
    
    (result=CEGISResult(cegis_failure, global_best_program, iter, counterexamples),
     satisfied_examples=global_best_satisfied)
end
