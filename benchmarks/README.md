# CEGIS Benchmark Suite

Comprehensive benchmark suite for program synthesis using the CEGIS (Counterexample-Guided Inductive Synthesis) approach.

## Overview

This directory contains carefully curated benchmark problems organized by difficulty level, all using the **CLIA (Conditional Linear Integer Arithmetic)** logic from the SyGuS competition.

### Structure

Each problem has its own directory containing:
- **`easy.sl`** - Simplified specification for quick baseline testing
- **`medium.sl`** - Extended specification with additional properties
- **`hard.sl`** - Complex specification with advanced mathematical properties
- **`README.md`** - Detailed problem description, solutions, and benchmarking notes

## Problem Categories

### 1. **Maximum Functions**
- **Directory**: `max_two/`
- **Description**: Find the maximum of two integers
- **Difficulty**: Easy < Medium < Hard
- **Key Properties**: Comparison, Idempotence, Commutativity

### 2. **Absolute Value**
- **Directory**: `abs_value/`
- **Description**: Compute absolute value of an integer
- **Difficulty**: Easy < Medium < Hard
- **Key Properties**: Non-negativity, Symmetry, Triangle Inequality

### 3. **Conditional Sum**
- **Directory**: `conditional_sum/`
- **Description**: Conditional aggregation with multiple branches
- **Difficulty**: Easy < Medium < Hard
- **Key Properties**: Branching logic, Nested conditions, Multi-variable constraints

### 4. **Maximum of Three**
- **Directory**: `find_max_three/`
- **Description**: Find maximum of three integers
- **Difficulty**: Easy < Medium < Hard
- **Key Properties**: Commutativity, Associativity, Transitivity, Ordering

### 5. **Sign Function**
- **Directory**: `sign_function/`
- **Description**: Classify value as negative (-1), zero (0), or positive (1)
- **Difficulty**: Easy < Medium < Hard
- **Key Properties**: Classification, Antisymmetry, Multiplication properties

### 6. **Clamp Value**
- **Directory**: `clamp_value/`
- **Description**: Constrain value to bounds with fixed or variable ranges
- **Difficulty**: Easy < Medium < Hard
- **Key Properties**: Range enforcement, Monotonicity, Idempotence

## Benchmark Categories by Difficulty

### Easy Problems
- **Synthesis space**: Small
- **Expected time**: < 1 second
- **Use case**: Testing basic synthesis pipeline, quick regression tests
- **Examples**: max_two/easy.sl, abs_value/easy.sl

### Medium Problems
- **Synthesis space**: Medium
- **Expected time**: 1-10 seconds
- **Use case**: Feature verification, property testing
- **Examples**: max_two/medium.sl, conditional_sum/medium.sl

### Hard Problems
- **Synthesis space**: Large (100K+ candidates)
- **Expected time**: 10-120 seconds
- **Use case**: Performance benchmarking, stress testing, solver evaluation
- **Examples**: find_max_three/hard.sl, clamp_value/hard.sl

## SyGuS Logic Track

All specifications use **LIA (Linear Integer Arithmetic)** with conditional logic:

### Supported Operators
- **Arithmetic**: `+`, `-`, `*`
- **Comparison**: `>`, `>=`, `<`, `<=`, `=`
- **Logical**: `and`, `or`, `not`, `=>`
- **Conditional**: `ifelse` / `ite`
- **Constants**: Integer literals

### Example Specification
```smt
(set-logic LIA)

(synth-fun max2 ((x Int) (y Int)) Int)

(declare-var x Int)
(declare-var y Int)

(constraint (>= (max2 x y) x))
(constraint (>= (max2 x y) y))
(constraint (or (= x (max2 x y)) (= y (max2 x y))))

(check-synth)
```

## Running Benchmarks

### Test Single Problem
```bash
julia --project
julia> include("src/CEGIS.jl")
julia> problem = CEGIS.CEGISProblem("benchmarks/max_two/easy.sl")
julia> grammar = CEGIS.build_grammar_from_spec("benchmarks/max_two/easy.sl")
julia> result = CEGIS.run_synthesis(problem, iterator)
```

### Benchmark Suite Script
Example script to run all benchmarks:

```julia
using BenchmarkTools

benchmarks = [
    ("max_two", ["easy", "medium", "hard"]),
    ("abs_value", ["easy", "medium", "hard"]),
    ("conditional_sum", ["easy", "medium", "hard"]),
    ("find_max_three", ["easy", "medium", "hard"]),
    ("sign_function", ["easy", "medium", "hard"]),
    ("clamp_value", ["easy", "medium", "hard"]),
]

for (problem, difficulties) in benchmarks
    for difficulty in difficulties
        spec_path = "benchmarks/$problem/$difficulty.sl"
        @time run_synthesis(spec_path)
    end
end
```

## Benchmark Metrics

Track these metrics for each problem:
- **Time**: Wall-clock synthesis time
- **Enumerated**: Number of candidates explored
- **Iterations**: CEGIS loop iterations
- **Counterexamples**: Number of CEX generated
- **Grammar size**: Number of production rules

## Expected Solutions

All problems have known solutions (provided in README files):

- `max_two`: `ifelse(x > y, x, y)`
- `abs_value`: `ifelse(x >= 0, x, -(x))`
- `conditional_sum`: `ifelse((x + y) >= 10, x + y, 0)`
- `find_max_three`: Nested three-way max
- `sign_function`: `ifelse(x > 0, 1, ifelse(x = 0, 0, -1))`
- `clamp_value`: `ifelse(x < min, min, ifelse(x > max, max, x))`

## Benchmarking Best Practices

1. **Warm-up**: Run once to compile before timing
2. **Repetition**: Run multiple times and report mean/median
3. **System state**: Close other applications during measurement
4. **Documentation**: Record Julia version, hardware, and any configuration changes
5. **Comparison**: Always compare against baseline on same hardware

## Adding New Problems

To add a new benchmark problem:

1. Create a new directory: `mkdir benchmarks/problem_name`
2. Create specification files:
   - `easy.sl` - Basic problem
   - `medium.sl` - Extended constraints
   - `hard.sl` - Complex properties
3. Create `README.md` with:
   - Problem description
   - Difficulty breakdown
   - Expected solutions
   - Grammar requirements
   - Benchmarking notes

## Performance Targets

Recommended baseline performance (will vary by hardware):

| Problem | Easy | Medium | Hard |
|---------|------|--------|------|
| max_two | <0.5s | 1-3s | 5-15s |
| abs_value | <0.5s | 1-3s | 5-20s |
| conditional_sum | <1s | 2-5s | 10-60s |
| find_max_three | 1-3s | 3-10s | 15-120s |
| sign_function | <0.5s | 1-5s | 5-20s |
| clamp_value | <0.5s | 2-5s | 10-60s |

## Related Resources

- SyGuS Competition: http://www.sygus.org
- SyGuS-IF 2.1 Specification: http://sygus.org/language
- CEGIS Original Paper: "Program Synthesis by Sketching" (Solar-Lezama et al., 2008)

## Contributing

To contribute new benchmarks:
1. Ensure all three difficulty levels are present
2. Verify specifications are valid SyGuS-LIA
3. Include comprehensive README
4. Document expected solutions clearly
5. Test with CEGIS implementation

## License

Same as CEGIS project

## Notes

- All problems use deterministic test cases
- Solutions should be reproducible and verified
- Use problems for regression testing after changes
- Monitor performance trends over time
