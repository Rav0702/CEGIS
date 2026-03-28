# Z3 SMT CEGIS: Architecture Overview

**Purpose**: Understand how z3_smt_cegis components fit together and data flows through the system.

---

## High-Level System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  z3_smt_cegis.jl (Entry Point)                                  │
│  - Parse command-line arguments                                 │
│  - Orchestrate workflow                                         │
│  - Report results                                               │
└──────────────────┬──────────────────────────────────────────────┘
                   │
        ┌──────────┴──────────┐
        ▼                     ▼
    SyGuS Spec File    build_grammar_from_spec_file()
    (.sl file)         - Call CEXGeneration.parse_spec_from_file()
                       - Extract variables from spec
                       - Build Herb grammar with operators
                            │
                            ▼
                     Grammar{Expr, BoolExpr}
                     (Synthesis search space)
                            │
        ┌───────────────────┴────────────────────┐
        ▼                                        ▼
   Z3Oracle()                          oracle_synth.jl
   - Store Spec object                 (synth_with_oracle)
   - Initialize Z3 context             │
   - Setup SMT-LIB2 infrastructure      ├─ For each iteration:
        │                              │   1. Synthesizer: enumerate candidates
        ▼                              │   2. Verifier: call oracle.extract_cex()
   Ready for verification              │      ├─ RuleNode → Infix expr
                                       │      ├─ Infix → SMT-LIB2
                                       │      ├─ generate_cex_query()
                                       │      ├─ verify_query() [Z3 native]
                                       │      └─ → Counterexample or nil
                                       │   3. Learner: learn from counterexample
                                       │   4. Grammar: add constraints
                                       │   Until: found valid OR max resources
                                       │
                                       ▼
                                CEGISResult{
                                  status: success|failure|timeout,
                                  program: RuleNode | nil,
                                  iterations: Int,
                                  counterexamples: [Counterexample]
                                }
                                       │
                                       ▼
                            Report to user & exit
```

---

## Detailed Component Interaction

### 1. Specification Parsing Layer

```
SyGuS .sl File
       │
       ▼
CEXGeneration.parse_spec_from_file()
       │
       ├─ Tokenize/Lex S-expressions (sexp.jl)
       │   (set-logic LIA)
       │   (synth-fun fnd_sum (...) Int)
       │   (declare-var x1 Int)
       │   (constraint (...))
       │
       ├─ Parse structure (parser.jl)
       │   ├─ Extract logic: LIA, NIA, BV, etc.
       │   ├─ Synth function: name, params, return sort
       │   ├─ Free variables: names and types
       │   ├─ Constraints: raw SMT code
       │   └─ Inv-constraint expansion (if present)
       │
       ▼
   Spec {
     logic: String,
     synth_funs: [SynthFun],
     free_vars: [FreeVar],
     constraints: [String]  # SMT-LIB2 format
   }
```

**Key Files**:
- `src/CEXGeneration/sexp.jl` — S-expression tokenizing and parsing
- `src/CEXGeneration/parser.jl` — SyGuS-v2 specification parsing
- `src/CEXGeneration/types.jl` — Spec, SynthFun, FreeVar data structures

---

### 2. Grammar Building Layer

```
Spec Object
    │
    ├─ Extract free variable names: {x1, x2, x3, ...}
    │
    ▼
Grammar String Construction:
    "Expr = 0"
    "Expr = 1"
    "Expr = 2"
    "Expr = x1"              ← from spec.free_vars
    "Expr = x2"
    "Expr = x3"
    "Expr = Expr + Expr"     ← operators
    "Expr = BoolExpr + Expr" ← mixed types (SymbolicParser)
    "BoolExpr = Expr >= Expr"
    "..."
    │
    ▼
Grammar (Herb internal):
    rules: [
      Expr → 0,
      Expr → 1,
      Expr → x1,
      Expr → Expr + Expr,
      BoolExpr → Expr >= Expr,
      ...
    ]
    │
    ├─ Each rule is a RuleNode with unique ID
    ├─ Enables enumeration by depth/breadth
    └─ Constraints can eliminate rules during synthesis
```

**Key Files**:
- `scripts/z3_smt_cegis.jl:build_grammar_from_spec_file()` — Grammar construction
- `src/HerbGrammar` — @csgrammar macro and Grammar type (external)

---

### 3. Candidate Enumeration Layer

```
Grammar + Constraints
    │
    ▼
Synthesizer (src/synthesizer.jl)
    │
    ├─ BFS/DFS enumeration by depth
    ├─ Generates RuleNode candidates
    └─ One per synthesis iteration
         │
         ▼
    RuleNode {
      id: Int (rule ID),
      children: [RuleNode] (for composite rules)
    }
    │
    ├─ Represents derivation tree
    ├─ Can be converted to Expr/String
    └─ Passed to oracle for verification
