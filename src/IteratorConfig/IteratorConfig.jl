"""
    module IteratorConfig

Iterator configuration for CEGIS synthesis.

Provides abstract interface and concrete configurations for iterator strategies
(BFS, DFS, random search, custom search strategies).
"""
module IteratorConfig

using HerbCore
using HerbGrammar
using HerbConstraints
using HerbSearch

# Include abstract base type and implementations
include("AbstractIterator.jl")

# Export public API
export
    AbstractSynthesisIterator,
    BFSIteratorConfig,
    DFSIteratorConfig,
    RandomSearchIteratorConfig,
    create_iterator

end # module IteratorConfig
