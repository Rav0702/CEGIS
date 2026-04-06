"""
    CEGIS Types
    ===========

This file defines the core types used throughout the CEGIS loop. All components
of the pipeline — synthesizer, verifier, counterexample generator, and learner —
communicate through these shared types.

Dependency graph:
    CEGISProblem ──▶ Synthesizer ──▶ SynthesisResult
                         ▲
    Counterexample ──────┘
    (from verifier feedback)

    Verifier ──▶ VerificationResult ─── if ¬verified ──▶ Counterexample
"""

# ─────────────────────────────────────────────────────────────────────────────
# Result enumerations
# ─────────────────────────────────────────────────────────────────────────────

"""
    @enum CEGISStatus

Possible terminal outcomes of a full CEGIS run.

| Value            | Meaning                                                  |
|------------------|----------------------------------------------------------|
| `cegis_success`  | A program satisfying all constraints was found.          |
| `cegis_failure`  | The search space was exhausted without success.          |
| `cegis_timeout`  | The loop hit the user-supplied time / iteration limit.   |
"""
@enum CEGISStatus begin
    cegis_success = 1
    cegis_failure = 2
    cegis_timeout = 3
end

"""
    @enum VerificationStatus

Result returned by the oracle / verifier after checking a candidate program.

| Value                  | Meaning                                       |
|------------------------|-----------------------------------------------|
| `verified`             | Program is correct on all inputs.             |
| `counterexample_found` | Oracle found an input that falsifies program. |
| `verification_error`   | The verifier raised an internal exception.    |
"""
@enum VerificationStatus begin
    verified            = 1
    counterexample_found = 2
    verification_error  = 3
end

# ─────────────────────────────────────────────────────────────────────────────
# Counterexample
# ─────────────────────────────────────────────────────────────────────────────

"""
    struct Counterexample

An input/output witness that shows why a candidate program is wrong.

Fields
------
- `input  :: Dict{Symbol, Any}` — Variable bindings fed to the program.
- `expected_output :: Any`      — The output the oracle deems correct.
- `actual_output   :: Any`      — The (wrong) output the candidate produced.

Relationship to Herb types
--------------------------
A `Counterexample` is converted to a `HerbSpecification.IOExample` before it is
added to the growing example set that drives the synthesizer in the next round:

    IOExample(cx.input, cx.expected_output)

See also: `HerbSpecification.IOExample`, `HerbSpecification.Problem`.
"""
struct Counterexample
    input           :: Dict{Symbol, Any}
    expected_output :: Any
    actual_output   :: Any
end

# ─────────────────────────────────────────────────────────────────────────────
# Verification result
# ─────────────────────────────────────────────────────────────────────────────

"""
    struct VerificationResult

Encapsulates the answer returned by the oracle after checking a candidate.

Fields
------
- `status          :: VerificationStatus` — Outcome of verification.
- `counterexample  :: Union{Counterexample, Nothing}` — Populated only when
  `status == counterexample_found`.

Produced by: [`verify`](@ref) in `verifier.jl`.
Consumed by: the main CEGIS loop in `pipeline.jl` and by
             [`generate_counterexample`](@ref) in `counterexample.jl`.
"""
struct VerificationResult
    status         :: VerificationStatus
    counterexample :: Union{Counterexample, Nothing}
end

# ─────────────────────────────────────────────────────────────────────────────
# CEGIS problem specification (OLD - kept for backward compatibility)
# ─────────────────────────────────────────────────────────────────────────────

