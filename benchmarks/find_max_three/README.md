# Maximum of Three Numbers

## Problem Description

Synthesis problem to find the maximum of three integers.

### Category
- **Logic**: CLIA (Conditional Linear Integer Arithmetic)
- **Domain**: Multi-variable comparison and selection
- **Difficulty**: Easy → Medium → Hard

### Problem Overview

Given three integers `x`, `y`, and `z`, synthesize a function that returns the maximum value.

## Difficulty Levels

### Easy Version (`easy.sl`)
Basic specification with two constraints:
- Result must be ≥ x, y, and z
- Result must be one of the three inputs

**Typical synthesis space**: Medium
**Expected synthesis time**: 1-3 seconds

### Medium Version (`medium.sl`)
Extended specification adding algebraic properties:
- Idempotence: max(x, x, x) = x
- Partial commutativity for different argument orderings
- Consistency with pairwise max operations

**Typical synthesis space**: Large
**Expected synthesis time**: 3-10 seconds

### Hard Version (`hard.sl`)
Complex specification with advanced properties:
- Complete algebraic properties (commutativity, idempotence)
- Full ordering constraints for sorted triplets
- Monotonicity properties
- Constraints involving an additional variable

**Typical synthesis space**: Very large
**Expected synthesis time**: 15-120 seconds

## Expected Solutions

### All Versions
```julia
ifelse(x >= y,
  ifelse(x >= z, x, z),
  ifelse(y >= z, y, z)
)
```

Or other equivalent nested ifelse forms:
```julia
ifelse(x > y,
  ifelse(x > z, x, z),
  ifelse(y > z, y, z)
)
```

## SyGuS Challenge Track
CLIA (Conditional Linear Integer Arithmetic)

## Notes for Benchmarking

1. **Easy**: Tests basic multi-variable synthesis
2. **Medium**: Tests symmetry properties and composition
3. **Hard**: Tests complex constraint satisfaction and monotonicity

## Related Problems

- `max_two`: Binary maximum (simpler predecessor)
- `min_three`: Minimum of three (symmetric problem)
- `median_three`: Middle value of three

## Grammar Requirements

The grammar must support:
- Comparison operators: `>`, `>=`, `<`, `<=`, `=`
- Logical operators: `and`, `or` (for hard version)
- Conditional operator: `ifelse` or `ite`
- Integer variables: x, y, z (and w in hard version)
- Support for nested conditionals

## Benchmarking Insights

- Easy version: Tests basic ternary synthesis
- Medium version: Tests symmetry reasoning
- Hard version: Heavy constraint propagation - good for stress testing
- Useful for comparing different search strategies
