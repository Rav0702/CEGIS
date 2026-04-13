"""
DEMONSTRATION: RuleNode → SMT-LIB2 Direct Conversion

This file shows the new simplified approach vs. the old multi-stage approach.
"""

# ═════════════════════════════════════════════════════════════════════════════
# OLD APPROACH (Multi-stage, still works)
# ═════════════════════════════════════════════════════════════════════════════

"""
OLD: RuleNode → Julia Expr → Infix String → SMT-LIB2

This is what the current z3_oracle.jl does:
"""
function old_candidate_to_smt(candidate::RuleNode, grammar::AbstractGrammar)::String
    # Step 1: RuleNode → Julia Expr
    candidate_expr = HerbGrammar.rulenode2expr(candidate, grammar)
    
    # Step 2: Julia Expr → Infix String
    candidate_readable = string(candidate_expr)
    
    # Step 3: Infix String → SMT-LIB2 (via parser)
    candidate_str = CEXGeneration.to_smt2(
        CEXGeneration.get_default_candidate_parser(),
        candidate_readable
    )
    
    return candidate_str
end

# Issues with old approach:
# ├─ Information loss: Grammar structure lost after expr → string
# ├─ String round-trip: "ifelse(x>y,x,y)" requires tokenization/parsing
# ├─ Dual parsers: InfixCandidateParser + SymbolicCandidateParser duplicate logic
# ├─ Type tracking: Lost after conversion to string
# └─ Performance: 3 transformations + tokenization + recursive descent parsing


# ═════════════════════════════════════════════════════════════════════════════
# NEW APPROACH (Direct, simpler)
# ═════════════════════════════════════════════════════════════════════════════

"""
NEW: RuleNode → SMT-LIB2 (direct)

This is what the new rulenode_to_smt.jl provides:
"""
function new_candidate_to_smt(candidate::RuleNode, grammar::AbstractGrammar)::String
    # Single transformation: direct tree traversal with type tracking
    return CEXGeneration.rulenode_to_smt2(candidate, grammar)
end

# Benefits of new approach:
# ├─ Single transformation: no intermediate representations
# ├─ Type tracked: Bool vs Int preserved throughout
# ├─ One algorithm: unified handling for both strict & flexible type coercion
# ├─ Direct grammar access: apply operator precedence correctly
# └─ Performance: No string conversion, no tokenization, just tree walk


# ═════════════════════════════════════════════════════════════════════════════
# COMPARISON: PERFORMANCE
# ═════════════════════════════════════════════════════════════════════════════

# Example: candidate = ifelse(x > y, x, y)

# OLD APPROACH:
#   1. rulenode2expr()            ← tree walk → Expr object
#   2. string()                   ← Expr → "ifelse(x > y, x, y)"
#   3. tokenise_infix()           ← string → ["ifelse","(","x",">","y",",","x",",","y",")"]
#      (+ implicit mult. post-processing hack)
#   4. operator precedence dict   ← precedence lookup
#   5. recursive descent parse    ← build SMT from tokens
#   6. Result: "(ite (> x y) x y)"
#   TIME: 6 transformation steps, string allocation, tokenization overhead

# NEW APPROACH:
#   1. rulenode_to_smt2()         ← tree walk with type context
#      └─ Traverse children with appropriate type contexts
#      └─ Build SMT strings directly at each node
#   2. Result: "(ite (> x y) x y)"
#   TIME: 1 transformation, direct string building


# ═════════════════════════════════════════════════════════════════════════════
# MIGRATION GUIDE: HOW TO SWITCH
# ═════════════════════════════════════════════════════════════════════════════

"""
Option 1: Drop-in replacement in z3_oracle.jl

Instead of:
    candidate_expr = HerbGrammar.rulenode2expr(candidate, oracle.grammar)
    candidate_readable = string(candidate_expr)
    candidate_str = CEXGeneration.to_smt2(oracle.parser, candidate_readable)

Use:
    candidate_str = CEXGeneration.rulenode_to_smt2(candidate, oracle.grammar)
    
This is shorter, faster, and preserves type information!
"""

