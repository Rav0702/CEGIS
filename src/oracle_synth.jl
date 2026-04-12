"""
oracle_synth.jl

Oracle-driven CEGIS synthesis loop: starts from empty IO problem, synthesizes candidates,
queries oracle for counterexamples, adds them to spec, and repeats until verified.

Requires: CEGIS module and Herb packages to be loaded first.

## Main Functions

- `synth_with_oracle()` — Legacy oracle-driven synthesis (still supported)
- `run_synthesis()` — New generic CEGISProblem orchestrator (recommended)
"""

using Logging

# ─────────────────────────────────────────────────────────────────────────────
# Grammar building utility (external step in new workflow)
# ─────────────────────────────────────────────────────────────────────────────

"""
    build_grammar_from_spec(spec_path::String; grammar_config=nothing, start_symbol=:Expr)

Build a grammar from a SyGuS specification file for use with synthesizers.

This is a convenience utility for the external grammar-building step in the new
`run_synthesis()` workflow. It handles:
1. Parsing the specification file
2. Detecting the logic (LIA, BV, etc.)
3. Building an appropriate grammar
4. Returning the grammar for iterator creation

**Arguments**:
- `spec_path::String` — Path to .sl file (e.g., "benchmark.sl")

**Options**:
- `grammar_config` — GrammarConfig instance (default: auto-detect based on spec logic)
- `start_symbol::Symbol` — Start non-terminal for grammar (default: :Expr)

**Returns**:
- `AbstractGrammar` — Ready-to-use grammar for iterator creation

**Errors**: Propagates any errors from spec parsing or grammar building

**Example**:
```julia
# Build grammar once, reuse for multiple iterators
grammar = build_grammar_from_spec("benchmark.sl")

# Create multiple iterator strategies
bfs_iterator = create_iterator(BFSIteratorConfig(max_depth=5), grammar, :Expr)
dfs_iterator = create_iterator(DFSIteratorConfig(max_depth=7), grammar, :Expr)

# Use with run_synthesis
problem = CEGISProblem("benchmark.sl")
result_bfs = run_synthesis(problem, bfs_iterator)
result_dfs = run_synthesis(problem, dfs_iterator)
```

**See also**: run_synthesis(), create_iterator()
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

# ─────────────────────────────────────────────────────────────────────────────
# Generic CEGISProblem orchestrator
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# Unified run_synthesis API with Multiple Dispatch
# ─────────────────────────────────────────────────────────────────────────────

"""
    run_synthesis(problem::CEGISProblem, iterator::ProgramIterator; keywords...) :: CEGISResult

Execute CEGIS synthesis loop with oracle-driven verification.

This is the main entry point for CEGISProblem synthesis. It follows the same
signature as HerbSearch.synth() for consistency, with multiple dispatch handling
different problem types.

**Arguments**:
- `problem::CEGISProblem` — Problem specification (spec_path + optional desired_solution)
- `iterator::ProgramIterator` — Search strategy/iterator (e.g., BFSIterator, DFSIterator)

**Options**:
- `shortcircuit::Bool` — Stop evaluating after first failing example (default: true)
- `allow_evaluation_errors::Bool` — Continue synthesis even if evaluation raises error (default: false)
- `max_time::Float64` — Wall-clock time budget in seconds (default: Inf)
- `max_enumerations::Int` — Enumeration limit (default: typemax(Int))
- `mod::Module` — Module for custom function lookup (default: Main)
- `eval_fn::Union{Function, Nothing}` — Custom evaluation function for advanced use (default: nothing)

**Returns**:
- `CEGISResult` — Synthesis outcome (status, program, iterations, counterexamples)

**Process**:
1. Parse problem spec and create oracle (lazy initialization)
2. Run CEGIS loop with provided iterator
3. Return CEGISResult with synthesized program or best approximation

