# Z3 SMT CEGIS: Workflow Guide

**Purpose**: Step-by-step guide to using z3_smt_cegis for program synthesis.

---

## Quick Start (5 Minutes)

### Prerequisites

```bash
# Ensure you have Julia 1.6+
julia --version

# Navigate to CEGIS directory
cd c:\Users\rafal\.julia\dev\CEGIS
```

### Run Default Synthesis

```bash
cd scripts
julia z3_smt_cegis.jl
```

**Expected Output**:
```
Z3 CEGIS Synthesis Script
════════════════════════════════════════════════════════════════════════════════
Spec file:        ../spec_files/findidx_problem.sl
Max depth:        6
Max enumerations: 50000
════════════════════════════════════════════════════════════════════════════════

Loading specification: ../spec_files/findidx_problem.sl
...
Starting Z3-based CEGIS Synthesis
════════════════════════════════════════════════════════════════════════════════
...
Z3 CEGIS Synthesis Results
════════════════════════════════════════════════════════════════════════════════

Status:              SUCCESS
Iterations:          5
Counterexamples:     4
Satisfied examples:  0

Synthesized Program: ifelse(x1 > 5, x1 + x2, ifelse(x2 > 5, x2 + x3, 0))

════════════════════════════════════════════════════════════════════════════════
```

**Success!** You synthesized a program that satisfies all constraints.

---

## Working with Different Specs

### Available Test Specs

**Location**: `spec_files/`

| Spec | Complexity | Runtime | Use When |
|------|------------|---------|----------|
| findidx_2_simple.sl | ⭐ Very Low | <1 sec | Quick validation |
| findidx_problem.sl | ⭐⭐ Low | 1-5 sec | Standard test (default) |
| findidx_2_problem.sl | ⭐⭐⭐ Medium | 5-30 sec | Mid-size problem |
| findidx_5_problem.sl | ⭐⭐⭐⭐ High | 30-120 sec | Large search space |
| jmbl_fg_VC22_a.sl | ⭐⭐⭐⭐⭐ Industrial | ? | Real-world benchmark |

### Run with Different Spec

```bash
# Quick validation (recommended for first time)
julia z3_smt_cegis.jl ../spec_files/findidx_2_simple.sl 4 10000

# Standard problem
julia z3_smt_cegis.jl ../spec_files/findidx_problem.sl 6 50000

# Larger problem (may take longer)
julia z3_smt_cegis.jl ../spec_files/findidx_2_problem.sl 6 100000

# Industrial benchmark (experimental)
julia z3_smt_cegis.jl ../spec_files/jmbl_fg_VC22_a.sl 8 500000
```

---

## Parameter Tuning

### Understanding Parameters

```bash
julia z3_smt_cegis.jl [spec_file] [max_depth] [max_enumerations] [candidate_to_test]
```

| Parameter | Default | Range | Effect |
|-----------|---------|-------|--------|
| **spec_file** | findidx_problem.sl | any .sl | Which problem to solve |
| **max_depth** | 6 | 1-15 | Max RuleNode complexity (deeper = more expressive but slower) |
| **max_enumerations** | 50000 | 1-∞ | Max candidates to try before giving up |
| **candidate_to_test** | none | any expr | Optional: test a specific candidate string |

### Tuning Strategy

**Start Conservative, Increase if Needed**:

```bash
# 1. Quick validation (depth 3, few enumerations)
julia z3_smt_cegis.jl ../spec_files/findidx_2_simple.sl 3 5000

# 2. If fails → increase depth
julia z3_smt_cegis.jl ../spec_files/findidx_2_simple.sl 4 5000

# 3. If still fails → increase enumerations
julia z3_smt_cegis.jl ../spec_files/findidx_2_simple.sl 4 20000

# 4. If still fails → increase depth further
julia z3_smt_cegis.jl ../spec_files/findidx_2_simple.sl 5 50000
```

### Parameter Effects

**Increasing max_depth**:
- ✅ More expressive programs possible
- ❌ Exponentially more candidates to try
- 💡 Use: When synthesis fails and you think the solution exists

**Increasing max_enumerations**:
- ✅ More candidates tried (more thorough search)
- ❌ Longer runtime
- 💡 Use: When synthesis fails but max_depth looks sufficient

