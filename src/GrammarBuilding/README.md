# GrammarBuilding

Grammar configuration and building system for CEGIS synthesis.

## Overview

GrammarBuilding provides a declarative, configuration-driven approach to constructing synthesis grammars. Rather than hardcoding grammar rules as string interpolation, this module enables reusable operation sets and dynamic grammar construction from problem specifications.

## Key Components

- **GrammarConfig.jl** — Configuration-based grammar building with operation sets, variable extraction, and rule combination

## Main Features

### Predefined Operation Sets

The module exports reusable operation sets for common synthesis domains:

- **BASE_OPERATIONS** — Default operations for general integer arithmetic synthesis
  - Constants: 0, 1, 2, -1
  - Binary arithmetic: +, -, *
  - Comparisons: <, >, <=, >=, ==
  - Logical operators: &&, ||, !
  - Control: ifelse/3

- **LIA_OPERATIONS** — Linear Integer Arithmetic (LIA) specialized operations
  - Excludes bitwise and modulo operations
  - Optimized for problems with `(set-logic LIA)` declarations

- **EXTENDED_OPERATIONS** — Extended set including division and modulo
- **STRING_OPERATIONS** — String manipulation operations
- **BITVECTOR_OPERATIONS** — Bitwise and bitvector-specific operations

### GrammarConfig Object

The `GrammarConfig` type enables declarative grammar specification:

```julia
config = GrammarConfig(
    spec;
    base_operations = LIA_OPERATIONS,
    additional_rules = ["Expr = Expr * Expr"],
    free_vars_from_spec = true
)

grammar = build_generic_grammar(spec, config)
```

## Key API

- `build_generic_grammar(spec, config)` — Construct grammar from specification and config
- `generate_grammar_string(config)` — Generate human-readable grammar representation
- `flatten_operations(ops)` — Flatten operation sets into rule list
- `sygus_sort_to_julia_type(sort_name)` — Convert SyGuS sort names to Julia types
- `is_lia_problem(spec)` — Detect Linear Integer Arithmetic problems

## Design Notes

- Reusable operation sets reduce duplication across benchmarks
- Automatic variable extraction from specs enables zero-configuration synthesis
- Declarative configuration improves maintainability and reproducibility
- Supports meta-programming for dynamic grammar construction
