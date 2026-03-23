"""
oracle_synth.jl

Oracle-driven CEGIS synthesis loop: starts from empty IO problem, synthesizes candidates,
queries oracle for counterexamples, adds them to spec, and repeats until verified.

Requires: CEGIS module and Herb packages to be loaded first.
"""

using HerbCore, HerbGrammar, HerbConstraints, HerbInterpret, HerbSearch, HerbSpecification

"""
    synth_with_oracle(grammar, start_symbol, oracle; ...)

Synthesis loop with oracle-driven CEGIS. Returns (result=CEGISResult, satisfied_examples=Int).
"""
function synth_with_oracle(
    grammar::AbstractGrammar, start_symbol::Symbol, oracle::AbstractOracle;
    max_depth::Int=5, max_time::Float64=Inf, max_enumerations::Int=50_000,
    shortcircuit::Bool=true, allow_evaluation_errors::Bool=false, mod::Module=Main
)
    start_time = time()
    problem = Problem(IOExample[])
    counterexamples = Counterexample[]
    global_best_program = nothing
    global_best_satisfied = 0
    symboltable = grammar2symboltable(grammar, mod)
    is_semantic_oracle = string(typeof(oracle)) == "SemanticSMTOracle"

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
    iterator = BFSIterator(; solver, max_depth)
    iter, num_enum = 0, 0

    for candidate_program in iterator
        num_enum += 1
        
        if num_enum > max_enumerations
            println("[enum=$num_enum] Reached max_enumerations limit ($max_enumerations)")
            break
        end
        
        if time() - start_time > max_time
            return (result=CEGISResult(CEGIS.cegis_timeout, global_best_program, iter, counterexamples),
                    satisfied_examples=global_best_satisfied)
        end
        
        num_enum % 10000 == 0 && println("[enum=$num_enum] checking: $(rulenode2expr(candidate_program, grammar)) | spec size=$(length(problem.spec))")
        
        expr = rulenode2expr(candidate_program, grammar)
        score = is_semantic_oracle || isempty(problem.spec) ? 1.0 :
                HerbSearch.evaluate(problem, expr, symboltable; shortcircuit, allow_evaluation_errors)

        score != 1 && continue
        
        candidate_program = freeze_state(candidate_program)
        candidate_expr = rulenode2expr(candidate_program, grammar)
        
        current_satisfied = count_satisfied(candidate_program)
        if current_satisfied >= global_best_satisfied
            global_best_satisfied = current_satisfied
            global_best_program = candidate_program
        end

        passes_all_examples(candidate_expr) || continue
        
        oracle_problem = CEGISProblem(grammar, start_symbol, problem.spec,
                                      (_, _) -> VerificationResult(CEGIS.verified, nothing))
        cx = extract_counterexample(oracle, oracle_problem, candidate_program)

        if cx === nothing
            println("[enum=$num_enum] SUCCESS: Found candidate satisfying all examples!")
            return (result=CEGISResult(CEGIS.cegis_success, candidate_program, iter, counterexamples),
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
    
    (result=CEGISResult(CEGIS.cegis_failure, global_best_program, iter, counterexamples),
     satisfied_examples=global_best_satisfied)
end
