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
function run_cegis(
    problem  :: CEGISProblem;
    verbose  :: Bool = false,
    minimize :: Bool = false,
    learn    :: Bool = true,
) :: CEGISResult
    error("run_cegis is not yet implemented. " *
          "Follow the implementation skeleton in the docstring above.")
end
