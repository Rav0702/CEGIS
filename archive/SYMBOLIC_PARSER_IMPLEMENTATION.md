# SymbolicCandidateParser Implementation Summary

## What Was Implemented

### 1. Type-Aware Expression Parser
**File**: `src/CEXGeneration/candidates.jl`

A new `SymbolicCandidateParser` that understands boolean and integer types:

```julia
struct SymbolicCandidateParser <: AbstractCandidateParser
    name::String
end
```

**Key Features**:
- Tracks expression types during parsing (Bool vs Int)
- Automatically wraps Boolean expressions with `(ite expr 1 0)` when used in arithmetic
- Supports all HerbGrammar expression types
- Falls back to InfixCandidateParser gracefully on errors

### 2. Type-Tracked AST

```julia
abstract type TypedExpr end
struct IntExpr <: TypedExpr
    smt::String
end
struct BoolExpr <: TypedExpr
    smt::String
end
```

### 3. Operator Signatures

Operators track their return type:

```julia
_SYMBOLIC_OPS = Dict(
    "or"  => (1, "or", :bool),      # Bool → Bool
    "and" => (2, "and", :bool),     # Bool → Bool
    "="   => (3, "=", :bool),       # Int → Bool
    "+"   => (4, "+", :int),        # Int → Int
    "*"   => (5, "*", :int),        # Int → Int
)
```

## Test Results

All test cases pass with correct type coercion:

| Expression | InfixCandidateParser | SymbolicCandidateParser | Status |
|---|---|---|---|
| `x + 5` | `(+ x 5)` | `(+ x 5)` | ✅ Safe |
| `(x > y) * x` | `(* (> x y) x)` | `(* (ite (> x y) 1 0) x)` | ✅ Coerced |
| `(a = b) + c` | `(+ (= a b) c)` | `(+ (ite (= a b) 1 0) c)` | ✅ Coerced |
| `if (x > 0) then 1 else 0` | `(ite (> x 0) 1 0)` | `(ite (> x 0) 1 0)` | ✅ Identical |
| `(x > y) and (a < b)` | `(and (> x y) (< a b))` | `(and (> x y) (< a b))` | ✅ Safe |

## Grammar Enhancement

**File**: `scripts/z3_smt_cegis.jl` → `build_grammar_from_spec_file()`

Added new grammar rules to support mixed boolean-numeric synthesis:

```julia
# Mixed boolean-numeric operations
Expr = BoolExpr + Expr      # (x > y) + k  →  (+ (ite (>) 1 0) k)
Expr = Expr + BoolExpr      # k + (x > y)
Expr = BoolExpr * Expr      # (x > y) * k  →  (* (ite (>) 1 0) k)
Expr = Expr * BoolExpr      # k * (x > y)

# Boolean conjunction (useful for multi-condition specs)
BoolExpr = BoolExpr && BoolExpr  # (x > 0) && (y < 10)
```

These rules enable synthesis of more expressive programs that naturally combine numerical and logical decision-making.

## Z3Oracle Integration

**File**: `src/Oracles/z3_oracle.jl`

The oracle now accepts an optional parser parameter:

```julia
# Default (InfixCandidateParser)
oracle = Z3Oracle(spec_file, grammar)

# Use SymbolicCandidateParser
oracle = Z3Oracle(spec_file, grammar, 
    parser=CEXGeneration.SymbolicCandidateParser())
```

## API Usage Examples

### 1. Direct Parser Usage

```julia
using CEGIS.CEXGeneration

# Method 1: Explicit parser
parser = SymbolicCandidateParser()
result = to_smt2(parser, "(x > y) * x")
# Result: "(* (ite (> x y) 1 0) x)"

# Method 2: Default parser
set_default_candidate_parser(SymbolicCandidateParser())
result = candidate_to_smt2("(x > y) * x")  # Uses SymbolicCandidateParser
```

### 2. With Z3Oracle

```julia
# Create oracle with type-aware parser
parser = SymbolicCandidateParser()
oracle = Z3Oracle(spec_file, grammar, parser=parser)

# Now synthesis can explore mixed bool-numeric expressions
# that would have failed with InfixCandidateParser
```

## Backwards Compatibility

✅ **Zero Breaking Changes**:
- Old code using `candidate_to_smt2(expr)` works unchanged
- Default parser is InfixCandidateParser (original behavior)
- All exports preserved and expanded
- Existing Z3Oracle calls work without modification

## Technical Implementation Details

### Type Checking During Parsing

The parser uses recursive descent with type propagation:

```
_symbolic_parse_expr_typed()
  ├─ Parse left operand → get type (Bool or Int)
  ├─ Read operator → check return type
  ├─ Parse right operand → get type
  ├─ If operator expects Int but got Bool → wrap with (ite ... 1 0)
  └─ Return typed result (IntExpr or BoolExpr)
```

### Example Walkthrough

Input: `(x > y) * x`

```
Parse (x > y):
  → Comparison → BoolExpr("(> x y)")
  
Parse *:
  → Arithmetic operator, expects Int operands
  → Left operand is Bool → wrap: (ite (> x y) 1 0)
  
Parse x:
  → Variable → IntExpr("x")
  
Result:
  → IntExpr("(* (ite (> x y) 1 0) x)")
```

## Error Handling

- Graceful fallback to InfixCandidateParser on parse errors
- Warnings for trailing tokens
- Type errors are converted to coercion (not rejected)

## Performance

- Z-complexity similar to InfixCandidateParser (both O(n) recursive descent)
- Minimal overhead: just type tracking during recursion
- No external dependencies (doesn't require Symbolics.jl)

## Future Enhancements

Optional ideas for future development:

1. **Environment selection**: Accept parser choice via env var or config
2. **Type inference**: Infer variable types from usage before parsing
3. **Symbolics integration**: Full support for symbolic computation
4. **Custom coercion strategies**: Allow user-defined type coercion rules

## Files Modified

1. ✅ `src/CEXGeneration/candidates.jl`
   - Added `SymbolicCandidateParser` implementation
   - Added `TypedExpr`, `IntExpr`, `BoolExpr` types
   - Added `_symbolic_parse_expr_typed()` and related functions
   - Fixed S-expression detection in both parsers

2. ✅ `src/Oracles/z3_oracle.jl`
   - Added `parser::AbstractCandidateParser` field
   - Updated constructor to accept optional `parser` argument
   - Updated `extract_counterexample()` to use injected parser
   - Updated docstrings with examples

3. ✅ `src/CEXGeneration/CEXGeneration.jl`
   - Added exports: `SymbolicCandidateParser`, `set_default_candidate_parser`, etc.

4. ✅ `scripts/z3_smt_cegis.jl`
   - Enhanced `build_grammar_from_spec_file()` with mixed rules
   - Added documentation for parser selection
   - Added boolean conjunction rule `&&`

## Testing

Created comprehensive test suite:

- ✅ `test_symbolic_parser.jl` - Direct parser testing
- ✅ `test_symbolic_impl.jl` - Integration with CEXGeneration
- ✅ `test_integration_parsers.jl` - Full Z3Oracle integration

**Run tests**:
```bash
julia test_symbolic_impl.jl
```

## Next Steps (Optional)

To further enhance the system:

1. Add support for more expression types (e.g., string operations, bitwise)
2. Implement full Symbolics.jl integration
3. Add parser benchmarking suite
4. Create parser selection CLI flags for synthesis scripts
