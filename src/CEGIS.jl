module CEGIS

using HerbCore
using HerbGrammar
using HerbConstraints
using HerbInterpret
using HerbSearch
using HerbSpecification

# ── local includes (order matters: types first) ───────────────────────────────
include("types.jl")
include("CEXGeneration/CEXGeneration.jl") # CEXGeneration module (needed by Z3Oracle)
include("Oracles/Oracles.jl") # Oracle implementations & abstract interface (must be before OracleFactories)
include("Parsers/Parsers.jl") # Spec parsers (extensible)
include("GrammarBuilding/GrammarBuilding.jl") # Grammar configuration and building
include("OracleFactories/OracleFactories.jl") # Oracle factory pattern (uses AbstractOracle)
include("IteratorConfig/IteratorConfig.jl") # Iterator configuration
include("synthesizer.jl")
include("verifier.jl")
include("counterexample.jl")
include("learner.jl")
include("oracle_synth.jl")     # Oracle-driven CEGIS synthesis loop
include("cegis_loop.jl")     # core loop — depends on all of the above

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

export
    # Support modules (extensible architecture)
    CEXGeneration,
    Parsers,
    GrammarBuilding,
    OracleFactories,
    IteratorConfig,
    
    # Types
    CEGISProblem,
    CEGISResult,
    CEGISStatus,
    cegis_success,
    cegis_failure,
    cegis_timeout,
    Counterexample,
    VerificationResult,
    VerificationStatus,
    verified,
    verification_failed,
    verification_error,
    AbstractOracle,
    IOExampleOracle,
    Z3Oracle,

    # Main entry point
    run_cegis,
    run_ioexample_cegis,

    # Synthesizer
    synthesize,
    build_iterator,
    update_problem_with_counterexample!,

    # Verifier
    verify,
    extract_counterexample,
    oracle_from_examples,
    oracle_from_smt,

    # Oracle-driven synthesis
    synth_with_oracle,
    run_synthesis,
    check_desired_solution,

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
