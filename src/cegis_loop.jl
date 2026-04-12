"""
    CEGIS Core Loop
    ===============

Implements `run_cegis` — the main orchestrator that coordinates the four
components (synthesizer, verifier, counterexample manager, learner) in the
classic CEGIS feedback loop.

Loop invariant
--------------
After every iteration i, `problem.spec` contains the union of:
  - all original examples
  - all counterexamples c₁, …, cᵢ found so far (as `IOExample`s)

This guarantees that the synthesizer cannot return the same wrong program
twice (and thus the loop must terminate if the grammar is finite).

Control-flow diagram
--------------------

    ┌───────────────────────────────────────────────────────────────┐
    │                        run_cegis                              │
    │                                                               │
    │  problem, grammar, start_symbol                               │
    │         │                                                     │
    │         ▼                                                     │
    │  ┌─────────────┐    no program found                         │
    │  │  synthesize │ ──────────────────────────▶ cegis_failure    │
    │  └─────────────┘                                              │
    │         │ candidate::RuleNode                                 │
    │         ▼                                                     │
    │  ┌────────────┐    verified                                   │
    │  │   verify   │ ──────────────────────────▶ cegis_success     │
    │  └────────────┘                                               │
    │         │ counterexample_found                                │
    │         ▼                                                     │
    │  ┌──────────────────┐                                         │
    │  │ minimize_cx      │   (optional, can be disabled)           │
    │  └──────────────────┘                                         │
    │         │                                                     │
    │         ▼                                                     │
    │  ┌──────────────────┐                                         │
    │  │ is_duplicate?    │ ──yes──▶ cegis_failure (loop detected)  │
    │  └──────────────────┘                                         │
    │         │ no                                                  │
    │         ▼                                                     │
    │  ┌──────────────────┐                                         │
    │  │ learn_constraint │ ──▶ add_constraint_to_grammar!          │
    │  └──────────────────┘                                         │
    │         │                                                     │
    │         ▼                                                     │
    │  update_problem_with_counterexample!                          │
    │         │                                                     │
    │         └──────────────────────────────┐                      │
    │                                        │ next iteration       │
    │                            (check max_iterations / timeout)   │
    └───────────────────────────────────────────────────────────────┘
"""

"""
    run_cegis(problem; verbose, minimize, learn) -> CEGISResult

**[NOT IMPLEMENTED]**

Run the full CEGIS loop until a correct program is found, the search is
exhausted, or the budget is spent.

Arguments
---------
- `problem    :: CEGISProblem` — The synthesis task (grammar, start symbol,
  spec, oracle, budget limits).
- `verbose    :: Bool`         — Print progress to stdout if `true` (default: `false`).
- `minimize   :: Bool`         — Apply `minimize_counterexample` before
  incorporating each counterexample (default: `false`).
- `learn      :: Bool`         — Apply `learn_constraint` and
  `add_constraint_to_grammar!` after each counterexample (default: `true`).

Returns
-------
A `CEGISResult` with:
- `status`           — `cegis_success`, `cegis_failure`, or `cegis_timeout`.
- `program`          — Best `RuleNode` found, or `nothing`.
- `iterations`       — How many synthesize→verify rounds ran.
- `counterexamples`  — Full list of counterexamples accumulated.

Implementation skeleton
-----------------------
```julia
function run_cegis(problem; verbose=false, minimize=false, learn=true)
    start_time      = time()
    counterexamples = Counterexample[]
    iteration       = 0

    while iteration < problem.max_iterations
        # ── Budget check ──────────────────────────────────────────────────
        if time() - start_time > problem.max_time
            return CEGISResult(cegis_timeout, nothing, iteration, counterexamples)
        end

        iteration += 1
        verbose && @info "CEGIS round \$iteration"

        # ── Synthesis ─────────────────────────────────────────────────────
        current_problem = Problem(problem.name, problem.spec)
        candidate = synthesize(current_problem, problem.grammar, problem.start_symbol)
        if candidate === nothing
            return CEGISResult(cegis_failure, nothing, iteration, counterexamples)
        end
        verbose && @info "  Candidate found: \$(rulenode2expr(candidate, problem.grammar))"

        # ── Verification ──────────────────────────────────────────────────
        vresult = verify(candidate, problem.grammar, problem.oracle)

        if vresult.status == verified
            return CEGISResult(cegis_success, candidate, iteration, counterexamples)
        end

        if vresult.status == verification_error
            @warn "Oracle raised an error; stopping."
            return CEGISResult(cegis_failure, candidate, iteration, counterexamples)
        end

        # ── Counterexample handling ────────────────────────────────────────
        cx = vresult.counterexample
        verbose && @info "  Counterexample: \$(cx.input) → got \$(cx.actual_output), want \$(cx.expected_output)"

        # Optionally minimize
        if minimize
            cx = minimize_counterexample(cx, candidate, problem.grammar)
        end

        # Guard against duplicate counterexamples (loop detection)
        if is_duplicate_counterexample(cx, counterexamples)
            @warn "Duplicate counterexample detected; synthesis may have stalled."
            return CEGISResult(cegis_failure, candidate, iteration, counterexamples)
        end

        push!(counterexamples, cx)

        # ── Learning ──────────────────────────────────────────────────────
        if learn
            constraint = learn_constraint(cx, candidate, problem.grammar)
            add_constraint_to_grammar!(problem.grammar, constraint)
        end

        # ── Grow the specification ─────────────────────────────────────────
        update_problem_with_counterexample!(problem, cx)
    end

    return CEGISResult(cegis_timeout, nothing, iteration, counterexamples)
end
```

Participants
------------
- Calls : `synthesize`                       (synthesizer.jl)
- Calls : `verify`                           (verifier.jl)
- Calls : `minimize_counterexample`          (counterexample.jl)
- Calls : `is_duplicate_counterexample`      (counterexample.jl)
- Calls : `learn_constraint`                 (learner.jl)
- Calls : `add_constraint_to_grammar!`       (learner.jl)
- Calls : `update_problem_with_counterexample!` (synthesizer.jl)
- Returns: `CEGISResult`                     (types.jl)
"""

