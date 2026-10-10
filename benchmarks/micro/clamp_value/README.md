# Clamp Value Function

## Problem Description

Synthesis problem to constrain (clamp) a value to be within specified bounds.

### Category
- **Logic**: CLIA (Conditional Linear Integer Arithmetic)
- **Domain**: Value constraint and range enforcement
- **Difficulty**: Easy → Medium → Hard

### Problem Overview

Given a value and bounds, synthesize a function that clamps the value to stay within the specified range.

## Difficulty Levels

### Easy Version (`easy.sl`)
Simple clamp to fixed range [0, 10]:
- If x < 0, return 0
- If x > 10, return 10
- If 0 ≤ x ≤ 10, return x
- Result is always in [0, 10]

**Typical synthesis space**: Small
**Expected synthesis time**: < 1 second

**Expected Solution**:
```julia
ifelse(x < 0, 0, ifelse(x > 10, 10, x))
```

### Medium Version (`medium.sl`)
Clamp with variable bounds [min_val, max_val]:
- Handles dynamic lower and upper bounds
- Monotonicity property
- Idempotence: clamp(clamp(x, a, b), a, b) = clamp(x, a, b)

**Typical synthesis space**: Medium
**Expected synthesis time**: 2-5 seconds

### Hard Version (`hard.sl`)
Advanced multi-range adaptive clamping:
- Five parameters: soft and hard min/max boundaries
- Different clamping behavior in different regions
- Complex monotonicity and idempotence properties
- Two-variable constraints for ordering

**Typical synthesis space**: Large
**Expected synthesis time**: 10-60 seconds

## Expected Solutions

### Easy Version
```julia
ifelse(x < 0, 0, ifelse(x > 10, 10, x))
```

### Medium Version
```julia
ifelse(x < min_val, min_val, ifelse(x > max_val, max_val, x))
```

### Hard Version
Complex nested conditional handling all 5 regions with transitions between hard and soft boundaries.

## SyGuS Challenge Track
CLIA (Conditional Linear Integer Arithmetic)

## Notes for Benchmarking

1. **Easy**: Tests basic range constraint synthesis
2. **Medium**: Tests variable parameter handling and idempotence
3. **Hard**: Tests complex multi-region logic and advanced properties

## Related Problems

- `abs_value`: Another constraint function
- `sign_function`: Classification within ranges
- `saturate`: Similar to clamp but with smooth transitions (in FP)

## Grammar Requirements

The grammar must support:
- Comparison operators: `<`, `>`, `<=`, `>=`, `=`
- Logical operators: `and`, `or` (for medium/hard)
- Conditional operator: `ifelse` or `ite`
- Arithmetic operators: `+`, `-` (for hard version)
- Integer variables: x (plus bounds for medium/hard)

## Applications

- Graphics: Value normalization in rendering pipelines
- Signal processing: Amplitude limiting and saturation
- Control systems: Actuator saturation bounds
- Game development: Health/mana/stat clamping

## Benchmarking Tips

- Easy version: Quick baseline for simple conditionals
- Medium version: Tests parameter passing and reuse
- Hard version: Useful for testing performance on complex constraint satisfaction
