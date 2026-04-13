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

Lightweight specification-driven CEGIS problem container.

This CEGISProblem type provides a minimal problem specification that pairs with
the unified `run_synthesis()` API. All synthesis parameters are passed to
`run_synthesis()` rather than stored in the problem, following the same pattern
as HerbSearch's `synth()` function.

**Core Fields**:
- `spec_path                 :: String`  — Path to specification file (e.g., "benchmark.sl")
- `desired_solution         :: Union{String, Nothing}` — Optional target solution for debugging

**Parsed Components (Lazy-Initialized)**:
- `spec                     :: Union{Spec, Nothing}` — Parsed specification
- `spec_parser              :: Any` — Parser instance for lazy loading
- `oracle                   :: Union{AbstractOracle, Nothing}` — Oracle instance (lazy)
- `is_initialized           :: Bool` — Initialization status

**Design Rationale**:
- **Lightweight**: Only stores spec file path and optional debug target
- **Separation of concerns**: Synthesis parameters (iterator, max_enumerations, etc.)
  are passed to `run_synthesis()` rather than stored in problem
- **Lazy initialization**: Spec and oracle are only loaded when actually needed
- **Unified API**: Matches HerbSearch.synth() signature for consistency

**Example Usage**:

```julia
# Minimal setup
problem = CEGISProblem("spec.sl"; desired_solution="max(x, y)")

# Build grammar and iterator externally
grammar = build_grammar_from_spec("spec.sl")
iterator = create_iterator(BFSIteratorConfig(max_depth=5), grammar, :Expr)

# Run synthesis with unified run_synthesis() API
result = run_synthesis(
    problem, iterator;
    max_enumerations = 10_000_000,
    max_time = 60.0
)
```

**See also**: `run_synthesis()`, `build_grammar_from_spec()`, `create_iterator()`
"""
mutable struct CEGISProblem
    # Problem specification (required)
    spec_path               :: String
    
    # Debug / Analysis
    desired_solution        :: Union{String, Nothing}
    
    # Parsed components (lazy-initialized)
    spec                    :: Union{Any, Nothing}  # CEXGeneration.Spec
    spec_parser             :: Any  # Parser instance
    oracle                  :: Union{Any, Nothing}  # AbstractOracle
    
    # State
    is_initialized          :: Bool
end

"""
    CEGISProblem(spec_path; desired_solution=nothing)

Construct a lightweight CEGISProblem from a specification file path.

**Arguments**:
- `spec_path::String` — Path to specification file (e.g., "benchmark.sl")

**Options**:
- `desired_solution::Union{String, Nothing}` — Optional debug target solution
  (enables debug logging if synthesis doesn't find this exact program)

**Returns**: CEGISProblem instance with lazy-initialized spec and oracle

**Throws**: Error if spec_path doesn't exist

**Example**:
```julia
# Basic: Just spec file path
problem = CEGISProblem("benchmark.sl")

# With debug target
problem = CEGISProblem("benchmark.sl"; desired_solution="max(x, y)")

# Then use with run_synthesis
grammar = build_grammar_from_spec("benchmark.sl")
iterator = create_iterator(BFSIteratorConfig(max_depth=5), grammar, :Expr)
result = run_synthesis(problem, iterator; max_enumerations=10_000_000)
```

**Note**: Synthesis parameters (max_depth, max_enumerations, max_time, etc.)
are passed directly to `run_synthesis()`, not stored in the problem.
See `run_synthesis()` for the complete API.
"""
function CEGISProblem(
    spec_path :: String;
    desired_solution :: Union{String, Nothing} = nothing,
)
    # Validate spec_path
    !isfile(spec_path) && error("Specification file not found: $spec_path")
    
    # Create parser instance (used for lazy loading)
    parser = Parsers.SyGuSParser()
    
    return CEGISProblem(
        spec_path,
        desired_solution,
        nothing,   # spec (not yet parsed)
        parser,    # spec_parser
        nothing,   # oracle (not yet created)
        false,     # is_initialized
    )
end

"""
    ensure_initialized!(problem::CEGISProblem, oracle; spec_parser=nothing)

Initialize a CEGISProblem by parsing its specification file.

This function is called by `run_synthesis()` to lazily load the spec once it's
needed. Since grammar and oracle are built externally and passed to `run_synthesis()`,
this function only handles spec parsing.

**Arguments**:
- `problem::CEGISProblem` — Problem to initialize
- `oracle` — The oracle instance (used to access the parsed spec)

**Options**:
- `spec_parser` — Parser instance (default: problem.spec_parser)

**Errors**: Propagates any errors from spec parser.

**Side effects**: Modifies problem.spec and problem.is_initialized

**Example**:
```julia
problem = CEGISProblem("spec.sl")
oracle = create_oracle(spec, grammar)  # Created externally
ensure_initialized!(problem, oracle)

# Now problem.spec is populated for use in CEGIS loop
```

**Note**: This is a lightweight init that only parses the spec. The oracle is
passed in (created by the caller) rather than being created here. This maintains
the lazy initialization pattern while keeping the problem lightweight.
"""
function ensure_initialized!(problem::CEGISProblem, oracle; spec_parser=nothing)
    if problem.is_initialized
        return  # Already initialized, skip
    end
    
    # Use provided parser or fall back to problem's
    parser = spec_parser !== nothing ? spec_parser : problem.spec_parser
    
    # Step 1: Parse specification (lazy load)
    if problem.spec === nothing
        problem.spec = Parsers.parse_spec(parser, problem.spec_path)
    end
    
    # Step 2: Store oracle reference
    if problem.oracle === nothing
        problem.oracle = oracle
    end
    
    # Step 3: Mark as initialized
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
