# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Setup
```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

### Running Tests
Tests use `ReTestItems`:
```bash
julia --project=. test/runtests.jl
```

Run a single test item by name:
```bash
julia --project=. -e 'using ReTestItems; runtests("CEGIS"; name="CEGIS Parsing")'
```

Run all tests with verbose output:
```bash
julia --project=. -e 'using ReTestItems; runtests("CEGIS"; verbose=true)'
```

## Architecture

### CEGIS Loop (`oracle_synth.jl`)

The synthesis loop lives in `synth_with_oracle`. It:
1. Starts with an empty `Problem(IOExample[])`.
2. Enumerates candidates from the iterator.
3. Evaluates each candidate against the accumulated IO examples.
4. When a candidate passes all examples, queries the oracle via `extract_counterexample`.
5. If a counterexample is found: converts it to `IOExample`, appends to spec, continues.
6. If `nothing` returned: candidate is formally verified — returns `CEGISResult(cegis_success, ...)`.

`run_synthesis(problem::CEGISProblem, iterator)` is the recommended entry point. It lazy-initializes the oracle from the spec file, then delegates to `synth_with_oracle`. `run_synthesis(problem::Problem, iterator)` is a passthrough to `HerbSearch.synth`.

### Module Dependency Order

```
CEXGeneration (standalone, uses Z3)
    ↓
Oracles (uses CEXGeneration for Z3Oracle)
    ↓
Parsers, GrammarBuilding, OracleFactories, IteratorConfig (peer modules)
    ↓
oracle_synth.jl (top-level synthesis loop)
```

### Key Types (`types.jl`)

- `CEGISProblem` — lightweight problem: `spec_path::String`, `desired_solution`, lazy `spec`/`oracle`. Constructed with `CEGISProblem("path.sl"; desired_solution="...")`.
- `CEGISResult` — `status::CEGISStatus`, `program::Union{RuleNode,Nothing}`, `iterations::Int`, `counterexamples::Vector{Counterexample}`.
- `Counterexample` — `input::Dict{Symbol,Any}`, `expected_output`, `actual_output`.
- `CEGISStatus` — `cegis_success | cegis_failure | cegis_timeout`.

### Oracles (`src/Oracles/`)

Both implement `extract_counterexample(oracle, problem, candidate::RuleNode) → Union{Counterexample, Nothing}`.

- **`Z3Oracle`** — Formal verification via Z3. Parses the `.sl` spec into a `CEXGeneration.Spec`, converts candidates to SMT-LIB2, calls Z3, extracts model values on `:sat`. Two candidate-conversion paths: default multi-stage (`RuleNode → Expr → String → SMT-LIB2` via `InfixCandidateParser`) or direct (`RuleNode → SMT-LIB2` via `rulenode_to_smt2`, enabled with `use_direct_conversion=true`).
- **`IOExampleOracle`** — Evaluates the candidate against a fixed `Vector{IOExample}` via `HerbInterpret`. Returns the first failing example.

### CEXGeneration Module (`src/CEXGeneration/`)

A self-contained sub-module that handles SyGuS v2 `.sl` parsing and SMT-LIB2 query generation.

- `parse_spec_from_file(path) → Spec` — Parses `.sl` into `Spec` (contains `synth_funs`, `free_vars`, `constraints`, `logic`).
- `generate_cex_query(spec, candidates::Dict{String,String}) → String` — Builds a complete SMT-LIB2 check-sat query with candidate substituted for the synthesis target.
- `verify_query(query::String) → Z3Result` — Runs Z3 on the query; returns `Z3Result` with `.status ∈ {:sat, :unsat, :unknown}` and `.model`.
- `rulenode_to_smt2(node, grammar) → String` — Direct `RuleNode → SMT-LIB2` conversion with type tracking (`:int` / `:bool`); applies `(ite cond 1 0)` for Bool→Int coercion.

### Grammar Building (`src/GrammarBuilding/`)

`build_generic_grammar(spec, config::GrammarConfig)` generates a `@csgrammar` string dynamically and evaluates it in `HerbGrammar` context.

The generated grammar uses two non-terminals:
- `Expr` — integer expressions, also includes a `Expr = BoolExpr` coercion rule.
- `BoolExpr` — boolean expressions (comparisons only; logical AND/OR use nested `ifelse`).

Predefined operation sets: `BASE_OPERATIONS`, `LIA_OPERATIONS`, `EXTENDED_OPERATIONS`, `STRING_OPERATIONS`, `BITVECTOR_OPERATIONS`. `build_grammar_from_spec(path)` auto-detects LIA problems and selects the appropriate set.

Variables for the grammar are extracted from **synth-fun parameters** (not all `declare-var` statements, which are constraint-only in SyGuS).

### Spec Files

- `spec_files/phase3_benchmarks/` — Primary test specs: `arith_simple`, `max2_simple`, `max3_simple`, `guard_simple`, `fnd_sum_simple`, `simple_define_sum`, `symmetric_max`.
- `spec_files/` — Additional one-off specs.
- `benchmarks/` — Organized by problem category (abs_value, max_two, etc.) with easy/medium/hard difficulties.

Test helpers in `test/test_helpers.jl` provide `find_spec_file(name)` which searches both locations, `run_spec_synthesis(spec_path; ...)` as a synthesis convenience wrapper, and `solution_to_string` / `solution_matches` for result comparison.

### Adding a New Oracle

1. Subtype `AbstractOracle` in `src/Oracles/`.
2. Implement `extract_counterexample(oracle::MyOracle, problem, candidate::RuleNode)`.
3. Include the file in `src/Oracles/Oracles.jl` and export.
4. Optionally add a factory in `src/OracleFactories/AbstractFactory.jl`.
