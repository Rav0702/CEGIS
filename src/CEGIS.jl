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
include("counterexample.jl")
include("oracle_synth.jl")     # Oracle-driven CEGIS synthesis loop

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
    counterexample_found,
    verification_error,
    AbstractOracle,
    IOExampleOracle,
    Z3Oracle,

    # Main entry points
    run_cegis,
    run_synthesis,
    synth_with_oracle,
    build_grammar_from_spec,
    check_desired_solution,

    # Counterexample management
    extract_counterexample,
    counterexample_to_ioexample,
    minimize_counterexample,
    generalize_counterexample,
    is_duplicate_counterexample

end # module CEGIS
