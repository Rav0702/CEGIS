"""
oracle_synth.jl

Oracle-driven CEGIS synthesis loop: starts from empty IO problem, synthesizes candidates,
queries oracle for counterexamples, adds them to spec, and repeats until verified.

## Main Functions

- `synth_with_oracle()` — Legacy oracle-driven synthesis (still supported)
- `run_synthesis()` — New generic CEGISProblem orchestrator (recommended)
"""

using Logging

"""
    build_grammar_from_spec(spec_path::String; grammar_config=nothing, start_symbol=:Expr)

Build a grammar from a SyGuS specification file for use with synthesizers.

This is a convenience utility for the external grammar-building step in the new
`run_synthesis()` workflow. It handles:
1. Parsing the specification file
2. Detecting the logic (LIA, BV, etc.)
3. Building an appropriate grammar
4. Returning the grammar for iterator creation
"""
function build_grammar_from_spec(spec_path::String; grammar_config=nothing, start_symbol::Symbol=:Expr) :: AbstractGrammar
    # Step 1: Parse specification
    parser = Parsers.SyGuSParser()
    spec = Parsers.parse_spec(parser, spec_path)
    
    # Step 2: Determine grammar config (auto-detect if not provided)
    if grammar_config === nothing
        if GrammarBuilding.is_lia_problem(spec)
            grammar_config = GrammarBuilding.lia_grammar_config()
        else
            grammar_config = GrammarBuilding.default_grammar_config()
        end
    end
    
    # Step 3: Build and return grammar
    return GrammarBuilding.build_generic_grammar(spec, grammar_config)
end

"""
    run_synthesis(problem::CEGISProblem, iterator::ProgramIterator; keywords...) :: CEGISResult

Execute CEGIS synthesis loop with oracle-driven verification.

This is the main entry point for CEGISProblem synthesis. It follows the same
signature as HerbSearch.synth() for consistency, with multiple dispatch handling
different problem types.
```

**Differences from synth()**:
- CEGISProblem path returns CEGISResult (with iterations and counterexamples)
- Generic Problem path delegates to HerbSearch.synth() (returns Tuple{RuleNode, SynthResult})
- CEGISProblem path uses oracle for formal verification
- Generic Problem path uses specification examples for evaluation

**See also**: run_synthesis(::Problem, ::ProgramIterator), build_grammar_from_spec()
"""
function run_synthesis(
    problem::CEGISProblem,
    iterator::ProgramIterator;
    shortcircuit::Bool = true,
    allow_evaluation_errors::Bool = false,
    max_time::Float64 = Inf,
    max_enumerations::Int = typemax(Int),
    mod::Module = Main,
    eval_fn::Union{Function, Nothing} = nothing) :: CEGISResult
    
    # Extract grammar from iterator
    grammar = HerbSearch.get_grammar(iterator)
    start_symbol = HerbSearch.get_starting_symbol(iterator)
    
    # Create oracle from spec
    ensure_initialized!(problem, OracleFactories.create_oracle(
        OracleFactories.Z3OracleFactory(),
        problem.spec !== nothing ? problem.spec : Parsers.parse_spec(problem.spec_parser, problem.spec_path),
        grammar
    ))
    
    # Run CEGIS synthesis loop
    result_tuple = synth_with_oracle(
        grammar,
        start_symbol,
        problem.oracle;
        max_depth = HerbSearch.get_max_depth(iterator),
        max_time = max_time,
        max_enumerations = max_enumerations,
        shortcircuit = shortcircuit,
        allow_evaluation_errors = allow_evaluation_errors,
        mod = mod,
        iterator = iterator,
        desired_solution = problem.desired_solution,
        eval_fn = eval_fn,
    )
    
    return result_tuple.result
end

function run_synthesis(
    problem::Problem,
    iterator::ProgramIterator;
    shortcircuit::Bool = true,
    allow_evaluation_errors::Bool = false,
    max_time::Float64 = Inf,
    max_enumerations::Int = typemax(Int),
    mod::Module = Main) :: Union{Tuple{RuleNode, SynthResult}, Nothing}
    
    # Delegate to HerbSearch.synth()
    return HerbSearch.synth(
        problem,
        iterator;
        shortcircuit = shortcircuit,
        allow_evaluation_errors = allow_evaluation_errors,
        max_time = max_time,
        max_enumerations = max_enumerations,
        mod = mod
    )
end

# ─────────────────────────────────────────────────────────────────────────────
# LEGACY: Original oracle-driven synthesis (kept for backward compatibility)
# ─────────────────────────────────────────────────────────────────────────────


"""
    synth_with_oracle(grammar, start_symbol, oracle; ...)

Synthesis loop with oracle-driven CEGIS. 

**Returns**: `(result=CEGISResult, satisfied_examples=Int)` — NamedTuple with synthesis result

**KeywordArguments**:
- `iterator` — Optional pre-constructed iterator. If not provided, creates BFSIterator.
- `desired_solution` — Optional target solution string for debug logging
- `eval_fn` — Optional custom evaluation function (for CustomInterpreterOracle)
"""
function synth_with_oracle(
    grammar::AbstractGrammar, start_symbol::Symbol, oracle::AbstractOracle;
    max_depth::Int=5, max_time::Float64=Inf, max_enumerations::Int=50_000,
    shortcircuit::Bool=true, allow_evaluation_errors::Bool=false, mod::Module=Main,
    iterator::Union{Any, Nothing}=nothing,
    desired_solution::Union{String, Nothing}=nothing,
    eval_fn::Union{Function, Nothing}=nothing
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
            @debug "DESIRED SOLUTION ENCOUNTERED" num_enum expr=expr_str satisfied=desired_satisfied total=length(problem.spec)
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