"""
    run_ioexample_cegis(grammar, start_symbol, oracle; ...) -> CEGISResult

Concrete CEGIS loop driven by an `IOExampleOracle`.

The loop starts with an empty synthesis problem (`Problem(IOExample[])`), then:
1. Synthesizes a candidate from the current examples.
2. Uses `extract_counterexample` to find the first failing held-out example.
3. Adds that counterexample as a new `IOExample` to the synthesis problem.
4. Repeats until verified or budget is exhausted.
"""
function run_ioexample_cegis(
    grammar       :: AbstractGrammar,
    start_symbol  :: Symbol,
    oracle        :: IOExampleOracle;
    max_iterations   :: Int = 100,
    max_depth        :: Int = 5,
    max_enumerations :: Int = 50_000,
    max_time         :: Float64 = Inf,
    verbose          :: Bool = false,
) :: CEGISResult
    start_time = time()
    spec = IOExample[]
    problem = Problem(spec)
    counterexamples = Counterexample[]

    for iteration in 1:max_iterations
        if time() - start_time > max_time
            return CEGISResult(cegis_timeout, nothing, iteration - 1, counterexamples)
        end

        solver = GenericSolver(grammar, start_symbol; max_depth = max_depth)
        iterator = BFSIterator(; solver = solver, max_depth = max_depth)

        synth_result = HerbSearch.synth(problem, iterator; max_enumerations = max_enumerations)
        if synth_result === nothing || synth_result[1] === nothing
            verbose && @info "[$iteration] No candidate found."
            return CEGISResult(cegis_failure, nothing, iteration, counterexamples)
        end

        candidate, _ = synth_result
        verbose && @info "[$iteration] Candidate: $(rulenode2expr(candidate, grammar))"

        # Create a dummy oracle_problem for extract_counterexample (backward compat with legacy code)
        oracle_problem = CEGISProblemLegacy(
            grammar,
            start_symbol,
            problem.spec,
            (_candidate, _grammar) -> VerificationResult(verified, nothing),
        )
        cx = extract_counterexample(oracle, oracle_problem, candidate)

        if cx === nothing
            verbose && @info "[$iteration] Verified: no counterexample found."
            return CEGISResult(cegis_success, candidate, iteration, counterexamples)
        end

        push!(counterexamples, cx)
        push!(problem.spec, IOExample(cx.input, cx.expected_output))

        verbose && @info "[$iteration] Added counterexample; spec size=$(length(problem.spec))."
    end

    return CEGISResult(cegis_timeout, nothing, max_iterations, counterexamples)
end

function run_cegis(
    problem  :: CEGISProblem;
    verbose  :: Bool = false,
    minimize :: Bool = false,
    learn    :: Bool = true,
) :: CEGISResult
    error("run_cegis is not yet implemented. " *
          "Follow the implementation skeleton in the docstring above.")
end
