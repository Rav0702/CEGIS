# Conditional Sum

## Problem Description

Synthesis problem to compute a conditional sum based on thresholds and sign conditions.

### Category
- **Logic**: CLIA (Conditional Linear Integer Arithmetic)
- **Domain**: Conditional aggregation and arithmetic
- **Difficulty**: Easy → Medium → Hard

### Problem Overview

Given one or more integers, synthesize a function that returns a sum or value based on multiple conditions.

## Difficulty Levels

### Easy Version (`easy.sl`)
Simple two-branch conditional:
- If x + y ≥ 10: return x + y
- If x + y < 10: return 0
- Result is non-negative

**Typical synthesis space**: Small
**Expected synthesis time**: < 1 second

**Expected Solution**:
```julia
ifelse((x + y) >= 10, x + y, 0)
```

### Medium Version (`medium.sl`)
Four-branch conditional with mixed inputs:
- Both positive, sum ≥ 15 → return sum
- Single positive ≥ 7 → return that value
- Other cases → return 0
- Uses max in one branch

**Typical synthesis space**: Medium
**Expected synthesis time**: 2-8 seconds

### Hard Version (`hard.sl`)
Complex six-branch nested conditionals with three inputs:
- All three positive, sum > 20 → return triple sum
- Two positive, their sum > 15 → return their sum
- Single positive ≥ 10 → return it
- Default → return 0
- Multiple implications with overlapping conditions

**Typical synthesis space**: Large
**Expected synthesis time**: 10-60 seconds

## Expected Solutions

### Easy Version
```julia
ifelse((x + y) >= 10, x + y, 0)
```

### Medium Version
```julia
ifelse(
  (and(x > 0, y > 0, (x + y) >= 15)),
  (x + y),
  ifelse(
    (and(x > 0, y <= 0, x >= 7)),
    x,
    ifelse(
      (and(x <= 0, y > 0, y >= 7)),
      y,
      0
    )
  )
)
```

### Hard Version
Complex nested ifelse with 6+ branches handling all cases

## SyGuS Challenge Track
CLIA (Conditional Linear Integer Arithmetic)

## Notes for Benchmarking

1. **Easy**: Test basic arithmetic and simple conditionals
2. **Medium**: Test multi-branch conditional logic and logical operators
3. **Hard**: Test deeply nested conditionals and complex constraint solving

## Related Problems

- `max_two`: Binary comparison (simpler)
- `abs_value`: Unary conditional transformation
- `weighted_median`: Three-input aggregation with weights

## Grammar Requirements

The grammar must support:
- Arithmetic operators: `+`, `-`, `*`
- Comparison operators: `>`, `>=`, `<`, `<=`, `=`
- Logical operators: `and`, `or`, `not`
- Conditional operator: `ifelse` or `ite`
- Integer constants: 0, 1, 10, 15, 20 (various thresholds)
- Integer variables: x, y (easy/medium), x, y, z (hard)

## Benchmarking Tips

- Monitor constraint propagation effectiveness
- Note any patterns in counterexample generation
- Compare synthesis time as constraints increase
- Hard version useful for stress-testing oracle efficiency
