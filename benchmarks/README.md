# Benchmark Suite

This directory contains the SyGuS benchmark problems used by the CEGIS project.

## Layout

Each problem lives in its own subdirectory and follows the same structure:

- `easy.sl` - smaller specification for quick checks
- `medium.sl` - moderate specification for regression testing
- `hard.sl` - larger specification for stress testing
- `README.md` - problem-specific notes and expected behavior

## Current Problems

- `abs_value/` - absolute value
- `clamp_value/` - clamp a value to bounds
- `conditional_sum/` - conditional sum or branch-based arithmetic
- `find_max_three/` - maximum of three integers
- `max_two/` - maximum of two integers
- `sign_function/` - sign classification

## Notes

- The benchmark specs are SyGuS problems in the CLIA/LIA style used by the project.
- See the README in each problem directory for the most accurate description of that benchmark.
- `validate_benchmarks.jl` is available for benchmark validation.

## Adding a New Benchmark

1. Create a new directory under `benchmarks/`.
2. Add `easy.sl`, `medium.sl`, and `hard.sl` specs if the problem uses the same difficulty split.
3. Add a short README that describes the actual spec and expected solution shape.
