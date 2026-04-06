# OracleFactories

Factory pattern implementation for pluggable oracle creation in CEGIS synthesis.

## Overview

OracleFactories provides a factory pattern interface for creating oracle instances from various sources (Z3 SMT solver, test examples, custom verifiers, etc.). This decouples oracle instantiation from core CEGIS logic and enables runtime selection of verification strategies.

## Key Components

- **AbstractFactory.jl** — Abstract factory interface and concrete implementations

## Main Features

### Oracle Factory Types

- **Z3OracleFactory** — Creates Z3 SMT solver-based oracles
  - Uses CEXGeneration module to convert candidates to SMT-LIB2 queries
  - Performs full formal verification
  - Can specify custom candidate parser
  - Example:
    ```julia
    factory = Z3OracleFactory()  # Uses default parser
    oracle = create_oracle(factory, spec, grammar)
    ```

- **IOExampleOracleFactory** — Creates test-based oracles from I/O examples
  - Instantiated with collection of `IOExample` objects
  - Verifies candidates against test suite
  - Fast but incomplete verification
  - Example:
    ```julia
    examples = [IOExample(Dict(:x => 1), 2), ...]
    factory = IOExampleOracleFactory(examples)
    oracle = create_oracle(factory, spec, grammar)
    ```

## Design Pattern

The factory pattern is used consistently:

1. **Define factory** — Create instance of desired oracle factory
2. **Pass to CEGIS** — Provide factory to CEGISProblem or synthesis driver
3. **Automatic instantiation** — CEGIS creates appropriately configured oracle

### Custom Oracle Extension

Users can extend with custom oracles:

```julia
struct CustomOracleFactory <: AbstractOracleFactory
    config :: Dict
end

function create_oracle(factory::CustomOracleFactory, spec, grammar)
    return CustomOracle(factory.config, spec, grammar)
end

# Use in synthesis
factory = CustomOracleFactory(Dict(:threshold => 0.95))
problem = CEGISProblem(spec; oracle_factory=factory)
```

## Key API

- `AbstractOracleFactory` — Base type for all oracle factories
- `create_oracle(factory, spec, grammar)` — Factory method to instantiate oracles
- `Z3OracleFactory` — SMT solver-based oracle factory
- `IOExampleOracleFactory` — Test-based oracle factory

## Integration with CEGIS

Oracles are instantiated once during synthesis initialization:

1. User specifies oracle factory in problem configuration
2. CEGIS calls `create_oracle()` to instantiate oracle
3. Oracle is used repeatedly in the CEGIS loop to verify candidates

## Design Notes

- **Separation of concerns** — Instantiation logic separated from oracle implementations
- **Runtime flexibility** — Oracle type selected without recompilation
- **Extensibility** — New oracle types added by implementing `AbstractOracleFactory`
- **Module isolation** — Defers loading of CEGIS modules to avoid circular dependencies