**Decreasing max_depth** (if synthesis is too slow):
- ✅ Fast partial exploration
- ❌ May miss valid solutions
- 💡 Use: To quickly understand problem difficulty

### Recommended Starting Points

| Problem Type | max_depth | max_enumerations |
|--------------|-----------|------------------|
| Simple (1-2 constraints) | 3-4 | 5,000 |
| Medium (3-5 constraints) | 4-6 | 20,000 |
| Complex (5+ constraints) | 6-8 | 50,000 |
| Large/Industrial | 8-12 | 100,000+ |

---

## Understanding Output

### Result Status

**Status: SUCCESS** ✅
```
Status:              SUCCESS
Iterations:          5
Counterexamples:     4
Synthesized Program: <expr>
```
✓ Found a program that satisfies all constraints

**Status: FAILURE** ❌
```
Status:              FAILURE
Iterations:          50000
Counterexamples:     32
No solution found within resource limits
```
✗ Exhausted search space without finding valid program
→ Solution may not exist, or parameters need tuning

**Status: TIMEOUT** ⏱️
```
Status:              TIMEOUT
Iterations:          12000
Counterexamples:     11
No solution found within resource limits
```
⏱ Exceeded time/resource limits
→ Problem may be too hard; increase max_depth/max_enumerations carefully

### Interpreting Counterexamples

```
Counterexamples collected during synthesis:
  [1] Input: Dict(x1 => 6, x2 => 7, x3 => 2)
      Expected: 13
      Got:      9
  [2] Input: Dict(x1 => 1, x2 => 2, x3 => 8)
      Expected: 10
      Got:      8
```

Each counterexample shows:
- **Input**: Variable values that trigger the error
- **Expected**: What spec says output should be
- **Got**: What candidate program produced

These are learning signals used to eliminate bad solutions and guide search.

### Interpreting Synthesis Program

```
Synthesized Program: ifelse(x1 > 5, x1 + x2, ifelse(x2 > 5, x2 + x3, 0))
```

This is a **Julia infix expression** that satisfies all constraints.  
It encodes the synthesized algorithm as a nested if-then-else.

---

## Advanced: Testing Specific Candidates

### Verify a Candidate Program

If you have a candidate program you want to test:

```bash
julia z3_smt_cegis.jl \
  ../spec_files/findidx_problem.sl \
  6 50000 \
  "ifelse(x1 > 5, x1 + x2, x2 + x3)"
```

**Output**:
```
📌 Testing provided candidate with counterexamples found by synthesis...

════════════════════════════════════════════════════════════════════════════════
🎯 TESTING PROVIDED CANDIDATE
════════════════════════════════════════════════════════════════════════════════
Candidate string: ifelse(x1 > 5, x1 + x2, x2 + x3)

Current counterexamples (to be satisfied):
  [1] Input: (x1, x2, x3) => (6, 7, 2) => 13
  [2] Input: (x1, x2, x3) => (1, 1, 8) => 9
  ...

Running Z3 formal verification...
  Candidate (SMT): (ite (> x1 5) (+ x1 x2) (+ x2 x3))
  Z3 Status: :sat
  ❌ Z3: INVALID - Found counterexample violating constraints
  Model Input: Dict(x1 => 1, x2 => 1, x3 => 2)
  Expected (from spec): 0
  Got candidate:        2
════════════════════════════════════════════════════════════════════════════════
```

This shows the candidate is **not valid** — it violates constraints at input (x1=1, x2=1, x3=2).

---

## Working with SyGuS Specifications

### Understanding Spec File Format

**File**: `spec_files/findidx_problem.sl`

```smt2
(set-logic LIA)                                          ; Logic: Linear Integer Arithmetic
(synth-fun fnd_sum ((y1 Int) (y2 Int) (y3 Int)) Int )  ; Synthesis function signature
(declare-var x1 Int)                                    ; Free variables
(declare-var x2 Int)
(declare-var x3 Int)
(constraint                                             ; Constraints as implications
  (=> (> (+ x1 x2) 5) (= (fnd_sum x1 x2 x3) (+ x1 x2))))
(constraint
  (=> (and (<= (+ x1 x2) 5) (> (+ x2 x3) 5))
      (= (fnd_sum x1 x2 x3) (+ x2 x3))))
(constraint
  (=> (and (<= (+ x1 x2) 5) (<= (+ x2 x3) 5))
      (= (fnd_sum x1 x2 x3) 0)))
(check-synth)                                           ; End of spec
```

