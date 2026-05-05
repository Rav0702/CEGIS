# Z3 Query Construction Search - Summary

## Search Completed Successfully

This document summarizes the findings from a comprehensive search of the CEGIS codebase for Z3 query construction, get-value command building, type declarations, and error handling.

## Files Generated

1. **Z3_QUERY_ANALYSIS.md** (420 lines)
   - Comprehensive detailed analysis of all Z3 query construction components
   - Includes code snippets for each major function
   - Complete file paths and line number mapping

2. **Z3_QUERY_QUICK_REFERENCE.txt** (139 lines)
   - Quick lookup reference for developers
   - Call chain overview
   - Key location indices
   - Error handling details

## Key Findings Summary

### 1. Get-Value Command Construction
All three types of `(get-value ...)` commands are constructed in:
- **File**: `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl`
- **Function**: `generate_query()` at lines 179-308
- **Specific lines**:
  - Free variables: **Lines 282-288**
  - Candidate output: **Lines 290-297**
  - Spec output: **Lines 299-305**

### 2. Get-Value Line Construction Details
- **Variable lists** built via `join()` of variable names (lines 286, 295)
- **Fresh constants** named using `get_fresh_const_name()` (line 302)
- **Function call values** extracted using function name + free variable arguments (line 296)
- **Pattern**: Three separate `push!()` calls per get-value type

### 3. Type System & Conversions
Sophisticated type tracking with two levels:

**Query Level** (query.jl):
- Bool detection via operator check (lines 133-148)
- Bool→Int wrapping: `(ite expr 1 0)` pattern (lines 153-158)

**Parser Level** (candidates.jl):
- Abstract base: `AbstractCandidateParser` (line 34)
- Two implementations:
  - `InfixCandidateParser` - strict typing (lines 220-242)
  - `SymbolicCandidateParser` - type-aware (lines 262-452)
- Typed AST: `IntExpr` and `BoolExpr` (lines 272-280)
- Operator type tags: `:bool` vs `:int` (lines 296-302)

### 4. "Z3 Status:" Message
**Location**: `/Users/howie/.julia/dev/CEGIS/src/Oracles/z3_oracle.jl:151`
```julia
println("  Z3 Status: $(result.status)")
```

**Status Values** (z3_verify.jl:20-23):
- `:sat` - Counterexample found
- `:unsat` - Valid candidate
- `:unknown` - Z3 error (type mismatch)

**Error Context**: Lines 143-169 show error handling with type mismatch detection

### 5. Full SMT-LIB2 Query Building
Complete pipeline with 10 stages:

1. Set logic (line 187)
2. Set options (line 188)
3. Add preamble (lines 191-198)
4. Declare free variables (lines 201-207)
5. Define synthesis functions (lines 213-230)
6. Declare fresh constants (lines 236-241)
7. Assert spec constraints (lines 247-263)
8. Assert candidate violation (lines 267-277)
9. Add check-sat (line 280)
10. Add get-value commands (lines 282-305)

**Entry Point**: `generate_cex_query()` (CEXGeneration.jl:80-88)
**Main Builder**: `generate_query()` (query.jl:179-308)
**Executor**: `verify_query()` (z3_verify.jl:161-194)

## Query Call Chain

```
extract_counterexample() [z3_oracle.jl:108-211]
    ↓
to_smt2(parser, candidate) [candidates.jl:51-502]
    ↓
generate_cex_query(spec, candidates) [CEXGeneration.jl:80-88]
    ↓
generate_query(spec, smt_candidates) [query.jl:179-308]
    ↓
verify_query(query) [z3_verify.jl:161-194]
    ↓
_parse_get_value_output(output) [z3_verify.jl:52-75]
```

## Important Implementation Details

### Fresh Constants
- **Naming pattern**: "out_" + synthesis_function_name
- **Examples**: max3 → out_max3, guard_fn → out_guard_fn
- **Purpose**: Represent "what the spec says is valid at this input"
- **Declared**: Line 240 (declare-const command)
- **Used in constraints**: Line 258 (substitution replaces function calls)

### Parameter Substitution
Two key substitution functions:

1. **`substitute_params()`** [query.jl:107-125]
   - Replaces free variables with function parameters
   - Uses word boundary matching (`\b...\b`)

2. **`substitute_synth_calls()`** [query.jl:40-90]
   - Replaces function calls with fresh constants
   - Tracks parenthesis depth for proper matching

### Model Parsing
**`_parse_get_value_output()`** [z3_verify.jl:52-75]
- Tokenizes Z3 output
- Recursively collects key-value pairs
- Parses numerals with bool→int conversion
- Normalizes keys for lookup

## File Locations (Absolute Paths)

All relative to: `/Users/howie/.julia/dev/CEGIS/`

| Component | Path | Lines |
|-----------|------|-------|
| Query generation entry | src/CEXGeneration/CEXGeneration.jl | 80-88 |
| Full query builder | src/CEXGeneration/query.jl | 179-308 |
| Candidate parser | src/CEXGeneration/candidates.jl | 500-502 |
| Query executor | src/CEXGeneration/z3_verify.jl | 161-194 |
| Oracle interface | src/Oracles/z3_oracle.jl | 108-211 |

## Documents Provided

1. **Z3_QUERY_ANALYSIS.md** - Complete technical reference
2. **Z3_QUERY_QUICK_REFERENCE.txt** - Quick lookup guide
3. **SEARCH_SUMMARY.md** - This summary document

## Code Examples

### Fresh Constant in Action
```julia
# From query.jl line 239-240:
fresh_name = get_fresh_const_name(sfun)  # e.g., "out_max3"
push!(query_parts, "(declare-const $fresh_name $(sfun.sort))")

# From query.jl line 302-303:
push!(query_parts, "(get-value ($fresh_name))")
```

### Get-Value Output Example
```
Z3 query includes:
  (check-sat)
  (get-value (x y z))
  (get-value ((max3 x y z)))
  (get-value (out_max3))

Z3 response:
  sat
  ((x 1) (y 0) (z 0))
  (((max3 x y z) 0))
  ((out_max3 1))
```

### Type Coercion Example
```julia
# From candidates.jl line 316-324:
if result_type == :int
    lhs_int = _bool_to_int(lhs)  # Wraps Bool in (ite expr 1 0)
    rhs_int = _bool_to_int(rhs)
    smt = "($(smt_op) $(lhs_int.smt) $(rhs_int.smt))"
    lhs = IntExpr(smt)
end
```

## Search Methodology

- Used grep for pattern matching ("get-value", "Z3 Status:", etc.)
- Used glob for file discovery (*.jl pattern)
- Traced call chains through function definitions
- Analyzed type system and parser implementations
- Cross-referenced with test output files

## Related Files Examined

- Test outputs: test_output_full.txt (shows actual get-value commands)
- Benchmark results: spec_files/phase3_benchmarks/result_*.txt
- Example queries: scripts/query*.smt2

---

**Date**: April 6, 2026
**Status**: Complete
**Query Scope**: Full Z3 query pipeline from candidate to Z3 execution

For detailed information, see the comprehensive analysis documents.
