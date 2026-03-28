# Z3 SMT CEGIS: Implementation Status Report

**Date**: March 28, 2026  
**Purpose**: Comprehensive status of z3_smt_cegis implementation  
**Audience**: Users, contributors, maintainers

---

## Executive Summary

`z3_smt_cegis` is a **production-ready** program synthesis tool that combines:
- **Grammar-based candidate enumeration** (HerbCore/HerbSearch)
- **Formal SMT verification** (Z3 native API)
- **Counterexample-guided learning** (CEGIS loop)

The system is modular, well-tested, and functional. Core components are production-ready; some advanced features are experimental.

---

## Component Status Matrix

### ✅ Production-Ready Components

| Component | File(s) | Lines | Status | Purpose |
|-----------|---------|-------|--------|---------|
| **z3_smt_cegis Script** | scripts/z3_smt_cegis.jl | 380 | ✅ Complete | Main synthesis driver with grammar building, oracle setup, result reporting |
| **Z3Oracle Type** | src/Oracles/z3_oracle.jl | 200+ | ✅ Complete | SMT-based oracle implementing extract_counterexample() verification pipeline |
| **CEXGeneration Module** | src/CEXGeneration/ | 1000+ | ✅ Complete | Modular spec parsing, query generation, Z3 verification (6 files) |
| **oracle_synth** | src/oracle_synth.jl | 150+ | ✅ Complete | CEGIS loop orchestration (Synthesizer → Verifier → Learner) |
| **IOExampleOracle** | src/Oracles/ioexample_oracle.jl | 80+ | ✅ Complete | Alternative oracle for fixed test-based verification |
| **Synthesizer** | src/synthesizer.jl | 100+ | ✅ Complete | Grammar-based candidate enumeration by depth/breadth |
| **Learner** | src/learner.jl | 120+ | ✅ Complete | Constraint extraction from counterexamples, grammar updates |
| **Verifier** | src/verifier.jl | 80+ | ✅ Complete | Verification interface and result reporting |

### 🟡 Experimental/Partial Components

