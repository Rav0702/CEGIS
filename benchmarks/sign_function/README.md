# Sign Function

## Problem Description

Synthesis problem to compute the sign of an integer (-1, 0, or 1).

### Category
- **Logic**: CLIA (Conditional Linear Integer Arithmetic)
- **Domain**: Unary classification function
- **Difficulty**: Easy → Medium → Hard

### Problem Overview

Given an integer `x`, synthesize a function that returns:
- `1` if x > 0 (positive)
- `0` if x = 0 (zero)
- `-1` if x < 0 (negative)

## Difficulty Levels

### Easy Version (`easy.sl`)
Basic specification with four constraints:
- Returns 1 for positive input
- Returns 0 for zero input
- Returns -1 for negative input
- Result is in {-1, 0, 1}

**Typical synthesis space**: Small
**Expected synthesis time**: < 1 second

### Medium Version (`medium.sl`)
Extended specification with properties:
- Core constraints from easy version
- sign(0) = 0 explicitly
- Antisymmetry: sign(-x) = -sign(x)
- Magnitude properties

**Typical synthesis space**: Medium
**Expected synthesis time**: 1-3 seconds

### Hard Version (`hard.sl`)
Complex specification with advanced properties:
- All medium constraints
- Idempotence: sign(sign(x)) = sign(x)
- Comparative properties across zero crossings
- Multiplication property: sign(x*y) = sign(x)*sign(y)
- Bounded constraints

**Typical synthesis space**: Large
**Expected synthesis time**: 5-20 seconds

## Expected Solutions

### All Versions
```julia
ifelse(x > 0, 1, ifelse(x = 0, 0, -1))
```

Or equivalently:
```julia
ifelse(x > 0, 1, ifelse(x < 0, -1, 0))
```

## SyGuS Challenge Track
CLIA (Conditional Linear Integer Arithmetic)

## Notes for Benchmarking

1. **Easy**: Basic ternary classification task
2. **Medium**: Tests antisymmetry and negation reasoning
3. **Hard**: Tests complex algebraic properties and multiplication

## Related Problems

- `abs_value`: Related magnitude function
- `max_two`: Comparison-based selection (simpler)
- `threshold_function`: Related classification with different boundaries

## Grammar Requirements

The grammar must support:
- Comparison operators: `>`, `<`, `=`
- Integer constants: -1, 0, 1
- Conditional operator: `ifelse` or `ite`
- Arithmetic: `-` (negation), `*`
- Integer variables: x (y, z for hard version)

## Benchmarking Insights

- Sign function is a common building block in many synthesis problems
- Easy version provides quick synthesis baseline
- Hard version useful for testing algebraic reasoning in solvers
- Multiplication property introduces non-linear reasoning