```

**Key Files**:
- `src/synthesizer.jl` — Enumeration strategy
- `src/HerbCore` — RuleNode type (external)

---

### 4. Verification Layer: Z3Oracle

```
RuleNode Candidate
    │
    ├─→ rulenode2expr(candidate, grammar)
    │   └─→ Julia Expr (AST)
    │
    ├─→ Pluggable Parser (from src/CEXGeneration/candidates.jl)
    │   │
    │   ├─ InfixCandidateParser (default)
    │   │  └─ Strict SMT-LIB2 type checking
    │   │     Rejects: (Expr > Expr) + Expr  ← bool + int mismatch
    │   │
    │   └─ SymbolicCandidateParser (alternative)
    │      └─ Mixed types via ITE coercion
    │         Converts: (Expr > Expr) + Expr → (ite (Expr > Expr) 1 0) + Expr
    │
    ├─→ to_smt2(parser, expr_string)
    │   └─→ SMT-LIB2 String
    │       "(define-fun candidate (...) (+ x1 x2))"
    │
    ├─→ CEXGeneration.generate_cex_query(spec, {func_name: smt2_code})
    │   │
    │   ├─ Include spec context: variables, sorting assertions
    │   ├─ Negate constraints: (assert (not (and constraint1 constraint2 ...)))
    │   │  Rationale: SAT = counterexample found; UNSAT = verified
    │   ├─ Define helper spec function from implications
    │   │  "(define-fun func_spec (...) (ite cond1 out1 (ite cond2 out2 ...)))"
    │   ├─ Include candidate definition
    │   ├─ Add check-sat and get-value commands
    │   │
    │   └─→ Full SMT-LIB2 Query String
    │
    ├─→ CEXGeneration.verify_query(query)
    │   │
    │   ├─ Call Z3 via native API (no subprocess)
    │   ├─ Parse Z3 response (status, model)
    │   │  Status: :sat (counterexample found), :unsat (verified)
    │   │  Model: variable assignments {x1: 3, x2: 5, ...}
    │   │
    │   └─→ Z3Result{status, model}
    │
    └─→ extract_counterexample() [core Z3Oracle method]
        │
        ├─ If status == :unsat
        │  └─→ return nothing  (candidate verified ✓)
        │
        ├─ If status == :sat
        │  ├─ Extract input dict from model: {x1, x2, x3} values
        │  ├─ Extract expected output from spec function: expected_value
        │  ├─ Extract actual output from candidate: actual_value
        │  │  (if they differ → model is a true counterexample)
        │  │
        │  └─→ return Counterexample{input, expected, actual}
        │
        └─ If status == :error or other
           └─→ return nothing (unknown, assume verified for now)
```

**Key Files**:
- `src/Oracles/z3_oracle.jl` — Z3Oracle type and extract_counterexample() (lines 40-180+)
- `src/CEXGeneration/candidates.jl` — Pluggable parsers (InfixCandidateParser, SymbolicCandidateParser)
- `src/CEXGeneration/query.jl` — Query generation with constraint negation and spec function building
- `src/CEXGeneration/z3_verify.jl` — Z3 native verification and model extraction

---

### 5. Learning Layer

```
Counterexample {
  input: {x1: 3, x2: 5, x3: 1},
  expected: 8,
  actual: something_else
}
    │
    ▼
Learner (src/learner.jl):
    │
    ├─ Extract constraint from counterexample
    │  Rule: "Add what we know is wrong to grammar"
    │  Example: if candidate failed for input=(x1=3, x2=5, x3=1), expected=8
    │           learn constraint that excludes this behavior
    │
    ├─ Build constraint expression
    │  e.g., "¬(candidate with x1=3, x2=5, x3=1 returns wrong value)"
    │
    └─→ Constraint Expression
        │
        ▼
Grammar Update:
    │
    ├─ add_constraint_to_grammar!()
    │  └─ Mark rules that violate constraint as invalid
    │  └─ Prune search space
    │
    └─→ Updated Grammar (smaller search space)
        │
        ▼
