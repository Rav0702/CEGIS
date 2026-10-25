# Fix Summary - RuleNode to SMT Conversion

## Issue
`UndefVarError: RuleNode not defined in Main.CEGIS.CEXGeneration`

## Root Cause
The `rulenode_to_smt.jl` file was missing imports for `RuleNode` and `AbstractGrammar` types, and was incorrectly accessing the grammar API.

## Solution Applied

### 1. Added Missing Imports (Line 14-15)
```julia
using HerbCore        # Provides RuleNode type
using HerbGrammar     # Provides AbstractGrammar type
```

### 2. Fixed Grammar API Usage
**Before:**
```julia
rule = grammar.rules[rule_idx]
smt, typ = _terminal_to_smt(rule.name, rule)  # ❌ rule.name doesn't exist
```

**After:**
```julia
rule_expr = grammar.rules[rule_idx]  # Direct expression from grammar
smt, typ = _terminal_to_smt(rule_expr, grammar, rule_idx)  # ✅ Correct API
```

### 3. Updated Function Signatures
**Before:**
```julia
function _terminal_to_smt(name::Symbol, rule)::Tuple{String, Symbol}
```

**After:**
```julia
function _terminal_to_smt(rule_expr::Any, grammar::AbstractGrammar, rule_idx::Int)::Tuple{String, Symbol}
```

### 4. Fixed RuleNode Field Access
**Before:**
```julia
rule_idx = node.rule_index  # ❌ Wrong field name
```

**After:**
```julia
rule_idx = node.ind  # ✅ Correct RuleNode field
```

## HerbGrammar API Reference

```julia
# Correct way to access rules from a grammar:
rule_expr = grammar.rules[i]          # Get rule expression at index i
rule_type = grammar.types[i]          # Get rule type at index i
is_terminal = grammar.isterminal[i]   # Check if terminal

# RuleNode structure:
node.ind                              # Rule index
node.children                         # Child RuleNodes
```

## Files Modified
- ✅ `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/rulenode_to_smt.jl`

## Next Steps
1. All syntax issues resolved
2. Try loading CEGIS module with dependencies installed
3. Test with actual synthesis problems
