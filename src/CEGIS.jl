"""
    CEGIS.jl
    =========

**Counterexample-Guided Inductive Synthesis** scaffold built on top of the
Herb.jl ecosystem.

Module structure
----------------

    CEGIS
    ├── types.jl          — Shared data types (CEGISProblem, Counterexample, …)
    ├── synthesizer.jl    — Synthesis component  (wraps HerbSearch.synth)
    ├── verifier.jl       — Verification component (oracle abstraction)
    ├── counterexample.jl — Counterexample management (minimize, generalize)
    └── learner.jl        — Constraint learning (updates grammar constraints)

The CEGIS loop (`run_cegis`) orchestrates these components.  See `pipeline.jl`
at the package root for a fully annotated pseudocode walkthrough.

Dependencies on Herb packages
------------------------------
| Component      | Herb package(s) used                                      |
|----------------|-----------------------------------------------------------|
| Grammar        | HerbGrammar (ContextSensitiveGrammar, @csgrammar, …)      |
| Program trees  | HerbCore   (RuleNode, AbstractHole, …)                    |
| Constraints    | HerbConstraints (AbstractGrammarConstraint, solvers, …)   |
| Interpretation | HerbInterpret  (execute_on_input, interpret, …)           |
| Search         | HerbSearch (ProgramIterator, synth, evaluate, …)          |
| Specification  | HerbSpecification (Problem, IOExample, SMTSpecification…) |
"""
module CEGIS

using HerbCore
using HerbGrammar
using HerbConstraints
using HerbInterpret
using HerbSearch
using HerbSpecification

# ── local includes (order matters: types first) ───────────────────────────────
include("types.jl")
include("synthesizer.jl")
include("verifier.jl")
include("counterexample.jl")
include("learner.jl")
include("cegis_loop.jl")     # core loop — depends on all of the above

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

export
    # Types
    CEGISProblem,
    CEGISResult,
    CEGISStatus,
    Counterexample,
    VerificationResult,
    VerificationStatus,

    # Main entry point
    run_cegis,

    # Synthesizer
    synthesize,
    build_iterator,
    update_problem_with_counterexample!,

    # Verifier
    verify,
    oracle_from_examples,
    oracle_from_smt,

    # Counterexample management
    counterexample_to_ioexample,
    minimize_counterexample,
    generalize_counterexample,
    is_duplicate_counterexample,

    # Learner
    learn_constraint,
    add_constraint_to_grammar!,
    reset_learned_constraints!,
    constraints_from_counterexamples

end # module CEGIS
