# IteratorConfig

Iterator configuration and selection for CEGIS synthesis search strategies.

## Overview

IteratorConfig provides an abstract configuration interface for selecting and customizing synthesis search strategies (BFS, DFS, random search, etc.). This enables runtime selection of iteration strategies without modifying core CEGIS code.

## Key Components

- **AbstractIterator.jl** — Abstract base type and concrete implementations for iterator strategies

## Main Features

### Search Strategy Configurations

- **BFSIteratorConfig** — Breadth-first search strategy
  - Explores all candidates at depth `d` before exploring depth `d+1`
  - Suitable for finding simple solutions
  - Default `max_depth=5`

- **DFSIteratorConfig** — Depth-first search strategy
  - Explores one branch completely before backtracking
  - Memory efficient for deep search trees
  - Default `max_depth=6`

- **RandomSearchIteratorConfig** — Random exploration strategy
  - Randomly samples the search space
  - Can escape local optima
  - Supports custom random seed

### Configuration Pattern

```julia
# Breadth-first search (default exploration)
iterator_config = BFSIteratorConfig(max_depth=6)

# Depth-first search (memory efficient)
iterator_config = DFSIteratorConfig(max_depth=8)

# Random search (escaping local optima)
iterator_config = RandomSearchIteratorConfig(max_depth=7, seed=42)
```

## Key API

- `AbstractSynthesisIterator` — Base type for all iterator configurations
- `create_iterator(config, grammar, start_symbol)` — Factory function to instantiate iterator from config
- `BFSIteratorConfig` — Breadth-first configuration
- `DFSIteratorConfig` — Depth-first configuration
- `RandomSearchIteratorConfig` — Random search configuration

## Integration with CEGIS

Iterators are used in the main CEGIS loop to generate candidate programs:

1. Iterator generates candidates from the grammar
2. Each candidate is tested against the oracle
3. Process continues until valid solution is found or search space exhausted

## Design Notes

- **Factory pattern** — `create_iterator()` decouples configuration from instantiation
- **Strategy pattern** — Different search strategies without modifying core synthesis logic
- **Extensible** — Users can add new iterator types by implementing `AbstractSynthesisIterator`
- **Configurable** — All parameters (depth, seed, custom solvers) specified at construction time
