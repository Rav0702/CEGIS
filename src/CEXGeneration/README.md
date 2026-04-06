# CEXGeneration

Counterexample query generation for SyGuS-v2 specifications.

## Overview

CEXGeneration handles the core task of converting SyGuS-v2 specifications and candidate solutions into SMT-LIB2 queries that can be verified by SMT solvers. It bridges the gap between the high-level synthesis problem specification and low-level SMT solver interactions.

## Key Components

- **types.jl** — Core data structures (`Spec`, `SynthFun`, `FreeVar`) representing parsed SyGuS specifications
- **sexp.jl** — S-expression lexing, parsing, and serialization utilities for handling SMT-LIB2 format
- **parser.jl** — SyGuS-v2 specification parser that reads `.sl` files and constructs complete `Spec` objects
- **candidates.jl** — Candidate solution parser that converts infix mathematical expressions to SMT-LIB2 prefix notation
- **query.jl** — SMT-LIB2 query generation and variable substitution logic
- **z3_verify.jl** — Z3 solver integration for counterexample verification

## Main Workflow

1. **Parse specification**: Read a `.sl` SyGuS file using `parse_spec_from_file()`
2. **Generate query**: Convert candidate solution and constraints to SMT-LIB2 format using `generate_cex_query()`
3. **Submit to solver**: Send the query to Z3 to find counterexamples
4. **Extract results**: Parse solver output to determine if candidate is valid or obtain counterexample

## Key API

- `parse_spec_from_file(filename::String)` — Parse `.sl` file to `Spec` object
- `generate_cex_query(spec::Spec, candidates::Dict{String,String})` — Generate SMT-LIB2 query for verification
- `candidate_to_smt2(src::String)` — Convert infix candidate expression to SMT-LIB2 prefix notation
- `verify_query(query::String)` — Execute query with Z3 and return result
- `serialize_spec()` / `deserialize_spec()` — Persistence for specifications

## Design Notes

- Automatically expands `inv-constraints` to pre/trans/post safety properties
- Supports all SyGuS-v2 logical contexts (LIA, BV, Arrays, etc.)
- Maintains ordered preamble for Z3 compatibility
- Handles recursive function definitions and datatype declarations
