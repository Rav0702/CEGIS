"""
    OracleFactories/AbstractFactory.jl

Factory pattern for oracle creation. Enables pluggable oracle selection without
modifying core CEGIS code, and centralizes oracle instantiation logic.

## Usage

```julia
# Create Z3 oracle via factory
factory = Z3OracleFactory()
oracle = create_oracle(factory, spec, grammar)

# Use test-based oracle instead
factory = IOExampleOracleFactory([IOExample(Dict(:x => 1), 2), ...])
oracle = create_oracle(factory, spec, grammar)

# User extension
struct CustomOracleFactory <: AbstractOracleFactory end

function create_oracle(factory::CustomOracleFactory, spec, grammar)
    return CustomOracle(...)
end

# Automatic selection in CEGISProblem
problem = CEGISProblem("spec.sl"; oracle_factory=CustomOracleFactory())
```
"""

using HerbCore
using HerbGrammar

# ─────────────────────────────────────────────────────────────────────────────
# Abstract interface
# ─────────────────────────────────────────────────────────────────────────────

"""
    abstract type AbstractOracleFactory

"""
abstract type AbstractOracleFactory end

"""
    create_oracle(factory::AbstractOracleFactory, spec::Spec, grammar::AbstractGrammar) :: AbstractOracle

Create an oracle instance configured by `factory`.
"""
function create_oracle(factory::AbstractOracleFactory, spec::Any, grammar::AbstractGrammar)
    error("create_oracle not implemented for $(typeof(factory))")
end

# ─────────────────────────────────────────────────────────────────────────────
# Z3 Oracle Factory
# ─────────────────────────────────────────────────────────────────────────────

"""
    struct Z3OracleFactory <: AbstractOracleFactory

Factory for creating Z3 SMT solver-based oracles.
```
"""
struct Z3OracleFactory <: AbstractOracleFactory
    parser  :: Any  # CEXGeneration.AbstractCandidateParser
    mod     :: Module
    use_direct_conversion :: Bool
    
    function Z3OracleFactory(;
        parser = nothing,
        mod    :: Module = Main,
        use_direct_conversion :: Bool = false
    )
        if parser === nothing
            # Get default parser from CEXGeneration at runtime via Main
            cexgen = getfield(Main, :CEGIS) |> m -> getfield(m, :CEXGeneration)
            parser = cexgen.get_default_candidate_parser()
        end
        new(parser, mod, use_direct_conversion)
    end
end

"""
    create_oracle(factory::Z3OracleFactory, spec::Spec, grammar::AbstractGrammar)

Create a Z3Oracle for formal verification.
"""
function create_oracle(factory::Z3OracleFactory, spec::Any, grammar::AbstractGrammar)
    # Check if spec has a file_path field
    if hasfield(typeof(spec), :file_path) && !isempty(spec.file_path)
        file_path = spec.file_path
        
        # Access Z3Oracle type - it's exported from CEGIS module
        cegis_module = getfield(Main, :CEGIS)
        Z3OracleType = getfield(cegis_module, :Z3Oracle)
        
        # Create Z3Oracle with the spec file path
        return Z3OracleType(
            file_path,
            grammar;
            mod = factory.mod,
            parser = factory.parser,
            use_direct_conversion = factory.use_direct_conversion
        )
    else
        error("create_oracle for Z3OracleFactory requires spec file path. " *
              "Spec must have file_path field.")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# IO Example Oracle Factory
# ─────────────────────────────────────────────────────────────────────────────

"""
    struct IOExampleOracleFactory <: AbstractOracleFactory

Factory for creating test-based oracles that verify against IO examples.
```
"""
struct IOExampleOracleFactory <: AbstractOracleFactory
    examples :: Vector{IOExample}
    
    function IOExampleOracleFactory(examples::Vector{IOExample})
        new(examples)
    end
end

"""
    create_oracle(factory::IOExampleOracleFactory, spec::Spec, grammar::AbstractGrammar) :: AbstractOracle

Create an IOExampleOracle for test-based verification.

The oracle will verify each candidate against the provided examples.
"""
function create_oracle(factory::IOExampleOracleFactory, spec::Any, grammar::AbstractGrammar)
    # This will create an IOExampleOracle once it's defined
    # For now, placeholder
    error("IOExampleOracle not yet implemented in phase 1. Available soon.")
end

# ─────────────────────────────────────────────────────────────────────────────
# Semantic SMT Oracle Factory (Legacy)
# ─────────────────────────────────────────────────────────────────────────────

"""
    struct SemanticSMTOracleFactory <: AbstractOracleFactory
"""
struct SemanticSMTOracleFactory <: AbstractOracleFactory end

"""
    create_oracle(factory::SemanticSMTOracleFactory, spec::Spec, grammar::AbstractGrammar) :: AbstractOracle

Create a legacy SemanticSMTOracle.
"""
function create_oracle(factory::SemanticSMTOracleFactory, spec::Any, grammar::AbstractGrammar)
    # This will create a SemanticSMTOracle once it's imported/defined
    error("SemanticSMTOracle not yet implemented as factory. Available in next phase.")
end

# ─────────────────────────────────────────────────────────────────────────────
# Default factory selection
# ─────────────────────────────────────────────────────────────────────────────

"""
    default_oracle_factory() :: AbstractOracleFactory

Returns the default oracle factory for new CEGISProblem instances.

Currently returns `Z3OracleFactory()` (formal verification is the default).

This can be configured globally if needed in future versions:
```julia
# Future: set_default_oracle_factory(IOExampleOracleFactory(...))
```
"""
function default_oracle_factory() :: AbstractOracleFactory
    return Z3OracleFactory()
end
