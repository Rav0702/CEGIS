"""
    module OracleFactories

Oracle factory pattern for CEGIS synthesis.

Provides abstract factory interface for creating oracles from various sources
(Z3 SMT solver, test examples, custom verifiers).
"""
module OracleFactories

using HerbCore
using HerbSpecification

# Note: We need to defer loading of CEGIS modules until after CEGIS module is fully initialized
# to avoid circular dependency issues. See AbstractFactory.jl for runtime module access patterns.

# Include abstract base type and implementations  
include("AbstractFactory.jl")

# Export public API
export
    AbstractOracleFactory,
    Z3OracleFactory,
    IOExampleOracleFactory,
    create_oracle

end # module OracleFactories