Back to Synthesizer: Enumerate next candidate
(from smaller space, avoiding known bad programs)
```

**Key Files**:
- `src/learner.jl` — Constraint extraction and learning
- `src/synthesizer.jl` — Grammar constraint application

---

### 6. Main Loop Integration

```
CEGIS Loop (src/oracle_synth.jl):
┌──────────────────────────────────────────────────────────────┐
│ synth_with_oracle(grammar, :Expr, oracle; ...)               │
└──┬───────────────────────────────────────────────────────────┘
   │
   ├─ Initialize: satisfied_examples = 0
   │
   └─→ Loop (max_enumerations iterations or until found):
       │
       ├─ [1] Synthesizer: next_candidate = next(synthesizer)
       │
       ├─ [2] Verifier: extract_counterexample(candidate)
       │      ├─ If returns nothing → candidate verified!
       │      │  └─→ return success with candidate
       │      │
       │      └─ If returns Counterexample → not verified
       │         └─→ continue to learner
       │
       ├─ [3] Learner: learn from counterexample
       │      ├─ Build constraint from counterexample
       │      ├─ Add to grammar
       │      └─ Increment counterexample count
       │
       └─ [4] Repeat with updated grammar
            (next candidate from smaller search space)
       │
       ├─ Until: found valid (status=success)
       ├─ Until: exhausted enumerations (status=failure)
       └─ Until: timeout (status=timeout)
```

**Key Files**:
- `src/oracle_synth.jl` — synth_with_oracle() main loop
- `src/synthesizer.jl`, `src/learner.jl`, oracle implementations

---

## Data Flow Summary

```
.sl File
   │
   ├─→ CEXGeneration.parse_spec_from_file()
   │   └─→ Spec Object
   │
   ├─→ build_grammar_from_spec_file()
   │   └─→ Grammar Object
   │
   ├─→ Z3Oracle(spec_file, grammar)
   │   └─→ Z3Oracle Instance (ready to verify)
   │
   └─→ synth_with_oracle(grammar, :Expr, oracle)
       │
       ├─ Loop:
       │  ├─ Synthesizer → RuleNode
       │  ├─ Z3Oracle → extract_counterexample()
       │  │  ├─ RuleNode → Expr → SMT-LIB2
       │  │  ├─ generate_cex_query()
       │  │  ├─ verify_query() [Z3]
       │  │  └─ Counterexample | nil
       │  ├─ Learner → learn from Counterexample
       │  └─ Grammar → update
       │
       └─ Return: CEGISResult
```

---

## Alternative Execution Paths

### Path A: Using IOExampleOracle (Test-Based)

```
Instead of Z3Oracle, use IOExampleOracle:
  - Input: Vector{IOExample} with fixed input-output pairs
  - Verification: Evaluate candidate directly on each example
  - Simpler but less powerful (no formal guarantees)
```

### Path B: Using SemanticSMTOracle (Legacy SMT)

```
Instead of Z3Oracle.extract_counterexample():
  - Convert RuleNode → Symbolic expression (not SMT-LIB2)
  - Use SymbolicSMT to check satisfiability
  - Extract model from SymbolicUtils/Z3
  - Slower but more transparent (intermediate representation)
```

---

## Configuration Points

### 1. Spec Parsing

**Configuration**: SyGuS-v2 format  
**Support**:
- Logics: LIA, NIA, BV, SLIA, etc.
- Constraints: implications, logical combinations
- Inv-constraints: pre/trans/post decomposition

### 2. Grammar Building

**Configuration**: Operators and terminal symbols  
**Customize in**: `build_grammar_from_spec_file()` in z3_smt_cegis.jl
- Add/remove operators: `Expr = Expr + Expr`, `Expr = Expr - Expr`, etc.
- Add/remove constants: `Expr = 0`, `Expr = 1`, etc.
- Control recursion: `Expr = ifelse(BoolExpr, Expr, Expr)`

### 3. Candidate Parsing

**Configuration** (in Z3Oracle constructor):
```julia
oracle = Z3Oracle(spec_file, grammar, 
                  parser=CEXGeneration.SymbolicCandidateParser())
```

- `InfixCandidateParser` (default): Strict type checking
- `SymbolicCandidateParser`: Mixed bool-int with ITE coercion

### 4. Query Generation

**Configuration**: Constraint strategies  
**Current**: Negation + spec function building (query.jl)
- Could be extended for different constraint encodings
- Could support incremental solving for repeated queries

### 5. Synthesis Parameters

**Configuration** (in synth_with_oracle call):
- `max_depth::Int` — Maximum RuleNode depth (complexity limit)
- `max_enumerations::Int` — Maximum candidates to try

---

## Module Dependencies

```
z3_smt_cegis.jl (script)
  │
  ├─ HerbCore                    → RuleNode, grammar operations
  ├─ HerbGrammar                 → @csgrammar macro, Grammar type
  ├─ HerbSearch                  → Enumeration strategies
  ├─ HerbInterpret               → rulenode2expr(), expression evaluation
  │
  ├─ CEGIS.jl (module)
  │  ├─ CEXGeneration            → parse_spec_from_file, generate_cex_query, verify_query
  │  ├─ Oracles.AbstractOracle   → Oracle interface
  │  ├─ Z3Oracle                 → extract_counterexample()
  │  │  └─ Z3.jl                 → Native Z3 API
  │  ├─ IOExampleOracle          → Alternative oracle
  │  ├─ synthesizer.jl           → Enumeration
  │  ├─ learner.jl               → Constraint learning
  │  ├─ verifier.jl              → Verification interface
  │  └─ oracle_synth.jl          → synth_with_oracle()
  │
  └─ CEGIS types
      └─ CEGISResult, Counterexample, VerificationResult
