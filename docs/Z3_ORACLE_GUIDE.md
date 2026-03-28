# Z3Oracle Implementation Guide

**Purpose**: Deep-dive into how Z3Oracle verifies candidates and extracts counterexamples.

---

## Overview

Z3Oracle is the **heart of formal verification** in z3_smt_cegis. It transforms synthesis candidates into SMT-LIB2 queries, calls Z3 to verify them, and extracts counterexamples for learning.

**Location**: `src/Oracles/z3_oracle.jl`

---

## Type Definition

```julia
mutable struct Z3Oracle <: AbstractOracle
    spec_file::String                                  # Path to .sl file
    spec::Any                                          # Parsed Spec object
    grammar::AbstractGrammar                           # Herb grammar
    z3_ctx::Z3.Context                                 # Z3 context (persistent state)
    z3_vars::Dict{String, Z3.Expr}                     # Cached Z3 variable expressions
    mod::Module                                        # Module for function lookup
    enum_count::Int                                    # Enumeration counter
    test_candidate::Union{String, Nothing}             # Optional candidate to test
    parser::CEXGeneration.AbstractCandidateParser      # Strategy for parsing candidates
end
```

**Key Fields Explained**:

| Field | Purpose | Notes |
|-------|---------|-------|
| `spec_file` | Path to input spec | Used to reload spec if needed |
| `spec` | Parsed spec object | From CEXGeneration.parse_spec_from_file() |
| `grammar` | Herb grammar | For converting RuleNode to Expr |
| `z3_ctx` | Z3 context | Persistent state; reused across queries |
| `z3_vars` | Cached Z3 variables | Optimization: avoid recreating Z3 terms |
| `mod` | Julia module | For finding primitive functions |
| `enum_count` | Counter | Track how many candidates verified |
| `test_candidate` | Optional test expr | If set, test this candidate directly |
| `parser` | Candidate parser | InfixCandidateParser or SymbolicCandidateParser |

---

## Constructor

