"""
This file documents the changes needed to support declare-fun in the CEGIS system.

CURRENT STATE
=============

The system now parses declare-fun statements correctly:
- findidx_2_declare_fun.sl is parsed successfully
- Declared functions are stored in spec.declared_functions
- The parser extracts function signatures (param types, return type)

WHAT'S NEEDED TO FULLY SUPPORT declare-fun
============================================

1. Enhanced SMT-LIB String Parsing
   Currently: _sexpr_to_symbolic() errors on unknown operators
   Needed: Handle uninterpreted function calls as special symbolic terms
   
   Example:
   - Input: "(im true false)" where im is declared but not defined
   - Currently: ERROR "Unsupported SMT-LIB operator: im"
   - Needed: Create a symbolic term representing the uninterpreted call

2. Z3 Uninterpreted Function Support
   Currently: Only works with standard SMT-LIB operators (+, -, <, =, etc.)
   Needed: Pass uninterpreted function calls to Z3 as abstract symbols
   
   The Z3 solver can handle uninterpreted functions, but we need to:
   - Create Z3 function declarations for declared-fun statements
   - Build Z3 function applications when parsing SMT-LIB constraints
   - Let Z3's constraint solver treat them as abstract predicates

3. Constraint Substitution for define-fun
   Currently: define-fun is parsed but not used when expanding constraints
   Needed: When building constraints, substitute define-fun calls with their bodies
   
   Example:
   - Define: (define-fun im ((b1 Bool) (b2 Bool)) Bool (or b1 b2))
   - Constraint: (im (> x 0) (< x 5))
   - Substitute: (or (> x 0) (< x 5))

ARCHITECTURE FOR FULL SUPPORT
==============================

Option 1: Symbolic Wrapper Approach
  - Wrap uninterpreted function calls as SymbolicUtils terms
  - Pass through to Z3 conversion layer
  - Z3 layer recognizes and creates uninterpreted function symbols
  
  Pros: Minimal changes to existing code
  Cons: Need to enhance Z3 integration layer

Option 2: Direct Z3 Constraint Building  
  - Build Z3 constraints directly from SMT-LIB strings
  - Skip SymbolicUtils conversion for constraints with declare-fun
  - Use Z3's native constraint building for uninterpreted functions
  
  Pros: Can leverage Z3's full capabilities
  Cons: More complex, bypasses SymbolicUtils abstraction

Option 3: Hybrid Approach (Recommended)
  - Keep SymbolicUtils for standard operators
  - Create placeholder symbolic terms for uninterpreted functions
  - In Z3 conversion, detect these placeholders and build Z3 function terms
  - For define-fun: substitute inline before parsing

TESTING WITH CURRENT VERSION
=============================

The declare-fun version script works for constraints without declared functions:
  julia semantic_smt_cegis_declared_fun.jl findidx_2_simple.sl  # Works
  julia semantic_smt_cegis_declared_fun.jl findidx_2_declare_fun.sl  # Fails on constraint with 'im'

The error occurs because constraint 2 uses the 'im' function which cannot be
converted to SymbolicUtils (it's uninterpreted, has no definition).

NEXT STEPS
==========

To fully implement declare-fun support:

1. Modify _sexpr_to_symbolic to not error on unknown operators
   Instead, create opaque symbolic terms that can be passed to Z3

2. Enhance SymbolicSMT.jl's to_z3 conversion to handle uninterpreted functions
   Create Z3 function declarations and applications

3. Add define-fun substitution logic
   Before parsing constraints, expand define-fun calls

4. Add integration tests with specs that use declare-fun and define-fun together

FILES INVOLVED
==============
- parse_sygus.jl: ✓ Already parses both define-fun and declare-fun
- semantic_smt_oracle_declared_fun.jl: Attempted extended oracle (incomplete)
- semantic_smt_cegis_declared_fun.jl: Script using extended oracle
- SymbolicSMT.jl: Needs enhancement for uninterpreted function handling
- semantic_smt_oracle.jl: _sexpr_to_symbolic needs to handle unknown operators gracefully
"""
