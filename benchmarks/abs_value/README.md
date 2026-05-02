# Absolute Value

## Problem Description

Synthesis problem to compute the absolute value (magnitude) of an integer.

### Category
- **Logic**: LIA (Linear Integer Arithmetic)
- **Domain**: Unary arithmetic operation
- **Difficulty**: Easy → Medium → Hard

### Problem Overview

Given an integer `x`, synthesize a function that returns its absolute value |x|.

## Difficulty Levels

### Easy Version (`easy.sl`)
Basic specification with three constraints:
- Result is non-negative
- If input ≥ 0, result equals input
- If input < 0, result equals negation of input

**Typical synthesis space**: Small
**Expected synthesis time**: < 1 second

### Medium Version (`medium.sl`)
Extended specification adding mathematical properties:
- abs(0) = 0
- Idempotence: abs(abs(x)) = abs(x)
- Result is either x or -x

**Typical synthesis space**: Medium
**Expected synthesis time**: 1-5 seconds

### Hard Version (`hard.sl`)
Complex specification with advanced properties:
- Symmetry: abs(-x) = abs(x)
- Triangle inequality: abs(x + y) ≤ abs(x) + abs(y)
- Multiplication property with positive constants
- Strictness property: abs(x) > 0 when x ≠ 0

**Typical synthesis space**: Large
**Expected synthesis time**: 5-20 seconds

## Expected Solutions

### All Versions
```julia
ifelse(x >= 0, x, -(x))
```

Or equivalently:
```julia
ifelse(x < 0, -(x), x)
```

Or using conditionals:
```julia
ifelse(>=(x, 0), x, -(x))
```

## SyGuS Challenge Track
CLIA (Conditional Linear Integer Arithmetic)

## Notes for Benchmarking

1. **Easy**: Good baseline for single-variable synthesis
2. **Medium**: Tests idempotence and composition properties
3. **Hard**: Tests complex mathematical reasoning and multi-variable constraints

## Related Problems

- `max_two`: Pairwise maximum (binary variant)
- `min_max`: Both min and max in one specification
- `sign_function`: Integer sign (-1, 0, or 1)

## Grammar Requirements

The grammar must support:
- Comparison operators: `>=`, `<`, `=`
- Conditional operator: `ifelse` or `ite`
- Arithmetic operators: `-` (negation), `+`, `*`
- Integer constants: 0, 1
- Integer variables: x, y (for hard version)