**Example**:
```julia
# Build components externally (clean separation of concerns)
problem = CEGISProblem("benchmark.sl"; desired_solution="max(x, y)")
grammar = build_grammar_from_spec("benchmark.sl")
iterator = create_iterator(BFSIteratorConfig(max_depth=5), grammar, :Expr)

# Run synthesis with unified API
result = run_synthesis(
    problem, iterator;
    max_enumerations = 1_000_000,
    max_time = 60.0
)

# Check result
if result.status == cegis_success
    println("Found: \$(rulenode2expr(result.program, grammar))")
else
    println("Best found: \$(rulenode2expr(result.program, grammar))")
end
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
    
    # Extract grammar from iterator (following HerbSearch convention)
    grammar = HerbSearch.get_grammar(iterator)
    start_symbol = HerbSearch.get_starting_symbol(iterator)
    
    # Create oracle from spec (lazy initialization)
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

"""
    run_synthesis(problem::Problem, iterator::ProgramIterator; keywords...) ::
        Union{Tuple{RuleNode, SynthResult}, Nothing}

Generic synthesis dispatcher for HerbSpecification.Problem types.

This method delegates to HerbSearch.synth() for non-CEGIS problems, providing
a unified API across CEGIS and standard synthesis workflows.

**Arguments**:
- `problem::Problem` — HerbSpecification problem with IO examples
- `iterator::ProgramIterator` — Search strategy

**Options**:
- `shortcircuit::Bool` — Stop after first failing example (default: true)
- `allow_evaluation_errors::Bool` — Continue on evaluation error (default: false)
- `max_time::Float64` — Time budget seconds (default: Inf)
- `max_enumerations::Int` — Enumeration limit (default: typemax(Int))
- `mod::Module` — Module for custom functions (default: Main)

**Returns**:
- `Tuple{RuleNode, SynthResult}` — Synthesized program and optimality flag
- `Nothing` — If no valid program found and options prevent returning suboptimal

**Example**:
```julia
using HerbSpecification, HerbSearch

# Standard HerbSearch workflow
spec = [IOExample(Dict(:x => 1, :y => 2), 2),
        IOExample(Dict(:x => 3, :y => 4), 7)]
problem = Problem(spec)
grammar = @csgrammar begin
    Expr = x | y | Expr + Expr | Expr - Expr | Expr * Expr
end
iterator = BFSIterator(solver=GenericSolver(grammar); max_depth=5)

# Can now use run_synthesis instead of synth
result = run_synthesis(problem, iterator)
```

**Note**: Returns None (not wrapped in CEGISResult) to match HerbSearch.synth() semantics.

**See also**: run_synthesis(::CEGISProblem, ::ProgramIterator), HerbSearch.synth()
"""
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

**[INTERNAL/LEGACY]** Synthesis loop with oracle-driven CEGIS. 

This function is kept for backward compatibility. **New code should use `run_synthesis()`**
which provides a unified API matching HerbSearch.synth().

For most users, prefer:
```julia
problem = CEGISProblem("spec.sl")
grammar = build_grammar_from_spec("spec.sl")  # external step
iterator = create_iterator(BFSIteratorConfig(max_depth=5), grammar, :Expr)  # external step
result = run_synthesis(problem, iterator; max_enumerations=10_000_000)  # unified API
```

**Legacy API** (deprecated, but still functional):
```julia
# Old way (not recommended)
result, satisfied = synth_with_oracle(grammar, start_symbol, oracle; max_depth=5, ...)
```

**Returns**: `(result=CEGISResult, satisfied_examples=Int)` — NamedTuple with synthesis result

**KeywordArguments**:
- `iterator` — Optional pre-constructed iterator. If not provided, creates BFSIterator.
- `desired_solution` — Optional target solution string for debug logging
- `eval_fn` — Optional custom evaluation function (for CustomInterpreterOracle)

**Backward Compatibility**:
- Old code: `synth_with_oracle(grammar, start_symbol, oracle)` still works (uses BFSIterator)
- New code: Use `run_synthesis(problem, iterator; ...)` instead

**Note**: `synth_with_oracle()` may be removed in a future major version. 
Use `run_synthesis()` for new code.

**See also**: run_synthesis(), CEGISProblem
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
