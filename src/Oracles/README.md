# Oracles

Collection of oracle implementations for CEGIS counterexample detection and verification.

## Overview

The Oracles module aggregates all concrete oracle implementations used for verification during CEGIS synthesis. Oracles determine whether a candidate program is correct by either checking against test cases or performing formal verification with an SMT solver.

## Key Components

- **abstract_oracle.jl** — Abstract base type and interface definition
- **ioexample_oracle.jl** — Test-based oracle using I/O examples
- **z3_oracle.jl** — Z3 SMT solver-based oracle for formal verification
- **semantic_smt_oracle.jl** — Alternative SMT oracle implementation
- **stub_oracle.jl** — Stub oracle for testing and prototyping

## Oracle Interface

All concrete oracles must subtype `AbstractOracle` and implement:

```julia
extract_counterexample(oracle, problem, candidate) :: Union{Counterexample, Nothing}
```

This method takes a candidate program and returns:
- `Counterexample` — When candidate violates specification
- `nothing` — When no counterexample found (candidate may be correct)

## Main Oracle Types

### IOExampleOracle
- **Purpose**: Fast, incomplete verification using test cases
- **Inputs**: Collection of I/O examples
- **Operation**: Evaluates candidate against test cases
- **Returns**: First failing test case as counterexample, or `nothing` if all pass
- **Characteristics**: 
  - Very fast execution
  - Cannot prove correctness
  - Useful for quick filtering

### Z3Oracle
- **Purpose**: Formal verification using Z3 SMT solver
- **Inputs**: SyGuS specification, candidate program
- **Operation**: Converts to SMT-LIB2 query, submits to Z3, parses result
- **Returns**: Concrete counterexample from SMT solver, or `nothing` if valid
- **Characteristics**:
  - Produces rigorous proofs
  - Can be slow for complex formulas
  - Requires CEXGeneration module for query generation

### SemanticSMTOracle
- **Purpose**: Alternative SMT-based verification approach
- **Similar to**: Z3Oracle but potentially different query generation strategy

### StubOracle
- **Purpose**: Testing and prototyping
- **Simulates**: Oracle behavior without real verification
- **Use case**: Debugging CEGIS loop logic

## Oracle Selection in CEGIS

Oracles are selected via factory pattern:

```julia
# Formal verification
factory = Z3OracleFactory()

# Fast test-based verification
factory = IOExampleOracleFactory(examples)

# Use in synthesis problem
problem = CEGISProblem(spec; oracle_factory=factory)
```

## Design Notes

- **Abstraction**: `AbstractOracle` provides unified interface for diverse verification strategies
- **Modular**: Each oracle independently implements interface
- **Pluggable**: New oracle types added without modifying existing code
- **Lazy loading**: Oracles using external dependencies (Z3, CEXGeneration) loaded on demand
