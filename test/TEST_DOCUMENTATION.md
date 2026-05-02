# CEGIS Unit Tests Documentation

## Overview

This document describes the unit tests for CEGIS, covering both parsing utilities and end-to-end synthesis functionality.

## Test Files

### 1. `test_parsing_utilities.jl`
Comprehensive unit tests for critical parsing and utility methods used throughout CEGIS.

#### Test Coverage

##### File Location (`find_spec_file`)
- ✅ Locates spec files in phase3_benchmarks directory
- ✅ Locates spec files in main spec_files directory  
- ✅ Throws error on missing spec files
- **Purpose**: Ensures test infrastructure can reliably find specification files

##### Solution Matching (`solution_matches`)
- ✅ Exact string matching
- ✅ Whitespace normalization (multi-space to single space)
- ✅ Detects mismatches correctly
- **Purpose**: Validates solution comparison logic works across different formatting styles

##### SyGuS Spec Parsing
- ✅ Validates required keywords (set-logic, synth-fun, constraint)
- ✅ Checks for define-fun helper functions when present
- ✅ Confirms spec files are valid SyGuS-v2 format
- **Purpose**: Ensures specification files are well-formed before synthesis

##### Grammar Building (`build_grammar_from_spec`)
- ✅ Creates valid AbstractGrammar objects
- ✅ Handles specs with various operation sets (arithmetic, comparison, conditional)
- ✅ Correctly includes conditional operators (ifelse) when needed
- ✅ Processes define-fun helper functions
- **Purpose**: Tests core grammar construction pipeline

##### CEGISProblem Construction
- ✅ Creates problem instances with spec path
- ✅ Supports optional desired_solution parameter
- ✅ Initializes state correctly
- ✅ Throws error on missing spec files
- **Purpose**: Validates problem specification container

##### Iterator Configuration
- ✅ Creates BFS iterators with configurable depth
- ✅ Iterators are usable in loops
- ✅ Supports multiple depth configurations
- **Purpose**: Tests synthesis space exploration configuration

##### RuleNode to String Conversion (`solution_to_string`)
- ✅ Converts RuleNode programs to readable strings
- ✅ Produces valid Julia expressions
- **Purpose**: Ensures solution output is human-readable

##### Spec Format Variations
- ✅ Arithmetic (basic LIA)
- ✅ Maximum (comparison operators)
- ✅ Guard (if-then-else logic)
- ✅ Define-fun (helper functions)
- **Purpose**: Validates parser handles diverse specification types

##### Run Synthesis Helper
- ✅ Completes without errors
- ✅ Returns valid CEGISResult
- ✅ Tracks iterations correctly
- **Purpose**: Integration test for synthesis wrapper function

##### Grammar Determinism
- ✅ Multiple builds produce identical grammars
- **Purpose**: Ensures reproducible grammar construction

##### Error Handling
- ✅ Meaningful errors for missing specs
- ✅ Handles empty string comparisons gracefully
- **Purpose**: Validates robustness and user feedback

##### Spec File Content Validation
- ✅ Arith spec contains required keywords
- ✅ Max spec contains required keywords
- ✅ Define-sum spec contains all required components
- **Purpose**: Ensures test specs are valid before testing against them

### 2. `test_e2e_synthesis.jl`
End-to-end synthesis tests on real specifications.

#### Test Coverage

##### Arithmetic (2*x + y)
- ✅ Synthesizer finds correct solution
- ✅ Solution contains arithmetic operations
- **Purpose**: Tests basic arithmetic synthesis

##### Maximum of Two
- ✅ Synthesizer finds solution using conditional logic
- ✅ Solution contains ifelse operator
- **Purpose**: Tests conditional operator synthesis

##### Guard with If-Then-Else
- ✅ Synthesizer handles complex guards
- ✅ Returns valid program
- **Purpose**: Tests advanced control flow

##### Find-Index with Boundaries
- ✅ Synthesizer finds indexing logic
- ✅ Handles boundary conditions
- **Purpose**: Tests array/indexing synthesis

##### Conditional Sum
- ✅ Synthesizer combines conditions with aggregation
- **Purpose**: Tests complex specification patterns

##### Simple Define-Sum (x + y)
- ✅ Correctly uses define-fun helper functions
- ✅ Uses parameter names from function definition
- **Purpose**: Tests helper function handling

##### Maximum of Three (Complex)
- ✅ Attempts complex multi-variable synthesis
- **Purpose**: Tests scalability to harder problems

##### Symmetric Maximum
- ✅ Handles symmetric constraints
- **Purpose**: Tests constraint handling

## Test Statistics

- **Total Tests**: 94
- **Parsing & Utilities**: 75 tests (13 test groups)
- **E2E Synthesis**: 19 tests (8 test groups)
- **Estimated Runtime**: ~1.5 minutes
- **All tests passing**: ✅

## Running Tests

### Run all tests
```bash
julia --project test/runtests.jl
```

### Run only unit tests
```bash
julia --project test/test_parsing_utilities.jl
```

### Run only e2e tests
```bash
julia --project test/test_e2e_synthesis.jl
```

## Key Test Insights

### Parsing Robustness
The unit tests confirm that CEGIS can robustly parse diverse SyGuS-v2 specifications with:
- Different logical theories (LIA, UFLIA)
- Various operation sets (arithmetic, comparison, conditional)
- Helper functions (define-fun)
- Complex constraints

### Grammar Construction Reliability
Grammar building is deterministic and handles all specification types correctly, including:
- Automatic operation selection based on spec requirements
- Correct inclusion of conditional operators
- Support for helper function declarations

### Solution Matching Flexibility
The solution comparison utility normalizes whitespace, allowing tests to verify correctness regardless of expression formatting.

### Error Handling Quality
Good error messages guide users when specs are missing or malformed.

## Future Improvements

Potential areas for expanded testing:
1. **Parser error recovery**: Test handling of malformed specs
2. **Performance regression tests**: Benchmark against baseline times
3. **Larger specifications**: Test with real-world SyGuS benchmarks
4. **Oracle verification**: Unit tests for oracle components (Z3, IO examples)
5. **Counterexample generation**: Tests for CEX minimization and generalization

## Debugging Tests

If a test fails, check:
1. Spec file exists and is valid: `julia -e "using Test; include(\"test/test_helpers.jl\"); println(find_spec_file(\"NAME\"))"`
2. Grammar builds correctly: `julia --project -e "include(\"src/CEGIS.jl\"); g=CEGIS.build_grammar_from_spec(\"path\"); println(g)"`
3. Solution comparison: Check whitespace in expected vs actual solutions
4. Iterator configuration: Verify max_depth is reasonable for the problem size

## Test Maintenance

- Update tests when adding new specification types
- Add regression tests when bugs are found
- Keep expected solutions synchronized with grammar rules
- Verify tests complete within reasonable time (~2 minutes for full suite)