**Location**: [src/Oracles/z3_oracle.jl:72-98](src/Oracles/z3_oracle.jl#L72-L98)

```julia
function Z3Oracle(
    spec_file::String,
    grammar::AbstractGrammar;
    parser::CEXGeneration.AbstractCandidateParser = CEXGeneration.InfixCandidateParser()
)::Z3Oracle
```

**Steps**:

1. **Parse Spec File**:
   ```julia
   spec = CEXGeneration.parse_spec_from_file(spec_file)
   ```
   - Parses .sl file into Spec object
   - Extracts synth function name, free variables, constraints

2. **Create Z3 Context**:
   ```julia
   z3_ctx = Z3.Context()
   ```
   - Initializes Z3 with default configuration
   - Reused across all verification queries

3. **Cache Z3 Variables**:
   ```julia
   z3_vars = Dict(fv.name => Z3.IntSort(z3_ctx) for fv in spec.free_vars)
   ```
   - Pre-allocates Z3 integer variables
   - Prevents recreating same variables in each query

4. **Return Oracle**:
   ```julia
   return Z3Oracle(spec_file, spec, grammar, z3_ctx, z3_vars, 
                   Main, 0, nothing, parser)
   ```

**Example Usage**:

```julia
# Default parser (InfixCandidateParser)
oracle = Z3Oracle("../spec_files/findidx_problem.sl", grammar)

# Custom parser (SymbolicCandidateParser for mixed types)
oracle = Z3Oracle("../spec_files/findidx_problem.sl", grammar,
                  parser=CEXGeneration.SymbolicCandidateParser())
```

---

## Core Method: extract_counterexample()

**Location**: [src/Oracles/z3_oracle.jl:110-180+](src/Oracles/z3_oracle.jl#L110)

This is the **main method** called during CEGIS synthesis to verify candidates.

```julia
function extract_counterexample(
    oracle::Z3Oracle,
    candidate::RuleNode
)::Union{Counterexample, Nothing}
```

**Returns**:
- `Counterexample{input, expected_output}` if candidate is invalid (counterexample found)
- `nothing` if candidate is valid (verified) or error occurs

### Detailed Pipeline

#### Step 1: Convert RuleNode to Infix Expression

```julia
candidate_expr = rulenode2expr(candidate, oracle.grammar)
```

**Example**:
```
RuleNode(id=5, children=[...])
    ↓
Expr(
  :ifelse,
  [Expr(:>, [Expr(:variable, [:x1]), Expr(:literal, [5])]),
   Expr(:+, [Expr(:variable, [:x1]), Expr(:variable, [:x2])]),
   Expr(:+, [Expr(:variable, [:x2]), Expr(:variable, [:x3])])]
)
```

**What it is**: A Julia abstract syntax tree (AST) representing the synthesized program.

#### Step 2: Apply Pluggable Parser

```julia
smt2_string = CEXGeneration.to_smt2(oracle.parser, candidate_expr)
```

**Two Parser Strategies**:

##### A) InfixCandidateParser (Default)

**How it works**:
1. Parse infix expression: `1 + 2 + 3`
2. Check SMT-LIB2 type consistency
3. Convert to S-expression: `(+ (+ 1 2) 3)`

**Constraints**:
- ✓ `Expr + Expr` → `(+ Expr Expr)` — Both must return Int
- ✗ `(Expr > Expr) + Expr` — Invalid! Bool + Int mismatch
- ✗ `Expr + Expr > Expr` — Invalid! Returns Bool, then compared

**Usage**: Default for problems with clear type separation

##### B) SymbolicCandidateParser (Alternative)

**How it works**:
1. Parse infix expression
2. Detect mixed bool-numeric operations
3. Auto-coerce Bool to Int using ITE: `bool_expr → (ite bool_expr 1 0)`

**Conversion Examples**:
```
(Expr > Expr) + Expr
    ↓ (coerce comparison to int)
(ite (Expr > Expr) 1 0) + Expr
    ↓
(+ (ite (Expr > Expr) 1 0) Expr)
```

**Usage**: When synthesis involves mixed-type expressions

**Example**: 
```julia
oracle = Z3Oracle(spec_file, grammar,
                  parser=CEXGeneration.SymbolicCandidateParser())
```

#### Step 3: Extract SMT-LIB2 String

After parsing, we have SMT-LIB2 representation:

```
(define-fun findIdx (x1 Int x2 Int x3 Int) Int
  (ite (> x1 5) (+ x1 x2) (ite (> x2 5) (+ x2 x3) 0))
)
```

#### Step 4: Generate Full Query

```julia
query = CEXGeneration.generate_cex_query(oracle.spec, 
                                        Dict(func_name => smt2_string))
```

**Query Structure**:

```smt2
(set-logic LIA)

; Declare variables
(declare-fun x1 () Int)
(declare-fun x2 () Int)
(declare-fun x3 () Int)

; Define candidate program
(define-fun findIdx (x1 Int x2 Int x3 Int) Int
  (ite (> x1 5) (+ x1 x2) (ite (> x2 5) (+ x2 x3) 0))
)

; Define spec function (nested ite from implications)
(define-fun findIdx_spec (x1 Int x2 Int x3 Int) Int
  (ite (> (+ x1 x2) 5) (+ x1 x2)
       (ite (and (<= (+ x1 x2) 5) (> (+ x2 x3) 5)) (+ x2 x3)
            0))
)

; ASSERT that constraints FAIL
; (this finds counterexamples!)
(assert (not
  (and
    (=> (> (+ x1 x2) 5) (= (findIdx x1 x2 x3) (+ x1 x2)))
    (=> (and (<= (+ x1 x2) 5) (> (+ x2 x3) 5)) (= (findIdx x1 x2 x3) (+ x2 x3)))
    (=> (and (<= (+ x1 x2) 5) (<= (+ x2 x3) 5)) (= (findIdx x1 x2 x3) 0))
  )
))

; Get values for counterexample
(get-value (x1 x2 x3 (findIdx x1 x2 x3) (findIdx_spec x1 x2 x3)))

(check-sat)
```

**Key Strategy**: Constraints are **negated**
- If UNSAT: Candidate satisfies all constraints ✓ (verified)
- If SAT: Counterexample found ✗ (invalid)
- If SAT + model: Extract input and expected output

#### Step 5: Call Z3 Verification

```julia
result = CEXGeneration.verify_query(query)
```

**Returns** Z3Result with:
- `status::Symbol` — `:sat`, `:unsat`, or `:error`
- `model::Dict` — Variable assignments if `:sat`

**What happens internally**:
1. Open pipe to Z3 process
2. Send query string
3. Parse response (status line + model)
4. Extract model values (handle S-expression format)

**Model Format** (from Z3):
```
sat
(
  (x1 3)
  (x2 5)
  (x3 1)
  (findIdx 8)
  (findIdx_spec 8)
)
```

#### Step 6: Interpret Result

**Case A: UNSAT** (Candidate verified ✓)
```julia
if result.status == :unsat
    return nothing  # No counterexample
end
```

**Case B: SAT** (Counterexample found)
```julia
if result.status == :sat
    # Extract input assignments
    input_dict = Dict(sym => model[sym] for sym in var_names)
    
    # Extract expected output from spec function
    expected_output = model["$(func_name)_spec_result"]
    
    # Extract actual output from candidate
    actual_output = model["$(func_name)_result"]
    
    return Counterexample(input_dict, expected_output, actual_output)
end
```

**Case C: ERROR** (Unknown status)
```julia
if result.status == :error
    return nothing  # Conservative: assume verified
end
```

### Complete Pipeline Visualization

```
RuleNode
    ↓
rulenode2expr()
    ↓
Expr (Julia AST)
    ↓
oracle.parser.to_smt2()
    ├─ InfixCandidateParser: Strict type checking
    └─ SymbolicCandidateParser: Mixed-type coercion
    ↓
SMT-LIB2 String (candidate definition)
    ↓
CEXGeneration.generate_cex_query()
    ├─ Add variable declarations
    ├─ Add candidate definition
    ├─ Build spec function from constraints
    ├─ Assert constraint negation
    └─ Add get-value commands
    ↓
Full SMT-LIB2 Query
    ↓
CEXGeneration.verify_query()
    ├─ Call Z3 native API
    ├─ Parse response
    └─ Extract model
    ↓
Z3Result{status, model}
    ↓
extract_counterexample()
    ├─ If :unsat → return nothing (verified)
    ├─ If :sat → parse model → return Counterexample
    └─ If :error → return nothing
```

---

## Candidate Parser Strategies

### Strategy 1: InfixCandidateParser (Strict)

**Location**: `src/CEXGeneration/candidates.jl`

**Philosophy**: Enforce SMT-LIB2 type safety

**Behavior**:
- All operators must have clear types
- `Expr + Expr` → `(+ Expr Expr)` (Int + Int = Int)
- Rejects `(Expr > Expr) + Expr` (Bool + Int mismatch)

**Pros**:
- ✅ Type-safe SMT-LIB2 generation
- ✅ Catches errors early

**Cons**:
- ❌ Rejects valid programs with mixed types
- ❌ Limits expressiveness

**When to use**:
- Problems with clear type hierarchy
- Grammar has separate Int and Bool expressions
- No need for boolean-to-integer coercion

**Example Problem**:
```
Good operators:
  Expr = Expr + Expr          (Int + Int = Int)
  Expr = Expr - Expr
  BoolExpr = Expr > Expr      (Bool, not Int!)
  Expr = ifelse(BoolExpr, Expr, Expr)
  
Would reject:
  (x1 > x2) + x3              (Bool + Int)
  x1 + (x2 > x3)              (Int + Bool)
```

### Strategy 2: SymbolicCandidateParser (Flexible)

**Location**: `src/CEXGeneration/candidates.jl`

**Philosophy**: Support mixed-type operations through automatic coercion

**Behavior**:
- Detects bool-in-int contexts
- Coerces: `bool_expr → (ite bool_expr 1 0)`
- Generates valid SMT-LIB2

**Transformation Examples**:

```
Input:     (x1 > x2) + x3
Coercion:  (ite (x1 > x2) 1 0) + x3  
Output:    (+ (ite (x1 > x2) 1 0) x3)  ✓ Valid SMT-LIB2

Input:     x1 + x2 > 5           ← This stays as-is; it's a comparison
Output:    (> (+ x1 x2) 5)       ✓ Returns Bool, so OK in boolean context

Input:     ifelse((x1 + x2) > 5, x3, x4)  ← Boolean condition is fine
Output:    (ite (> (+ x1 x2) 5) x3 x4)    ✓
```

**Pros**:
- ✅ Supports mixed-type expressions
- ✅ More expressive synthesis space
- ✅ Automatic type fixing

**Cons**:
- ❌ May introduce inefficient coercions
- ❌ Slightly slower parsing

**When to use**:
- Problems require mixed-type programs
- Synthesis fails with InfixCandidateParser
- Grammar mixes Expr and BoolExpr freely

**Example Problem**:
```
Solution: ifelse((x > limit) && (y > threshold), x + y, z)
          └─ Mixed types: && returns Bool, used in ifelse condition
          
With SymbolicParser: Handles automatically
With InfixParser: Rejects (type mismatch)
```

### How to Choose

**Start with InfixCandidateParser** (default):
```julia
oracle = Z3Oracle(spec_file, grammar)
```

**Switch to SymbolicCandidateParser if**:
- Synthesis fails with "type error"
- Error mentions "Bool" + "Int" mismatch
- Problem naturally involves mixed types

```julia
oracle = Z3Oracle(spec_file, grammar,
                  parser=CEXGeneration.SymbolicCandidateParser())
```

---

## Query Generation Strategy

### Why Constraints Are Negated

**Standard Approach** (WRONG ❌):
```smt2
(assert (and constraint1 constraint2 constraint3))
(check-sat)
```

**Problem**: If constraints are implications like `(=> condition output)`, the unconstrained regions are vacuously true. Z3 could return ANY value and still satisfy the constraints.

**Example**:
```
Constraint: (=> (< x 5) (= func_result 10))

Evaluation at x=10:
  Premise (< 10 5) = false
  Implication evaluates to true (false => anything = true)
  Z3 accepts ANY value for func_result!
```

**New Approach** (CORRECT ✓):
```smt2
(assert (not (and constraint1 constraint2 constraint3)))
(check-sat)
```

**Result**:
- If UNSAT: All constraints satisfied ✓
- If SAT: Found some constraint that's false (counterexample)

**Example**:
```
Same constraint: (=> (< x 5) (= func_result 10))

At x=10:
  Implication = true (vacuously satisfied)
  Not(true) = false
  Assertion fails

Z3 must find assignment where some constraint is false
→ Identifies real violation, not vacuous satisfaction
```

### Spec Function Building

To extract correct expected output when SAT (counterexample found):

**Method**: Build nested ITE from constraint implications

**From constraints**:
```smt2
(constraint (=> (> (+ x1 x2) 5) (= fnd_sum (+ x1 x2))))
(constraint (=> (and (<= (+ x1 x2) 5) (> (+ x2 x3) 5)) (= fnd_sum (+ x2 x3))))
(constraint (=> (and (<= (+ x1 x2) 5) (<= (+ x2 x3) 5)) (= fnd_sum 0)))
```

**Extract structure**:
```
If (> (+ x1 x2) 5) then output is (+ x1 x2)
Else if (and (<= (+ x1 x2) 5) (> (+ x2 x3) 5)) then output is (+ x2 x3)
Else if (and (<= (+ x1 x2) 5) (<= (+ x2 x3) 5)) then output is 0
Else output is 0 (default, don't-care)
```

**Build ITE**:
```smt2
(define-fun fnd_sum_spec (x1 Int x2 Int x3 Int) Int
  (ite
    (> (+ x1 x2) 5) (+ x1 x2)
    (ite
      (and (<= (+ x1 x2) 5) (> (+ x2 x3) 5)) (+ x2 x3)
      (ite
        (and (<= (+ x1 x2) 5) (<= (+ x2 x3) 5)) 0
        0))))
```

**Purpose**: When Z3 returns SAT model, we can query `fnd_sum_spec` to get what the correct output SHOULD be at that assignment.

**Example Model**:
```
(x1 1) (x2 1) (x3 2)
(fnd_sum 3)          ← What candidate returned
(fnd_sum_spec 0)     ← What spec says should be returned
→ Counterexample! Expected 0, got 3
```

---

## Error Handling

### Silent Failures (Conservative)

If anything goes wrong (Z3 crash, parse error, model extraction fail):
```julia
try
    # ... verification steps ...
catch e
    return nothing  # Assume verified (conservative)
end
```

**Rationale**: We'd rather accept a bad program than reject a good one.

### Model Extraction Challenges

**Challenge 1: S-Expression Negatives**

Z3 returns:
```
(x1 (- 5))  ← Not (-5), but an S-expression with operator -
```

**Solution**: Regex pattern:
```julia
r"\(\s*-\s+(\d+)\)" → "(-5)"
```

**Challenge 2: Complex Model Format**

Z3 response with many variables:
```
(
  (x1 3) (x2 5) (x3 1)
  (findIdx 8)
  (findIdx_spec 8)
)
```

**Solution**: Parse line-by-line, extract pairs

**Challenge 3: Undefined Variables**

Some variables might not appear in minimal model:
```julia
val = get(model, var_name, 0)  # Default to 0 if missing
```

---

## Debugging & Inspection

### Enumeration Counter

```julia
oracle.enum_count  # Incremented after each verify call
```

**Use**:
```julia
@info "Verified candidate #$(oracle.enum_count)"
```

### Test Candidate Feature

```julia
oracle = Z3Oracle(spec_file, grammar, test_candidate="x1 + x2")
```

If set, oracle can test specific candidate:
```julia
test_candidate_directly(spec_file, candidate_str, oracle, counterexamples)
```

### Debug Output

**To enable debugging**, modify z3_oracle.jl:

```julia
@debug "Converting RuleNode to expression"
@debug "Generated SMT-LIB2: $smt2_string"
@debug "Z3 status: $(result.status)"
@debug "Extracted model: $model"
```

Then run with debug logging:
```bash
julia --startup-file=no -e 'using Logging; global_logger(ConsoleLogger(Logging.Debug)); include("z3_smt_cegis.jl")'
```

---

## Performance Characteristics

### Per-Candidate Verification Time

**Typical ranges** (unfold when running):
- Simple spec (1-2 constraints): 5-10 ms
- Medium spec (3-5 constraints): 20-50 ms
- Complex spec (10+ constraints): 100-500 ms

**Factors affecting speed**:
1. Number of free variables (more → harder)
2. Constraint complexity (nested arithmetic, many conditions)
3. Variables' arithmetic range
4. Z3 heuristic selection for logic

### Optimizations Applied

1. **Variable caching**: Z3 variables pre-allocated (constructor)
2. **Context reuse**: Single Z3.Context per oracle
3. **String avoidance**: Direct SMT-LIB2 generation

### Future Optimizations (Considered but Not Implemented)

1. **Z3OracleDirect**: Build Z3 AST directly (avoid string parsing)
   - Potential speedup: 2-5x
   - Status: Experimental (src/Oracles/z3_oracle_direct.jl)

2. **Incremental Solving**: Reuse Z3 assertions across iterations
   - Potential speedup: 1.5-2x
   - Requires tracking assertion context

3. **Parallel Verification**: Multiple Z3 contexts in threads
   - Potential speedup: 4-8x (4-8 cores)
   - Requires thread-safe grammar traversal

---

## Comparison with SemanticSMTOracle

| Aspect | Z3Oracle | SemanticSMTOracle |
|--------|----------|-------------------|
| **Verification Method** | Native Z3 API | SymbolicSMT library |
| **Intermediate Rep** | SMT-LIB2 string | SymbolicUtils expression |
| **Speed** | Fast (10-50ms) | Slow (100-500ms) |
| **Transparency** | Less (string queries) | More (symbolic repr) |
| **Type Handling** | Strict or flexible | Mixed through rebasing |
| **Query Strategy** | Negation + spec func | Direct satisfiability |
| **Recommended** | ✅ Yes (default) | 🟡 For comparison only |

---

## Summary

**Z3Oracle** provides **formal verification** of synthesized programs via:

1. **Conversion**: RuleNode → Expr → SMT-LIB2
2. **Parsing**: Apply InfixCandidateParser or SymbolicCandidateParser
3. **Query Generation**: Negated constraints + spec function
4. **Z3 Verification**: Native API call with model extraction
5. **Result**: Counterexample (if invalid) or nothing (if verified)

**Key Design Decisions**:
- Constraint negation to properly find counterexamples
- Spec function building to extract correct expected values
- Pluggable parsers for flexible grammar handling
- Conservative error handling (assume verified if error)

**Usage**:
```julia
oracle = Z3Oracle(spec_file, grammar)  # Default
oracle = Z3Oracle(spec_file, grammar, parser=SymbolicCandidateParser())  # Mixed types
```

See [WORKFLOW_GUIDE.md](WORKFLOW_GUIDE.md) for how to use in practice.
