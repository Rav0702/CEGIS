"""
    IteratorConfig/AbstractIterator.jl

Configuration types for synthesis iterator strategies. Enables runtime selection of
search strategies (BFS, DFS, random, etc.) without modifying core CEGIS code.

## Usage

```julia
# Breadth-first search (default)
iterator_config = BFSIteratorConfig(max_depth=6)

# Depth-first search
iterator_config = DFSIteratorConfig(max_depth=8)

# Random search
iterator_config = RandomSearchIteratorConfig(max_depth=7, seed=42)

# Use in CEGISProblem
problem = CEGISProblem("spec.sl"; iterator_config=iterator_config)
result = run_synthesis(problem)
```
"""

using HerbCore
using HerbGrammar
using HerbSearch


abstract type AbstractSynthesisIterator end

function create_iterator(config::AbstractSynthesisIterator, grammar::AbstractGrammar, start_symbol::Symbol) :: Any
    error("create_iterator not implemented for $(typeof(config))")
end


struct BFSIteratorConfig <: AbstractSynthesisIterator
    max_depth :: Int
    solver    :: Union{GenericSolver, Nothing}
    
    function BFSIteratorConfig(;
        max_depth :: Int = 5,
        solver    :: Union{GenericSolver, Nothing} = nothing
    )
        max_depth >= 1 || error("max_depth must be >= 1, got $max_depth")
        new(max_depth, solver)
    end
end

"""
    create_iterator(config::BFSIteratorConfig, grammar::AbstractGrammar, start_symbol::Symbol)

Create a BFSIterator from configuration.
"""
function create_iterator(config::BFSIteratorConfig, grammar::AbstractGrammar, start_symbol::Symbol)
    solver = if config.solver === nothing
        GenericSolver(grammar, start_symbol; max_depth=config.max_depth)
    else
        config.solver
    end
    
    return BFSIterator(; solver, max_depth=config.max_depth)
end

struct DFSIteratorConfig <: AbstractSynthesisIterator
    max_depth :: Int
    solver    :: Union{GenericSolver, Nothing}
    
    function DFSIteratorConfig(;
        max_depth :: Int = 6,
        solver    :: Union{GenericSolver, Nothing} = nothing
    )
        max_depth >= 1 || error("max_depth must be >= 1, got $max_depth")
        new(max_depth, solver)
    end
end

"""
    create_iterator(config::DFSIteratorConfig, grammar::AbstractGrammar, start_symbol::Symbol)

"""
function create_iterator(config::DFSIteratorConfig, grammar::AbstractGrammar, start_symbol::Symbol)
    solver = if config.solver === nothing
        GenericSolver(grammar, start_symbol; max_depth=config.max_depth)
    else
        config.solver
    end
    
    return DFSIterator(; solver, max_depth=config.max_depth)
end


struct RandomSearchIteratorConfig <: AbstractSynthesisIterator
    max_depth :: Int
    seed      :: Int
    solver    :: Union{GenericSolver, Nothing}
    
    function RandomSearchIteratorConfig(;
        max_depth :: Int = 6,
        seed      :: Int = 42,
        solver    :: Union{GenericSolver, Nothing} = nothing
    )
        max_depth >= 1 || error("max_depth must be >= 1, got $max_depth")
        new(max_depth, seed, solver)
    end
end


"""
    default_iterator_config() :: AbstractSynthesisIterator

Returns the default iterator configuration for new CEGISProblem instances.
"""
function default_iterator_config() :: AbstractSynthesisIterator
    return BFSIteratorConfig()
end