"""
    struct CEGISProblem (LEGACY)

A self-contained description of a CEGIS synthesis task.

This is the original CEGISProblem type. It remains here for backward compatibility.

**DEPRECATED**: For new code, use the new generic CEGISProblem with extensible
configuration. The new type supports pluggable spec parsers, oracle factories,
and iterator strategies.

Fields (Legacy)
------
- `grammar      :: AbstractGrammar`      — The context-sensitive grammar that
  defines the program space.  Created with `HerbGrammar.@csgrammar`.
- `start_symbol :: Symbol`               — Non-terminal to start synthesis from
  (e.g. `:Program`, `:Expr`).
- `spec         :: AbstractSpecification`— Initial specification.  In the IO
  setting this is `Vector{IOExample}`.  Grows each round with new
  `Counterexample`s converted to `IOExample`s.
- `oracle       :: Function`             — A callable `(program::RuleNode,
  grammar::AbstractGrammar) -> VerificationResult` that acts as the verifier.
  Can wrap an SMT solver, a type-checker, or an exhaustive tester.
- `max_iterations :: Int`                — Hard cap on the number of
  synthesize → verify rounds (default 100).
- `max_time      :: Float64`             — Wall-clock time budget in seconds
  (default `Inf`).

See also: CEGISProblemGeneric (new architecture)
"""
mutable struct CEGISProblemLegacy
    grammar         :: AbstractGrammar
    start_symbol    :: Symbol
    spec            :: AbstractSpecification
    oracle          :: Function
    max_iterations  :: Int
    max_time        :: Float64
end

"""
    CEGISProblemLegacy(grammar, start_symbol, spec, oracle)

Convenience constructor with default limits (100 iterations, no time limit).

**DEPRECATED**: Use CEGISProblem with new extensible API instead.
"""
function CEGISProblemLegacy(
    grammar      :: AbstractGrammar,
    start_symbol :: Symbol,
    spec         :: AbstractSpecification,
    oracle       :: Function,
)
    return CEGISProblemLegacy(grammar, start_symbol, spec, oracle, 100, Inf)
end

# ─────────────────────────────────────────────────────────────────────────────
# CEGIS problem specification (NEW - Extensible generic version)
# ─────────────────────────────────────────────────────────────────────────────

"""
    mutable struct CEGISProblem

Generic, configuration-driven CEGIS problem specification.

This new CEGISProblem type replaces the rigid legacy version with a fully
extensible architecture supporting:
- Multiple specification formats (SyGuS, JSON, YAML, custom DSLs)
- Pluggable oracle selection (Z3, test-based, custom verifiers)
- Configurable search strategies (BFS, DFS, random, custom iterators)
- Debug support with optional desired solution checking

**Configuration Fields**:
- `spec_path                 :: String`  — Path to specification file
- `spec_parser              :: AbstractSpecParser` — Parser for spec format
- `grammar_config           :: GrammarConfig` — Grammar configuration
- `oracle_factory           :: AbstractOracleFactory` — Oracle factory
- `iterator_config          :: AbstractSynthesisIterator` — Iterator strategy
- `desired_solution         :: Union{String, Nothing}` — (NEW) Optional target solution for debugging

**Synthesis Parameters**:
- `start_symbol             :: Symbol` — Start non-terminal (default: :Expr)
- `max_depth                :: Int` — Maximum program depth (default: 5)
- `max_enumerations         :: Int` — Enumeration limit (default: 50_000)
- `max_time                 :: Float64` — Time budget in seconds (default: Inf)
- `max_iterations           :: Int` — CEGIS rounds limit (default: 100)

**Parsed Components (Lazy-Initialized)**:
- `spec                     :: Union{Spec, Nothing}` — Parsed specification
- `grammar                  :: Union{AbstractGrammar, Nothing}` — Built grammar
- `oracle                   :: Union{AbstractOracle, Nothing}` — Oracle instance
- `is_initialized           :: Bool` — Initialization status

**Metadata & Analysis**:
- `metadata                 :: Dict{String, Any}` — User-defined metadata

**Lazy Initialization**:
Parsed fields are populated only when `ensure_initialized!()` is called or
when synthesis begins. This allows:
- Configuration inspection before running
- Better error messages (fails on init, not mid-synthesis)
- Easier debugging and testing

**Example Usage**:

```julia
# Minimal setup (uses all defaults)
problem = CEGISProblem("spec.sl")
result = run_synthesis(problem)

# Custom parser and oracle
problem = CEGISProblem(
    "spec.sl";
    oracle_factory = Z3OracleFactory(parser=SymbolicCandidateParser()),
    iterator_config = DFSIteratorConfig(max_depth=8)
)
result = run_synthesis(problem)

# With debugging
problem = CEGISProblem(
    "spec.sl";
    desired_solution = "ifelse(x > 5, x+y, z)"
)
result = run_synthesis(problem)

# Manual initialization for inspection
problem = CEGISProblem("spec.sl")
ensure_initialized!(problem)
println("Grammar size: \$(length(problem.grammar))")
```

**Backward Compatibility**: The legacy `synth_with_oracle()` function continues
to work with old-style oracle objects.
"""
mutable struct CEGISProblem
    # Configuration (immutable after construction)
    spec_path               :: String
    spec_parser             :: Any  # AbstractSpecParser
    grammar_config          :: Any  # GrammarConfig
    oracle_factory          :: Any  # AbstractOracleFactory
    iterator_config         :: Any  # AbstractSynthesisIterator
    
    # Synthesis parameters
    start_symbol            :: Symbol
    max_depth               :: Int
    max_enumerations        :: Int
    max_time                :: Float64
    max_iterations          :: Int
    
    # Debug / Analysis
    desired_solution        :: Union{String, Nothing}
    metadata                :: Dict{String, Any}
    
    # Parsed components (lazy-initialized)
    spec                    :: Union{Any, Nothing}  # CEXGeneration.Spec
    grammar                 :: Union{AbstractGrammar, Nothing}
    oracle                  :: Union{Any, Nothing}  # AbstractOracle
    
    # State
    is_initialized          :: Bool