# Option 2: Keep both for gradual migration
#
# You can use whichever parser is configured:
#   - If InfixCandidateParser or SymbolicCandidateParser is set, use old path
#   - Add flag: oracle.use_direct_conversion = true to use new path
#
# Example:
function extract_counterexample_v2(oracle, problem, candidate::RuleNode)
    if haskey(oracle, :use_direct_conversion) && oracle.use_direct_conversion
        # NEW: Direct conversion
        candidate_str = CEXGeneration.rulenode_to_smt2(candidate, oracle.grammar)
    else
        # OLD: Via parser (for backwards compatibility)
        candidate_expr = HerbGrammar.rulenode2expr(candidate, oracle.grammar)
        candidate_readable = string(candidate_expr)
        candidate_str = CEXGeneration.to_smt2(oracle.parser, candidate_readable)
    end
    
    # Rest of verification logic...
end


# ═════════════════════════════════════════════════════════════════════════════
# EXAMPLES
# ═════════════════════════════════════════════════════════════════════════════

"""
Example 1: Simple max function
"""
# Candidate: if x > y then x else y
example1_result = """
Input (RuleNode):
  ifelse
    ├─ > (x, y)
    ├─ x
    └─ y

Output (SMT-LIB2):
  "(ite (> x y) x y)"
"""

"""
Example 2: Mixed bool-int (requires Bool→Int coercion in arithmetic)
"""
# Candidate: (x > y) * x
# Context: expecting Int result
example2_result = """
Input (RuleNode):
  *
    ├─ > (x, y)        [produces Bool]
    └─ x               [Int]

Type coercion at * operator:
  - Left operand Bool but * needs Int
  - Coerce: (> x y) → (ite (> x y) 1 0)

Output (SMT-LIB2):
  "(* (ite (> x y) 1 0) x)"
"""

"""
Example 3: Complex nested expression
"""
# Candidate: if (x > 0) and (y < 10) then x+y else 0
example3_result = """
Input (RuleNode):
  ifelse
    ├─ and
    │   ├─ > (x, 0)
    │   └─ < (y, 10)
    ├─ + (x, y)
    └─ 0

Output (SMT-LIB2):
  "(ite (and (> x 0) (< y 10)) (+ x y) 0)"
"""


# ═════════════════════════════════════════════════════════════════════════════
# TECHNICAL NOTES
# ═════════════════════════════════════════════════════════════════════════════

"""
Type Tracking During Conversion:

The new converter maintains type context at each node:

  rulenode_to_smt2(node, grammar, expected_type)
  
At arithmetic operators (+, -, *):
  - Require Int operands
  - If Bool operand received: wrap (ite bool 1 0)
  - If context expects Bool: wrap result (> result 0)

At comparison operators (>, <, =, etc.):
  - Require Int operands
  - Return Bool naturally
  - If context expects Int: wrap (ite result 1 0)

At if-then-else (ite):
  - Condition must be Bool (coerce if needed)
  - Then/else match expected type (coerce if needed)

This ensures type-safe conversion and automatic mixed-type handling.
"""

"""
Supported Operators:

Arithmetic:
  :+ → "+"
  :- → "-"
  :* → "*"

Comparison:
  :(>) → ">"
  :(<) → "<"
  :(>=) → ">="
  :(<=) → "<="
  :(==) → "="
  :(!=) → "distinct"

Boolean:
  :and → "and"
  :or → "or"
  :not → "not"

Control:
  :ifelse, :ite → "ite"
"""

"""
Limitations:

1. Requires RuleNode & grammar (cannot convert raw infix strings)
   - Solution: Use old to_smt2() for raw strings if needed
   
2. No support for user-defined functions (only operators in grammar)
   - Solution: Extend _rulenode_to_smt_impl to handle custom functions
   
3. Variables assumed Int by default
   - Solution: Could accept type signature parameter in future
"""