**Key Elements**:
- **Logic**: QF_LIA (quantifier-free linear integer arithmetic)
- **Synth-fun**: Function to synthesize (name, parameters with types, return type)
- **Free vars**: Variables that appear in constraints
- **Constraints**: Implications that guide synthesis
- **Check-synth**: Terminator

### Creating Your Own Spec

**Template**:
```smt2
(set-logic LIA)
(synth-fun my_func ((param1 Int) (param2 Int)) Int)
(declare-var x Int)
(declare-var y Int)
(constraint (=> (> x 10) (= (my_func x y) (+ x y))))
(constraint (=> (<= x 10) (= (my_func x y) (* x y))))
(check-synth)
```

**Steps**:
1. Pick a logic (LIA, NIA, BV, SLIA, etc.)
2. Define synthesis function with parameters
3. Declare free variables
4. Add constraints as implications: `(=> condition (= (func ...) expected_output))`
5. Add `(check-synth)` at end

**Save as**: `spec_files/my_spec.sl`

**Run synthesis**:
```bash
julia z3_smt_cegis.jl ../spec_files/my_spec.sl 6 50000
```

---

## Troubleshooting

### Problem: "Spec file not found"

**Symptom**:
```
Error: Spec file not found: ../spec_files/myspec.sl
```

**Solution**:
```bash
# Check current directory
pwd

# Navigate to scripts/ directory
cd scripts

# Verify spec file exists
ls ../spec_files/findidx_problem.sl
```

### Problem: "No solution found within resource limits"

**Symptom**:
```
Status: FAILURE
Iterations: 50000
No solution found within resource limits
```

**Possible Causes & Solutions**:

1. **max_depth too small**: Solution is too complex
   ```bash
   # Try increasing depth
   julia z3_smt_cegis.jl ../spec_files/my_spec.sl 8 50000
   ```

2. **max_enumerations too small**: Not enough candidates tried
   ```bash
   # Try more enumerations
   julia z3_smt_cegis.jl ../spec_files/my_spec.sl 6 200000
   ```

3. **Problem unsolvable**: No program satisfies constraints
   - Verify spec manually: Are constraints consistent?
   - Try smaller sub-spec: Simplify constraints

4. **Grammar incomplete**: Missing operators
   - Edit `build_grammar_from_spec_file()` in z3_smt_cegis.jl
   - Add operators you know solution needs (e.g., `-`, `*`, comparison ops)

### Problem: "Invalid type: Bool + Int"

**Symptom**:
```
ERROR: type error in generated queries
```

**Cause**: InfixCandidateParser is too strict about types

**Solution**:
1. Edit `z3_smt_cegis.jl` line 270
2. Change:
   ```julia
   oracle = Z3Oracle(spec_file, grammar)
   ```
   To:
   ```julia
   oracle = Z3Oracle(spec_file, grammar, parser=CEXGeneration.SymbolicCandidateParser())
   ```
3. Rerun synthesis

**Why**: SymbolicCandidateParser automatically coerces mixed types with ITE expressions

### Problem: Z3 query syntax error

**Symptom**:
```
ERROR: Invalid SMT-LIB2 syntax in query
```

**Possible Causes**:
1. Unsupported operators in grammar
2. Variable names with special characters
3. Logic mismatch (grammar generates operators not in specified logic)

**Solution**:
1. Check grammar construction in `build_grammar_from_spec_file()`
2. Verify all operators are valid for the logic (QF_LIA has no multiplication!)
3. See CEXGeneration/README.md for supported operations

### Problem: Z3 crashes or times out

**Symptom**:
```
STATUS: :error (Z3 timeout/crash)
```

**Solutions**:
1. Reduce max_enumerations (fewer Z3 calls)
2. Reduce max_depth (simpler programs)
3. Simplify constraints (fewer/easier conditions)
4. Try simpler spec file first