end

"""
    CEGISProblem(spec_path; <options>)

Construct a new generic CEGISProblem with configuration.

**Arguments**:
- `spec_path::String` — Path to specification file

**Options**:
- `spec_parser::AbstractSpecParser` — Parser for spec format (default: SyGuSParser)
- `grammar_config::GrammarConfig` — Grammar configuration (default: default_grammar_config())
- `oracle_factory::AbstractOracleFactory` — Oracle factory (default: default_oracle_factory())
- `iterator_config::AbstractSynthesisIterator` — Iterator config (default: default_iterator_config())
- `start_symbol::Symbol` — Start non-terminal (default: :Expr)
- `max_depth::Int` — Max program depth (default: 5)
- `max_enumerations::Int` — Enumeration limit (default: 50_000)
- `max_time::Float64` — Time budget (default: Inf)
- `max_iterations::Int` — CEGIS rounds limit (default: 100)
- `desired_solution::Union{String, Nothing}` — Debug target solution (default: nothing)
- `metadata::Dict{String, Any}` — Problem metadata (default: empty)

**Returns**: CEGISProblem instance (not yet initialized; call ensure_initialized!() to parse)

**Throws**: ArgumentError if spec_path doesn't exist

**Example**:
```julia
# Uses all defaults (SyGuSParser, Z3OracleFactory, BFSIteratorConfig)
problem = CEGISProblem("benchmark.sl")

# Custom configuration
@with_module CEGIS begin
    problem = CEGISProblem(
        "benchmark.sl";
        oracle_factory = Z3OracleFactory(),
        iterator_config = DFSIteratorConfig(max_depth=7),
        desired_solution = "max(x, y)",
        metadata = Dict("source" => "SyGuS competition")
    )
end
```

**Note**: This constructor requires that default factory functions are exported
from the CEGIS module for automatic defaults to work.
"""
function CEGISProblem(
    spec_path :: String;
    spec_parser             :: Any = nothing,
    grammar_config          :: Any = nothing,
    oracle_factory          :: Any = nothing,
    iterator_config         :: Any = nothing,
    start_symbol            :: Symbol = :Expr,
    max_depth               :: Int = 5,
    max_enumerations        :: Int = 50_000,
    max_time                :: Float64 = Inf,
    max_iterations          :: Int = 100,
    desired_solution        :: Union{String, Nothing} = nothing,
    metadata                :: Dict{String, Any} = Dict{String, Any}(),
)
    # Validate spec_path
    !isfile(spec_path) && error("Specification file not found: $spec_path")
    
    # Validate parameters
    max_depth >= 1 || error("max_depth must be >= 1, got $max_depth")
    max_enumerations >= 1 || error("max_enumerations must be >= 1, got $max_enumerations")
    
    # Note: Defaults for spec_parser, grammar_config, oracle_factory, iterator_config
    # are not set here because they depend on modules not yet loaded.
    # They will be set by ensure_initialized!() if left as nothing.
    # Alternatively, the CEGIS module can be extended to provide factory functions.
    
    # Provide sensible defaults if not specified
    if spec_parser === nothing
        spec_parser = Parsers.SyGuSParser()
    end
    
    if grammar_config === nothing
        grammar_config = GrammarBuilding.default_grammar_config()
    end
    
    if oracle_factory === nothing
        oracle_factory = OracleFactories.Z3OracleFactory()
    end
    
    if iterator_config === nothing
        iterator_config = IteratorConfig.BFSIteratorConfig(max_depth = max_depth)
    end
    
    return CEGISProblem(
        spec_path,
        spec_parser,
        grammar_config,
        oracle_factory,
        iterator_config,
        start_symbol,
        max_depth,
        max_enumerations,
        max_time,
        max_iterations,
        desired_solution,
        metadata,
        nothing,  # spec (not yet parsed)
        nothing,  # grammar (not yet built)
        nothing,  # oracle (not yet created)
        false,    # is_initialized
    )