```

---

## Execution Timeline (Single Synthesis Run)

```
Time   Component                      Action
────────────────────────────────────────────────────
  0ms  z3_smt_cegis.jl               Parse args, load spec file
       
  +5ms CEXGeneration.parser          Parse spec (tokenize, extract structure)
       
 +10ms build_grammar_from_spec_file  Extract vars, build grammar object
       
 +15ms Z3Oracle.__init__             Setup Z3 context, create oracle
       
 +20ms synth_with_oracle             Start CEGIS loop
       
 +25ms [ITER 1] Synthesizer          Enumerate first candidate (depth 1)
 +30ms [ITER 1] Z3Oracle.extract_cex RuleNode → Expr → SMT-LIB2 → Z3 verify
 +40ms [ITER 1] Result: Counterex.   Found counterexample
 +45ms [ITER 1] Learner              Learn constraint from counterex.
 +50ms [ITER 1] Grammar              Update grammar (eliminate bad rules)
       
 +55ms [ITER 2] Synthesizer          Enumerate next candidate (depth 1, updated)
 +60ms [ITER 2] Z3Oracle.extract_cex Verify...
 +70ms [ITER 2] Result: Counterex.   Found counterexample
 +75ms [ITER 2] Learner & Grammar    Update...
       
 +80ms [ITER 3] Synthesizer          Enumerate next candidate (depth 2)
 +90ms [ITER 3] Z3Oracle.extract_cex Verify...
 +100ms [ITER 3] Result: VERIFIED    ✓ Candidate passes all constraints!
 +105ms synth_with_oracle            Return success with program
       
 +110ms z3_smt_cegis.jl              Report results & exit
```

---

## Performance Bottlenecks & Optimization Points

### Current Bottlenecks (Not Profiled)

1. **Z3 Verification**: Most expensive per-candidate operation
   - Z3Oracle.extract_counterexample() ~10-20ms per query typical
   - Grows with spec size and constraint complexity

2. **Enumeration**: Explosive growth in candidates
   - Grammar size × depth → exponential search space
   - Learning must eliminate rules aggressively

3. **Model Extraction**: Parsing Z3 response
   - Small overhead but repetitive

### Optimization Opportunities

1. **Z3OracleDirect**: Avoid string parsing overhead
   - Build Z3 expressions directly as objects
   - Could be 2-5x faster (untested)

2. **Incremental Solving**: Reuse Z3 state across iterations
   - Z3 supports pushing/popping assertions
   - Could avoid re-parsing constraints

3. **Parallel Enumeration**: Multi-threaded candidate generation
   - Thread-safe grammar traversal
   - Multiple independent Z3 contexts

4. **Grammar Compression**: Early learning to eliminate large subtrees
   - Better constraint propagation
   - Reduce branching factor

---

## Error Handling & Recovery

```
Failure Scenario          Z3Oracle Response    CEGIS Action
──────────────────────────────────────────────────────────
Z3 timeout               status: :error       Return nothing (assume verified)
Z3 crash                 Exception thrown     Catch, return nothing
Invalid SMT-LIB2         Parser error         Catch, return nothing
Model extraction fail    Empty model          Return nothing
Candidate eval fail      Runtime error        Catch, return nothing
Grammar exhausted        Synthesizer empty    Return failure (out of candidates)
Max iterations reached   Loop exits           Return failure (max_eumerations)
```

---

## Summary

**Z3 SMT CEGIS** is a **modular system** with clear separation of concerns:

1. **Parsing**: CEXGeneration reads specs → Spec objects
2. **Grammar**: build_grammar_from_spec_file() creates synthesis space
3. **Oracle**: Z3Oracle verifies candidates via SMT queries
4. **Loop**: oracle_synth() orchestrates Synthesizer, Verifier, Learner
5. **Results**: CEGISResult with program or counterexamples

Data flows in one direction:
- Spec → Grammar → Z3Oracle → CEGIS Loop → Result

Alternative execution paths (IOExampleOracle, SemanticSMTOracle) follow the same structure.

See **WORKFLOW_GUIDE.md** for step-by-step usage examples.
