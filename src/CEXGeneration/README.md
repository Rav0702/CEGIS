# CEXGeneration Module

Production-ready counterexample query generation for SyGuS-v2 specifications.

## Overview

CEXGeneration converts SyGuS-v2 specifications (.sl files) and candidate solutions into SMT-LIB2 queries that can be solved with Z3 or other SMT solvers. It replaces the monolithic scripts approach with a modular, maintainable architecture.

## Features

- **SyGuS-v2 Parsing**: Handles logical context, options, declarations, synthesis targets, and constraints
- **Infix Expression Parsing**: Surface syntax (if/then/else, arithmetic, comparisons) to SMT-LIB2 prefix notation
- **Automatic Substitution**: Maps free variables to function parameters correctly
- **Inv-Constraint Expansion**: Transforms invariant constraints to pre/trans/post safety properties
- **Serialization**: Save and load Spec objects for caching parsed specifications

## Public API

### `parse_spec_from_file(filename::String) → Spec`

Parse a SyGuS-v2 specification file (.sl) to a data structure.

```julia
using CEXGeneration

spec = parse_spec_from_file("problem.sl")
# Spec contains:
#   - logic: "QF_LIA" 
#   - options: Dict of solver options
#   - synth_funs: Vector of synthesis targets
#   - free_vars: Vector of free variables
#   - constraints: Vector of SMT-LIB2 constraints
```

### `generate_cex_query(spec::Spec, candidates::Dict{String,String}) → String`

Generate an SMT-LIB2 query for candidate verification.

```julia
candidates = Dict(
    "f" => "if x = 0 then 1 else x",      # Infix syntax
    "g" => "(+ x 1)"                       # Raw SMT-LIB2
)

query = generate_cex_query(spec, candidates)
write("query.smt2", query)
```

### `candidate_to_smt2(src::String) → String`

Convert an infix expression to SMT-LIB2 prefix notation (standalone utility).

```julia
smt_expr = candidate_to_smt2("if x = 0 then 1 else (+ x 1)")
# → "(ite (= x 0) 1 (+ x 1))"
```

### `serialize_spec(spec::Spec, filename::String)`

Save a parsed Spec object to disk for reuse.

```julia
serialize_spec(spec, "problem.parsed.jl")
```

### `deserialize_spec(filename::String) → Spec`

Load a previously saved Spec object.

```julia
spec = deserialize_spec("problem.parsed.jl")
```

## Surface Syntax for Candidates

The infix parser supports:

| Category     | Syntax                          | SMT-LIB2 Output     |
|--------------|--------------------------------|------------------|
| Literals     | `0`, `-3`, `true`, `false`     | Unchanged          |
| Arithmetic   | `x + y`, `x - y`, `x * y`, `-x`| `(+ x y)` etc      |
| Comparisons  | `x = y`, `x != y`, `x < y`    | `(= x y)` etc      |
| Boolean      | `x and y`, `x or y`, `not x`    | Unchanged          |
| If-then-else | `if C then T else E`            | `(ite C T E)`      |
| Variant ITE  | `ite(C, T, E)`                  | `(ite C T E)`      |
| Raw SMT-LIB2 | `(ite (= x 0) 1 x)`             | Pass-through       |

## Example: Complete Workflow

```julia
using CEXGeneration

# 1. Parse specification
spec = parse_spec_from_file("spec.sl")

# 2. Generate query with candidate
candidates = Dict("max" => "if x > y then x else y")
query = generate_cex_query(spec, candidates)

# 3. Write to file (automatic UTF-8 encoding)
open("query.smt2", "w") do f
    write(f, query)
end

# 4. Run Z3 (external)
# $ z3 query.smt2
```

## Module Structure

```
CEXGeneration/
├── types.jl       — Core data structures (Spec, SynthFun, FreeVar)
├── sexp.jl        — S-expression lexing and serialization
├── parser.jl      — SyGuS-v2 specification parser
├── candidates.jl  — Infix-to-prefix expression parser
├── query.jl       — SMT-LIB2 query generation
└── CEXGeneration.jl — Module entry point (this exports the public API)
```

## Data Structures

### `Spec`

```julia
mutable struct Spec
    logic :: String                      # "QF_LIA", "QF_UFLIA", etc
    options :: Dict{String, String}      # :produce-models → true
    synth_funs :: Vector{SynthFun}       # Functions to synthesize
    free_vars :: Vector{FreeVar}         # Input variables
    constraints :: Vector{String}        # SMT-LIB2 constraints
end
```

### `SynthFun`

```julia
struct SynthFun
    name :: String                       # Function name
    params :: Vector{FreeVar}            # Parameters
    sort :: String                       # Return type
    grammar :: Union{Nothing, String}    # Grammar (unused for now)
end
```

### `FreeVar`

```julia
struct FreeVar
    name :: String                       # Variable name ("x1", "y", etc)
    sort :: String                       # Type ("Int", "Bool", etc)
    param_sorts :: Vector{String}        # If no params, empty vector
    primed :: Bool                       # For invariants: x'
    is_free :: Bool                      # True if free variable
    is_state_var :: Bool                # For temporal reasoning
end
```

## Integration with CEGIS

The CEXGeneration module can be used independently or integrated into the CEGIS synthesis loop:

```julia
using CEGIS, CEXGeneration

# In verifier.jl or similar:
candidate = candidate_to_smt2(my_expression)
query = generate_cex_query(spec, Dict("f" => candidate))
result = run_z3(query)  # External solver
```

## Error Handling

All parsing errors include descriptive messages:

```julia
try
    spec = parse_spec_from_file("broken.sl")
catch e
    println("Parse error: $(e.msg)")
end
```

## Performance Notes

- **Caching**: Use `serialize_spec()` to avoid reparsing large .sl files
- **Large Candidates**: No limit on expression size; string-based representation
- **Solver Integration**: This module generates queries; actual solving is external

## License

Same as CEGIS parent package.