---

## Comparing Different Oracles

### Z3Oracle (Default: What We Use)

**Characteristics**:
- ✅ Formal verification (SAT-based)
- ✅ Complete search (guaranteed to find solution if exists)
- ✅ Fast (native Z3 API)
- ❌ Requires SMT logic support

**When to use**: Most problems

**Command**:
```bash
julia z3_smt_cegis.jl ../spec_files/findidx_problem.sl
```

### IOExampleOracle (Test-Based)

**Characteristics**:
- ✅ Simple (just evaluate on examples)
- ✅ No SMT overhead
- ❌ Incomplete (misses corner cases)
- ❌ Requires explicit test cases

**When to use**: When you have fixed test cases

**Script**: See `archive/manual_oracle_cegis.jl` for example

### SemanticSMTOracle (Legacy SMT)

**Characteristics**:
- ✅ Formal verification
- ❌ Slower (intermediate representation overhead)
- ❌ Less transparent query building

**When to use**: Comparison studies only

**Script**: See `archive/semantic_smt_cegis.jl`

---

## Performance Tips

### Reduce Runtime

1. **Use simpler spec first**:
   ```bash
   # Quick validation
   julia z3_smt_cegis.jl ../spec_files/findidx_2_simple.sl 3 5000
   ```

2. **Lower max_depth if not needed**:
   ```bash
   # Depth 4 instead of 6
   julia z3_smt_cegis.jl ../spec_files/findidx_problem.sl 4 50000
   ```

3. **Remove unnecessary operators from grammar**:
   - Edit `build_grammar_from_spec_file()` in z3_smt_cegis.jl
   - Comment out operators not needed in solution

### Improve Success Rate

1. **Match grammar to logic**:
   - QF_LIA: Use `+`, `-`, `<`, `>`, `<=`, `>=`, `=`
   - Don't use `*`, `^`, `/` in QF_LIA!

2. **Add operators solution likely needs**:
   - If spec uses `<=`: Add `BoolExpr = Expr <= Expr`
   - If output is mix of conditions: Add `Expr = ifelse(BoolExpr, Expr, Expr)`

3. **Start with working example**:
   - Use `findidx_2_simple.sl` to validate setup
   - Then gradually increase complexity

---

## Example Workflows

### Workflow 1: Quick Validation

```bash
# Does the system work? (2 min)
cd scripts
julia z3_smt_cegis.jl ../spec_files/findidx_2_simple.sl 3 5000
# ✓ Should succeed in <10 sec
```

### Workflow 2: Solve New Problem

```bash
# Create spec (my_problem.sl in spec_files/)
# Start small
julia z3_smt_cegis.jl ../spec_files/my_problem.sl 3 5000
# If fails, gradually increase
julia z3_smt_cegis.jl ../spec_files/my_problem.sl 4 10000
julia z3_smt_cegis.jl ../spec_files/my_problem.sl 5 20000
# ✓ Until success
```

### Workflow 3: Test Specific Candidate

```bash
# Someone proposes a candidate
# Verify it's correct
julia z3_smt_cegis.jl ../spec_files/findidx_problem.sl 6 50000 \
  "ifelse(x1 > 5, x1 + x2, ifelse(x2 > 5, x2 + x3, 0))"
# Reports: valid ✓ or invalid ✗ with counterexample
```

### Workflow 4: Compare Parsers

```bash
# Try default (InfixCandidateParser)
julia z3_smt_cegis.jl ../spec_files/my_problem.sl 6 50000
# If type errors → switch to SymbolicCandidateParser
# Edit line 270 in z3_smt_cegis.jl to use SymbolicCandidateParser
# Rerun same command
```

---

## Next Steps

- **Read**: [ARCHITECTURE_OVERVIEW.md](ARCHITECTURE_OVERVIEW.md) for technical details
- **Explore**: [Z3_ORACLE_GUIDE.md](Z3_ORACLE_GUIDE.md) for verification details
- **Reference**: [API_REFERENCE.md](API_REFERENCE.md) for function signatures
- **Debug**: Check [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for troubleshooting

---

**Last Updated**: March 28, 2026
