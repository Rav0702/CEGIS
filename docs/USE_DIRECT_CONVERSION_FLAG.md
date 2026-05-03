"""
Test script showing the new use_direct_conversion flag

This demonstrates how to enable the new direct RuleNode→SMT-LIB2 conversion
instead of the old multi-stage approach.
"""

# Example 1: Default behavior (old multi-stage approach)
# oracle = Z3Oracle("problem.sl", grammar)
# This uses:
#   RuleNode → Expr → String → SMT-LIB2 (via InfixCandidateParser)

# Example 2: Enable new direct conversion (RECOMMENDED)
# oracle = Z3Oracle("problem.sl", grammar, use_direct_conversion=true)
# This uses:
#   RuleNode → SMT-LIB2 (direct tree walk with type tracking)

# Example 3: Keep old approach but with custom parser
# oracle = Z3Oracle("problem.sl", grammar, parser=SymbolicCandidateParser())
# This uses:
#   RuleNode → Expr → String → SMT-LIB2 (via SymbolicCandidateParser)

# Example 4: Custom parser + direct conversion (mixing approaches not recommended)
# oracle = Z3Oracle("problem.sl", grammar, parser=SymbolicCandidateParser(), use_direct_conversion=true)
# This uses:
#   RuleNode → SMT-LIB2 (the parser argument is ignored when use_direct_conversion=true)

"""
ALIGNMENT CHECK (Master branch as of 13 April 2026):

✓ File: CEGIS/src/CEXGeneration/rulenode_to_smt.jl
  - Direct RuleNode → SMT-LIB2 converter implementation
  - Type-aware recursive descent parser
  - Handles Bool/Int type coercion
  
✓ File: CEGIS/src/CEXGeneration/CEXGeneration.jl
  - Exports rulenode_to_smt2 function
  - Includes rulenode_to_smt.jl module

✓ File: CEGIS/src/Oracles/z3_oracle.jl
  - Z3Oracle struct updated: added use_direct_conversion::Bool field
  - Constructor signature: added use_direct_conversion parameter (default: false)
  - extract_counterexample(): conditional logic using the flag
    - If use_direct_conversion=true: calls CEXGeneration.rulenode_to_smt2()
    - If use_direct_conversion=false: uses old path (rulenode2expr → string → parser)

PERFORMANCE COMPARISON:

Old approach (default):
  ├─ rulenode2expr (tree walk)
  ├─ string conversion
  ├─ tokenise_infix (string → tokens)
  ├─ operator precedence lookup
  ├─ recursive descent parse
  └─ Result: "(ite (> x y) x y)"
  
  Time complexity: O(n) × 5 transformations + tokenization overhead
  
New approach (use_direct_conversion=true):
  ├─ rulenode_to_smt2 (tree walk with type context)
  └─ Result: "(ite (> x y) x y)"
  
  Time complexity: O(n) × 1 transformation

BACKWARDS COMPATIBILITY:

✓ Default behavior unchanged (use_direct_conversion=false)
✓ Old parser mechanism still available
✓ Gradual migration path:
  - Start with use_direct_conversion=true
  - Test compatibility
  - Gradually convert codebase if needed
  - Old path always available as fallback

USAGE IN EXPERIMENTS:

To enable the new converter in your experiments:

    oracle = CEXGeneration.Z3Oracle(
        spec_file,
        grammar,
        use_direct_conversion=true  # ← NEW FLAG
    )

Then run your synthesis experiment as usual:
    result = run_problem(problem, iterator, oracle; max_time=config.max_time)

The only difference is the internal conversion method - the interface remains the same.
"""

# Development notes:
# - The flag is stored on the oracle instance
# - Can be changed per-oracle (not global)
# - Old code doesn't need modification
# - New code gets faster conversion automatically