end

"""
    ensure_initialized!(problem::CEGISProblem)

Initialize a CEGISProblem by parsing spec, building grammar, and creating oracle.

This function is called automatically at the start of synthesis. Can be called
manually for inspection or error checking before running.

**Process**:
1. Parse specification (if not already parsed)
2. Build grammar from spec and config
3. Create oracle via factory
4. Set is_initialized flag

**Errors**: Propagates any errors from parsers, builders, or factories.

**Example**:
```julia
problem = CEGISProblem("spec.sl")
ensure_initialized!(problem)

# Now inspect problem state
println("Grammar start_symbol: \$(problem.start_symbol)")
println("Is initialized: \$(problem.is_initialized)")
```

**Side effects**: Modifies problem.spec, problem.grammar, problem.oracle, problem.is_initialized
"""
function ensure_initialized!(problem::CEGISProblem)
    if problem.is_initialized
        return  # Already initialized, skip
    end
    
    # Step 1: Parse specification
    if problem.spec === nothing
        problem.spec = Parsers.parse_spec(problem.spec_parser, problem.spec_path)
    end
    
    # Step 2: Build grammar
    if problem.grammar === nothing
        # If spec is LIA but using default config with BASE_OPERATIONS, upgrade to LIA_OPERATIONS
        grammar_config = problem.grammar_config
        if GrammarBuilding.is_lia_problem(problem.spec) && grammar_config.base_operations === GrammarBuilding.BASE_OPERATIONS
            grammar_config = GrammarBuilding.lia_grammar_config()
        end
        problem.grammar = GrammarBuilding.build_generic_grammar(problem.spec, grammar_config)
    end
    
    # Step 3: Create oracle
    if problem.oracle === nothing
        problem.oracle = OracleFactories.create_oracle(problem.oracle_factory, problem.spec, problem.grammar)
    end
    
    # Step 4: Mark as initialized
    problem.is_initialized = true
end

# ─────────────────────────────────────────────────────────────────────────────
# Final output of the CEGIS run
# ─────────────────────────────────────────────────────────────────────────────

"""
    struct CEGISResult

The value returned by [`cegis`](@ref) after the loop terminates.

Fields
------
- `status         :: CEGISStatus`                    — High-level outcome.
- `program        :: Union{RuleNode, Nothing}`        — The synthesized program
  (or `nothing` on failure / timeout with nothing found).
- `iterations     :: Int`                            — Number of rounds run.
- `counterexamples :: Vector{Counterexample}`        — All counterexamples
  accumulated during the run (useful for debugging and analysis).

Consumed by: the caller of `cegis(...)` — typically a higher-level driver or
the `pipeline.jl` script.
"""
struct CEGISResult
    status          :: CEGISStatus
    program         :: Union{RuleNode, Nothing}
    iterations      :: Int
    counterexamples :: Vector{Counterexample}
end
