# Maximum of Two Numbers

## Problem Description

Synthesis problem to find the maximum of two integers using standard conditional logic.

### Category
- **Logic**: LIA (Linear Integer Arithmetic)
- **Domain**: Comparison and selection
- **Difficulty**: Easy → Medium → Hard

### Problem Overview

Given two integers `x` and `y`, synthesize a function that returns the maximum value.

## Difficulty Levels

### Easy Version (`easy.sl`)
Basic specification with three constraints:
- Result must be ≥ x
- Result must be ≥ y  
- Result must be either x or y

**Typical synthesis space**: Small
**Expected synthesis time**: < 1 second

### Medium Version (`medium.sl`)
Extended specification adding:
- Properties about different values
- Equality properties
- Defensive constraints

**Typical synthesis space**: Medium
**Expected synthesis time**: 1-5 seconds

### Hard Version (`hard.sl`)
Complex specification with:
- Mixed sign handling
- Idempotence property
- Negative number properties
- Multi-constraint implications

**Typical synthesis space**: Large
**Expected synthesis time**: 5-30 seconds

## Expected Solutions

### All Versions
```julia
ifelse(x > y, x, y)
```

Or equivalently:
```julia
ifelse(y > x, y, x)
```

Or using ternary-style:
```julia
ifelse(>=(x, y), x, y)
```

### Alternative Forms
- `max(x, y)` (if max is available in grammar)
- `ifelse(>=(x, y), x, y)`
- `ifelse(<(y, x), x, y)`

## SyGuS Challenge Track
CLIA (Conditional Linear Integer Arithmetic)

## Notes for Benchmarking

1. **Easy**: Use for testing basic synthesis pipeline and grammar validity
2. **Medium**: Use for regression testing and feature verification
3. **Hard**: Use for performance benchmarking and stress testing

## Related Problems

- `abs_value`: Finding absolute value (single variable variant)
- `max_three`: Finding maximum of three numbers
- `min_max_range`: Constraining value within a range

## Grammar Requirements

The grammar must support:
- Comparison operators: `>`, `>=`, `<`, `<=`, `=`, `!=`
- Conditional operator: `ifelse` or `ite`
- Integer constants: 0, 1
- Integer variables: x, y
- Integer operations: None required (pure logic)
