# define-fun Parser Implementation

## Summary

The `parse_sygus.jl` file has been extended to support parsing `define-fun` statements from SyGuS specifications. This allows the system to handle helper function definitions that are often used in complex specifications.

## What's New

### 1. Updated `SMTSpec` Struct

The `SMTSpec` struct now includes a `functions` field:

```julia
struct SMTSpec
    vars::Vector{Symbol}
    constraints::Vector{NamedTuple}
    functions::Dict{String, NamedTuple}  # NEW: function definitions
end
```

Each function definition is stored as a NamedTuple with:
- `params::Vector{Symbol}` — Parameter names
- `param_types::Vector{String}` — Parameter type strings
- `return_type::String` — Return type string
- `body::String` — Function body as an S-expression string

### 2. New Functions

#### `extract_define_fun(content::String) -> Dict{String, NamedTuple}`

Extracts all `(define-fun ...)` declarations from the SyGuS file content. Handles multi-line definitions by tracking parenthesis balance.

#### `parse_define_fun_line(line::String, functions::Dict)`

Parses a single define-fun declaration and adds it to the functions dictionary. Performs:
- Name extraction
- Parameter list parsing
- Return type identification
- Function body extraction

## Usage Example

### SyGuS File with define-fun

```scheme
(define-fun im ((b1 Bool) (b2 Bool) (b3 Bool)) Bool 
  (or (and b1 b2) (and (not b1) b3)))

(define-fun plus_2 ((x Int) (y Int)) Int 
  (+ x y))

(declare-var x Int)
(declare-var y Int)

(constraint (=> (and (> x 0) (> y 0)) 
                (= (plus_2 x y) (+ x y))))

(check-synth)
```

### Parsing and Accessing Functions

```julia
include("parse_sygus.jl")

spec = parse_sygus("myspec.sl")

# Access defined functions
for (fname, fdef) in spec.functions
    println("Function: $fname")
    println("  Parameters: $(fdef.params)")
    println("  Parameter Types: $(fdef.param_types)")
    println("  Return Type: $(fdef.return_type)")
    println("  Body: $(fdef.body)")
end

# Example output:
# Function: im
#   Parameters: [:b1, :b2, :b3]
#   Parameter Types: ["Bool", "Bool", "Bool"]
#   Return Type: Bool
#   Body: (or (and b1 b2) (and (not b1) b3))
```

## Integration with SemanticSMT Oracle

The `SemanticSMTOracle` can now access the function definitions through the parsed spec:

```julia
oracle = SemanticSMTOracle(spec, sym_vars, grammar)

# Access functions for constraint processing
if haskey(oracle.spec.functions, "im")
    im_def = oracle.spec.functions["im"]
    # Use the definition for constraint substitution
end
```

## Backward Compatibility

The parser maintains full backward compatibility:
- Specs WITHOUT define-fun statements will have an empty `functions` dictionary
- Existing code that doesn't use the functions field will continue to work
- All constraint parsing logic remains unchanged

## Example: Processing Constraints with define-fun

When constraints reference defined functions, they can be processed by:

1. Parsing the constraint expression
2. Looking up referenced function definitions in `spec.functions`
3. Substituting parameters and expanding function calls
4. Building the SMT query

This is currently done implicitly through the string-based constraint parsing in `_parse_smtlib_string()` of `semantic_smt_oracle.jl`. For more complex handling, function definitions can be explicitly accessed and used during query construction.

## Files Modified

- **parse_sygus.jl**: 
  - Updated `SMTSpec` struct with `functions` field
  - Extended `parse_sygus()` to call `extract_define_fun()`
  - Added `extract_define_fun()` function
  - Added `parse_define_fun_line()` helper function

## Testing

The implementation was tested with:
- Multi-parameter function definitions
- Nested SMT-LIB expressions in function bodies
- Backward compatibility with specs lacking define-fun statements
- Both single-line and multi-line function definitions