| Component | File(s) | Status | Notes |
|-----------|---------|--------|-------|
| **Z3OracleDirect** | src/Oracles/z3_oracle_direct.jl | 🟡 Experimental | Direct Z3 AST building (avoids string parsing); not integrated |
| **SemanticSMTOracle** | src/Oracles/semantic_smt_oracle.jl | 🟡 Legacy | SymbolicSMT-based verification; slower than Z3Oracle |
| **Archive Scripts** | archive/*.jl | 🟡 Reference | Historical/placeholder scripts useful for understanding evolution |

---

## Feature Completeness

### Core Features (✅ All Implemented)

- [x] SyGuS-v2 specification parsing
- [x] SyGuS inv-constraint expansion (pre/trans/post decomposition)
- [x] Grammar building from spec variables and operators
- [x] RuleNode to SMT-LIB2 conversion with type checking
- [x] Pluggable candidate parser strategy (Infix vs Symbolic)
- [x] SMT-LIB2 query generation with constraint negation
- [x] Z3 native verification (no subprocess calls)
- [x] Model extraction from Z3 responses
- [x] Counterexample generation with expected vs actual values
- [x] CEGIS loop orchestration
- [x] Enumeration-based synthesis with depth limits
- [x] Constraint learning and grammar updates
- [x] Command-line interface with argument parsing
- [x] Test candidate feature (verify and test provided candidates)
- [x] Result reporting and statistics

### Advanced Features (🟡 Partial or Experimental)

- [x] Multiple oracle types (Z3Oracle, IOExampleOracle, SemanticSMTOracle)
- [x] Serialization/deserialization of Spec objects
- [x] Custom interpreter support (CustomInterpreterOracle)
- [x] Debug output and enumeration tracking
- [⚠️] Z3OracleDirect (not integrated; experimental)
- [⚠️] Performance profiling (no built-in profiler annotations)
- [⚠️] Scaling to large grammars (untested beyond medium size)

---

## Module Architecture

### CEXGeneration Module Structure

**Location**: `src/CEXGeneration/`

| File | Size | Purpose |
|------|------|---------|
| `CEXGeneration.jl` | 80 lines | Module aggregator and public API export |
| `types.jl` | 100 lines | Spec, SynthFun, FreeVar data structures |
| `sexp.jl` | 200 lines | S-expression parsing and serialization |
| `parser.jl` | 250 lines | SyGuS-v2 specification parser with inv-constraint handling |
| `candidates.jl` | 150 lines | Infix ↔ SMT-LIB2 conversion with type checking (2 parsers) |
| `query.jl` | 130 lines | Query generation, constraint negation, model substitution |
| `z3_verify.jl` | 100 lines | Z3 native verification, model extraction |
| `README.md` | 300+ lines | Complete module documentation and examples |

**Public API** (Main exports):
```julia
parse_spec_from_file(filename::String) → Spec
generate_cex_query(spec::Spec, candidates::Dict) → String (SMT-LIB2)
verify_query(query::String) → Z3Result{status, model}
candidate_to_smt2(src::String) → String (SMT-LIB2)
```

### Oracles Module Structure

**Location**: `src/Oracles/`

| File | Purpose | Status |
|------|---------|--------|
| `Oracles.jl` | Module aggregator | ✅ Complete |
| `abstract_oracle.jl` | AbstractOracle interface definition | ✅ Complete |
| `z3_oracle.jl` | Z3-based SMT verification oracle | ✅ Production |
| `z3_oracle_direct.jl` | Direct Z3 AST oracle (experimental) | 🟡 Experimental |
| `semantic_smt_oracle.jl` | SymbolicSMT-based oracle (legacy) | 🟡 Legacy |
| `ioexample_oracle.jl` | Test-based verification oracle | ✅ Production |

---

## Z3Oracle Implementation Details

### Constructor & Fields

```julia
mutable struct Z3Oracle <: AbstractOracle
    spec_file::String
    spec::Any                                    # CEXGeneration.Spec
    grammar::AbstractGrammar
    z3_ctx::Z3.Context
    z3_vars::Dict{String, Z3.Expr}
    mod::Module
    enum_count::Int                              # Enumeration tracking
    test_candidate::Union{String, Nothing}       # Optional test candidate
    parser::CEXGeneration.AbstractCandidateParser # Pluggable parser
end
```

**Location**: [src/Oracles/z3_oracle.jl:40-49](src/Oracles/z3_oracle.jl#L40-L49)

### Core Method: `extract_counterexample()`

**Location**: [src/Oracles/z3_oracle.jl:110-180+](src/Oracles/z3_oracle.jl#L110)

**Pipeline**:
1. Convert RuleNode candidate to Julia Expr
2. Apply pluggable parser (InfixCandidateParser or SymbolicCandidateParser)
3. Convert Expr to SMT-LIB2 string
4. Generate full SMT-LIB2 query via CEXGeneration.generate_cex_query()
5. Verify with Z3 native API via CEXGeneration.verify_query()
6. Extract model from Z3 response
7. Build Counterexample with input dict, expected output, and actual output
8. Return Counterexample if found; nothing if verified

### Candidate Parsers

**Default**: InfixCandidateParser
- Strict SMT-LIB2 type checking
- Rejects mixed bool-numeric operations
- Best for problems with clear type separation

**Alternative**: SymbolicCandidateParser  
- Enables mixed bool-numeric via ITE coercion: `(ite (bool_expr) 1 0)`
- Required for problems with mixed-type expressions
- Used by default in z3_smt_cegis.jl (already configured)

**Selection**: Pass as keyword argument to Z3Oracle constructor:
```julia
oracle = Z3Oracle(spec_file, grammar, parser=CEXGeneration.InfixCandidateParser())
```

---

## CEXGeneration Query Generation Strategy

### Query Structure

**Location**: [src/CEXGeneration/query.jl](src/CEXGeneration/query.jl)

When generating verification queries:

1. **Constraint Negation**: Asserts `(not (and all_constraints))`
   - Rationale: SAT = counterexample found; UNSAT = all constraints satisfied
   - Alternative (rejected): Raw `(assert (and constraints))` caused spurious counterexamples in don't-care regions

2. **Spec Function Building**: Creates nested ITE from constraint implications
   - Extracts conditions and expected outputs from implications
   - Builds: `(define-fun func_spec (...) (ite cond1 out1 (ite cond2 out2 (ite cond3 out3 0))))`
   - Rationale: Provides ground truth for what output should be at each input

3. **Model Extraction**: Extracts both candidate output AND spec-expected output
   - If they differ at SAT assignment → real counterexample with correct expected value
   - Handles S-expression negatives: `(- 5)` not `-5`

---

## Test Specifications

**Location**: `spec_files/`

| File | Problem | Variables | Constraints | Notes |
|------|---------|-----------|-------------|-------|
| `findidx_problem.sl` | Sum finding | x1, x2, x3 | 3 implications | Standard test case |
| `findidx_2_simple.sl` | Sum finding | k, x0, x1 | 1 test | Quick validation |
| `findidx_2_problem.sl` | Sum variant | k, x0, x1, x2 | 3 implications | Larger problem |
| `findidx_5_problem.sl` | 5-variable sum | x1-x5 | 5+ implications | Stress test |
| `findidx_2_declare_fun.sl` | With uninterpreted function | k, x0, x1 | Helper function | Tests declare-fun support |
| `jmbl_fg_VC22_a.sl` | Industrial verification | Multiple | Complex | Real-world benchmark |

---

## CEGIS Loop Integration

### synth_with_oracle Entry Point

**Location**: [src/oracle_synth.jl:45-102](src/oracle_synth.jl#L45)

```julia
synth_with_oracle(
    grammar::AbstractGrammar,
    start_symbol::Symbol,
    oracle::AbstractOracle;
    max_depth::Int = 6,
    max_enumerations::Int = 50_000
) → (result, satisfied_examples)
```

**Loop Structure**:
```
For each iteration:
  1. Synthesizer: Enumerate next candidate RuleNode
  2. Verifier: Call oracle.extract_counterexample(candidate)
     - Returns Counterexample if found; nothing if verified
  3. If verified: Return success with candidate
  4. Learner: Learn constraint from counterexample
  5. Grammar: Add constraint to reduce search space
  6. Repeat with updated grammar
Until: Found valid candidate OR exhausted max_enumerations/max_depth OR timeout
```

---

## Script Usage

### Command-Line Interface

**Location**: [scripts/z3_smt_cegis.jl:345-410](scripts/z3_smt_cegis.jl#L345-L410)

```bash
julia z3_smt_cegis.jl [spec_file] [max_depth] [max_enumerations] [candidate_to_test]
```

**Arguments**:
- `spec_file` (optional, default: `../spec_files/findidx_problem.sl`)
- `max_depth` (optional, default: 6)
- `max_enumerations` (optional, default: 50,000)
- `candidate_to_test` (optional, for testing specific candidates)

**Examples**:
```bash
# Basic usage with default spec
julia z3_smt_cegis.jl

# Custom spec and depth
julia z3_smt_cegis.jl ../spec_files/findidx_2_simple.sl 4 100000

# Test a specific candidate
julia z3_smt_cegis.jl ../spec_files/findidx_problem.sl 6 50000 \
  "ifelse(x1 > 5, x1 + x2, x2 + x3)"
```

---

## Output & Results

### Result Structure

**Type**: `CEGISResult`  
**Fields**:
- `status::CEGISStatus` — `:success`, `:failure`, or `:timeout`
- `program::Union{RuleNode, Nothing}` — Synthesized program or nothing
- `iterations::Int` — Number of CEGIS iterations
- `counterexamples::Vector{Counterexample}` — All counterexamples found

### Counterexample Structure

**Type**: `Counterexample`  
**Fields**:
- `input::Dict{Symbol, Any}` — Variable assignments for input
- `expected_output::Any` — What spec says output should be
- `actual_output::Union{Any, Nothing}` — What candidate produced (if extracted)

---

## Documentation Status

### ✅ Well-Documented

- [CEXGeneration/README.md](../src/CEXGeneration/README.md) — 300+ lines of API reference and examples
- z3_smt_cegis.jl inline comments — Function docstrings and CEGIS step comments
- Z3Oracle comments — Constructor and method documentation

### 🔴 Needs Documentation

- Z3Oracle extraction pipeline rationale (why each step)
- End-to-end workflow walkthrough with examples
- Architecture diagram (ASCII or visual)
- Spec file format guide and examples
- Performance characteristics and tuning guidance
- Troubleshooting guide for common issues

---

## Known Issues & Limitations

### ✅ Resolved Issues

- Query negation now correctly finds counterexamples in don't-care regions
- Model parsing handles S-expression negatives correctly
- Pluggable parser avoids type errors in mixed bool-int problems

### 🟡 Current Limitations

1. **No GPU/Distributed Synthesis**: Single-threaded enumeration only
2. **Scaling**: Untested on grammars with >1000 rules
3. **Debug Output**: Limited profiling/tracing capabilities
4. **Uninterpreted Functions**: declare-fun syntax supported but limited verification of function bodies

### 🔮 Future Opportunities

1. Profile Z3OracleDirect vs Z3Oracle to assess string parsing overhead
2. Implement parallel enumeration for larger problems
3. Add incremental solving for repeated queries with similar constraints
4. Extend to LIA/NIA/BV logics beyond current QF_LIA focus

---

## Integration Points

### Dependencies

**Core Julia**:
- HerbCore (grammar and RuleNode)
- HerbGrammar (@csgrammar macro)
- HerbSearch (enumeration)
- HerbSpecification (not currently used but available)

**Verification**:
- Z3.jl (native Z3 API)
- SymbolicUtils.jl (symbol representations)
- SymbolicSMT.jl (for SemanticSMTOracle only)

**Test & Benchmark**:
- HerbBenchmarks.jl (integrated benchmark suites)

### Exported Public API (from CEGIS module)

```julia
# Main entry points
run_cegis()
run_ioexample_cegis()
synth_with_oracle()

# Oracle types
AbstractOracle
IOExampleOracle
Z3Oracle

# Support modules
CEXGeneration

# Result types
CEGISResult, CEGISStatus, Counterexample, VerificationResult
```

---

## Verification Checklist

- [x] z3_smt_cegis.jl runs successfully on findidx_problem.sl
- [x] Z3Oracle correctly implements extract_counterexample()
- [x] CEXGeneration parses all test specs without errors
- [x] Grammar building from spec variables works as expected
- [x] Candidate testing feature functional
- [x] All three oracle types (Z3Oracle, IOExampleOracle, SemanticSMTOracle) are accessible
- [x] Pluggable parser architecture working
- [x] Result reporting with counterexamples accurate
- [x] Exit codes properly reflect success/failure

---

## Recommendations

### For Users

1. **Start with**: findidx_2_simple.sl for quick validation
2. **Use SymbolicCandidateParser** if you have mixed-type expressions
3. **Tune max_depth** based on problem complexity (start with 4, increase if needed)
4. **Monitor counterexamples** to understand what's being learned

### For Contributors

1. **Before extending**: Read Z3_ORACLE_GUIDE.md and CEXGeneration/README.md
2. **Adding new oracles**: Extend AbstractOracle interface (see ioexample_oracle.jl)
3. **Modifying queries**: Understand constraint negation strategy (query.jl)
4. **Performance work**: Profile vs Z3OracleDirect before optimizing

### For Maintainers

1. **Keep Z3OracleDirect** as experimental until profiling shows bottleneck
2. **Maintain SemanticSMTOracle** for comparison studies
3. **Update docs** when adding new supported logics or SyGuS features
4. **Test all specs** in regression suite (findidx_*.sl suite)

---

## Summary Table

| Aspect | Status | Notes |
|--------|--------|-------|
| **Core Synthesis** | ✅ Production | Grammar enumeration + Z3 verification working |
| **Spec Parsing** | ✅ Production | SyGuS-v2 support, inv-constraint expansion |
| **Verification** | ✅ Production | Z3Oracle with pluggable parsers |
| **CEGIS Loop** | ✅ Production | Full oracle-driven synthesis |
| **Documentation** | 🟡 Partial | API docs present; workflow docs needed |
| **Performance** | 🟡 Untested | No profiling data yet; Z3OracleDirect experimental |
| **Scaling** | 🟡 Unknown | Works for medium problems; large grammar unknown |
| **Advanced Features** | 🟡 Some | Multiple oracles working; uninterpreted functions partial |

---

**Last Updated**: March 28, 2026  
**Status**: Production-Ready (Core) + Experimental (Advanced)  
**Roadmap**: [See ARCHITECTURE_OVERVIEW.md for next steps]
