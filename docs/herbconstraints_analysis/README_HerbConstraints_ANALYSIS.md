# HerbConstraints Architecture - Complete Analysis

This directory contains comprehensive documentation of the HerbConstraints system and its integration with HerbSearch iterators.

## Documentation Files

### 1. **HerbConstraints_Detailed_Analysis.md** (21 KB)
The main comprehensive analysis document covering:
- What are HerbConstraints and where they're defined
- How constraints are used in iterators (constraint flow)
- Whether constraints are iterator-agnostic (YES - they are!)
- How constraints filter/prune the search space
- What would be needed to add constraints to a BFS iterator (Already done!)
- Existing examples across different iterator types
- Key files and code sections
- Architecture diagrams
- Why constraints are iterator-agnostic

**Best for:** Understanding the overall architecture and design philosophy

### 2. **HerbConstraints_Code_Examples.md** (12 KB)
Practical code examples and quick reference guide including:
- Quick start: creating and using constraints
- Multiple constraint combinations
- Using constraints with different iterator types
- Understanding each constraint type (Forbidden, Ordered, Contains, etc.)
- How constraints work internally (propagation pipeline)
- Advanced: implementing custom constraints
- Testing constraints
- HerbStyle vs ASPStyle comparison
- Common patterns and use cases

**Best for:** Learning how to use constraints and implement custom ones

### 3. **HerbConstraints_File_Index.md** (13 KB)
Complete file reference with:
- All key files organized by category
- Line numbers for important functions
- File location summary with directory tree
- Quick navigation guide for common tasks
- Absolute file paths to all relevant files

**Best for:** Finding specific code and understanding where functionality is located

## Key Findings Summary

### Main Discovery: Constraints are Iterator-Agnostic

HerbConstraints are enforced at the **solver level**, not the iterator level. This means:

1. **Any iterator using a solver gets constraint support automatically**
   - BFSIterator ✓
   - DFSIterator ✓
   - RandomIterator ✓
   - BottomUpIterator ✓
   - Any custom iterator ✓

2. **Two solver types available:**
   - `GenericSolver`: Default, uses constraint propagation
   - `UniformSolver`: Backtracking-capable, used for fixed-shaped trees
   - `ASPSolver`: Alternative using Answer Set Programming

3. **Three-stage constraint system:**
   - Grammar constraints (user-facing)
   - Local constraints (runtime)
   - Propagation engine (solver-level)

### Constraint Architecture

```
Grammar (constraints field)
    ↓
Iterator (any type)
    ↓
Solver (GenericSolver or UniformSolver)
    ↓
Constraint Propagation Engine
    ├─ Pattern matching
    ├─ Domain reduction
    ├─ Feasibility checking
    └─ Fixed-point iteration
```

### How Constraints Work

1. **Posting**: User adds constraint to grammar
2. **Notification**: When tree expands, constraints are notified
3. **Conversion**: Grammar constraints become local constraints
4. **Scheduling**: Local constraints added to propagation queue
5. **Propagation**: Constraints execute deductions (remove impossible rules)
6. **Repropagation**: Tree changes trigger cascading constraint updates
7. **Feasibility**: Iterator backtracks from infeasible states

## Usage Quick Start

```julia
using HerbCore, HerbGrammar, HerbConstraints, HerbSearch

# Create grammar with constraints
grammar = @csgrammar begin
    Int = 1 | 2
    Int = Int + Int
end

# Add constraint - forbid identical children
forbidden = Forbidden(RuleNode(2, [VarNode(:a), VarNode(:a)]))
addconstraint!(grammar, forbidden)

# Constraints work with ANY iterator automatically!
for program in BFSIterator(grammar, :Int, max_size=5)
    @assert check_tree(forbidden, program)  # Always satisfied
end
```

## File Organization in CEGIS

```
/Users/howie/.julia/dev/CEGIS/
├── HerbConstraints_Detailed_Analysis.md    [Main architecture guide]
├── HerbConstraints_Code_Examples.md        [Practical examples]
├── HerbConstraints_File_Index.md           [File reference]
└── README_HerbConstraints_ANALYSIS.md      [This file]
```

## Key Conclusions

1. **HerbConstraints are iterator-agnostic** - They work with any iterator that uses a compatible solver

2. **Constraint enforcement is solver-based** - The solver handles all constraint logic automatically

3. **Two-layer constraint system** - Grammar constraints are user-friendly, local constraints handle runtime enforcement

4. **Pattern-matching based** - Constraints use sophisticated pattern matching with variable binding

5. **Fixed-point propagation** - Constraints are propagated until a fixed point is reached

6. **Multiple enforcement strategies** - Can use propagation (HerbStyle) or ASP/Clingo (ASPStyle)

7. **Comprehensive test coverage** - All iterator types tested with various constraint combinations

## What To Read First

1. **For Overview**: Read the "Summary of Findings" section in `HerbConstraints_Detailed_Analysis.md`

2. **For Quick Start**: Go to `HerbConstraints_Code_Examples.md` section "Quick Start: Using Constraints"

3. **For Implementation Details**: Use `HerbConstraints_File_Index.md` to find specific code

4. **For Architecture Understanding**: See section 8 and 9 of `HerbConstraints_Detailed_Analysis.md`

## Key Takeaways for CEGIS Integration

If you want to add HerbConstraints to CEGIS:

1. Create iterators that use `Solver` (GenericSolver or UniformSolver)
2. Call `notify_new_nodes()` when tree structure changes
3. Check `isfeasible()` before continuing search
4. Constraints are automatically enforced from the grammar

**No iterator-specific constraint code needed** - the solver handles everything!

## Additional Resources

- HerbConstraints Repository: `/Users/howie/.julia/dev/HerbConstraints/`
- HerbSearch Repository: `/Users/howie/.julia/dev/HerbSearch/`
- HerbGrammar Repository: `/Users/howie/.julia/dev/HerbGrammar/`

---

Generated: June 11, 2026
Analysis Depth: Comprehensive (all 7 key questions answered with detailed evidence)
