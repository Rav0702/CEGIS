# HerbConstraints - Code Examples and Quick Reference

## Quick Start: Using Constraints

### 1. Creating and Adding Constraints to a Grammar

```julia
using HerbCore, HerbGrammar, HerbConstraints, HerbSearch

# Create a grammar
grammar = @csgrammar begin
    Int = 1 | 2 | 3
    Int = x
    Int = Int + Int
    Int = Int * Int
end

# Create a constraint (forbid identical children in +)
forbidden_identical_sum = Forbidden(RuleNode(3, [VarNode(:a), VarNode(:a)]))

# Add constraint to grammar
addconstraint!(grammar, forbidden_identical_sum)

# Create an iterator - constraints are automatically active!
iterator = BFSIterator(grammar, :Int, max_size=5)

# All programs from iterator satisfy the constraint
for program in iterator
    @assert check_tree(forbidden_identical_sum, program)
end
```

### 2. Multiple Constraints

```julia
# Create multiple constraints
forbidden_rule = Forbidden(RuleNode(1))  # Forbid the rule at index 1
contains_constraint = Contains(2)         # Must contain rule 2
unique_constraint = Unique(2)             # Rule 2 can appear at most once

# Add all to grammar
addconstraint!(grammar, forbidden_rule)
addconstraint!(grammar, contains_constraint)
addconstraint!(grammar, unique_constraint)

# All constraints are enforced together
iterator = BFSIterator(grammar, :Int, max_size=6)
count = 0
for program in iterator
    count += 1
    @assert check_tree(forbidden_rule, program)
    @assert check_tree(contains_constraint, program)
    @assert check_tree(unique_constraint, program)
end
println("Found $count programs satisfying all constraints")
```

### 3. Using Constraints with Different Iterator Types

```julia
# Same constraints work with ANY iterator type

grammar = @csgrammar begin
    Int = 1 | 2
    Int = Int + Int
end
addconstraint!(grammar, Forbidden(RuleNode(2, [VarNode(:a), VarNode(:a)])))

# BFS Iterator
bfs_iter = BFSIterator(grammar, :Int, max_size=5)
bfs_programs = collect(bfs_iter)

# DFS Iterator
dfs_iter = DFSIterator(grammar, :Int, max_size=5)
dfs_programs = collect(dfs_iter)

# Random Iterator
random_iter = RandomSearchIterator(grammar, :Int)
random_programs = [next_solution!(random_iter) for _ in 1:10]

# ASP-based Iterator
asp_iter = BFSASPIterator(grammar, :Int, max_size=5)
asp_programs = collect(asp_iter)

# Bottom-up Iterator
bu_iter = SizeBasedBottomUpIterator(grammar, :Int, max_size=5)
bu_programs = collect(bu_iter)

# All respect the same constraint!
all_same_result = (
    length(bfs_programs) == length(dfs_programs) &&
    all(check_tree(grammar.constraints[1], p) for p in random_programs) &&
    length(asp_programs) == length(bu_programs)
)
```

---

## Understanding Constraint Types

### 1. Forbidden - Prevent Specific Patterns

```julia
# Forbid a specific pattern
forbidden = Forbidden(RuleNode(3, [
    RuleNode(1),
    RuleNode(1)
]))

# With variable nodes (pattern matching)
forbidden = Forbidden(RuleNode(3, [
    VarNode(:a),
    VarNode(:a)  # Both must match same subtree
]))

# Single rule index shorthand
forbidden = Forbidden(VarNode(:a))  # Forbid any rule
```

### 2. Ordered - Require Ordering in Tree

```julia
# Require that left child appears before right child
ordered = Ordered(RuleNode(3, [
    VarNode(:a),
    VarNode(:b)
]), [:a, :b])  # :a must come before :b lexicographically
```

### 3. Contains - Require Rule Presence

```julia
# Program must contain rule at index 2
contains = Contains(2)

# Shorthand: creates Contains constraint
tree = RuleNode(2)
contains = ContainsSubtree(tree)  # Must contain this exact tree
```

### 4. Unique - Limit Occurrences

```julia
# Rule at index 2 can appear at most once in entire tree
unique = Unique(2)
```

### 5. ForbiddenSequence - Prevent Rule Sequences

```julia
# Forbid rule 4 followed by rule 5
forbidden_seq = ForbiddenSequence([4, 5])

# With ignore_if: forbid unless rule 3 appears in between
forbidden_seq = ForbiddenSequence([4, 5], ignore_if=[3])
```

### 6. ContainsSubtree - Require Subtree Structure

```julia
# Must contain this specific subtree structure
subtree = RuleNode(3, [
    RuleNode(1),
    RuleNode(2)
])
contains_subtree = ContainsSubtree(subtree)
```

---

## How Constraints Work Internally

### The Constraint Propagation Pipeline

```julia
# 1. User adds constraint to grammar
addconstraint!(grammar, forbidden_pattern)

# 2. Iterator creates solver with grammar
solver = GenericSolver(grammar, :Int)

# 3. When tree expands, solver notifies constraints
notify_new_nodes(solver, tree, path)

# 4. Grammar constraint converts to local constraint
on_new_node(solver, forbidden_pattern, path)
post!(solver, LocalForbidden(path, forbidden_pattern.tree))

# 5. Solver schedules constraint for propagation
schedule!(solver, local_constraint)

# 6. Fix-point iteration propagates constraints
fix_point!(solver)
  # 6a. Pop constraint from schedule
  # 6b. Call propagate!(solver, constraint)
  #     - Pattern match against tree
  #     - Remove conflicting rules: remove!(solver, path, rule_index)
  #     - Mark satisfied: deactivate!(solver, constraint)
  #     - Or mark infeasible: set_infeasible!(solver)
  # 6c. Tree manipulations trigger reschedule
  # 6d. Repeat until all scheduled constraints processed

# 7. Iterator checks feasibility
isfeasible(solver)  # Returns false if any contradiction found

# 8. Iterator backtracks from infeasible states
if !isfeasible(solver)
    load_state!(solver, saved_state)
end
```

### Key Solver Functions

```julia
# Get/create state
solver = GenericSolver(grammar, :Int)
state = save_state!(solver)
load_state!(solver, state)

# Tree manipulation (triggers constraint propagation)
remove!(solver, path, rule_index)           # Remove one rule
remove_all_but!(solver, path, rule_index)   # Keep only one rule
substitute!(solver, path, node)             # Replace with node

# Constraint query
isfeasible(solver)              # Is current state consistent?
get_tree(solver)                # Get current tree
get_node_at_location(solver, path)  # Get node at path
get_hole_at_location(solver, path)  # Get hole at path

# Constraint testing
check_tree(constraint, tree)    # Does tree satisfy constraint?
```

---

## Advanced: Implementing Custom Constraints

### Creating a New Constraint Type

```julia
using HerbCore, HerbGrammar, HerbConstraints

# 1. Define grammar constraint
struct MyConstraint <: AbstractGrammarConstraint
    rule_index::Int
end

# 2. Define local constraint
struct LocalMyConstraint <: AbstractLocalConstraint
    path::Vector{Int}
    rule_index::Int
end

# 3. Implement on_new_node (convert grammar to local)
function on_new_node(solver::Solver, c::MyConstraint, path::Vector{Int})
    post!(solver, LocalMyConstraint(path, c.rule_index))
end

# 4. Implement propagate! (enforcement logic)
function propagate!(solver::Solver, c::LocalMyConstraint)
    node = get_node_at_location(solver, c.path)
    # Your constraint logic here
    # Can call: remove!, deactivate!, set_infeasible!, etc.
end

# 5. Implement check_tree (for testing)
function check_tree(c::MyConstraint, tree::AbstractRuleNode)::Bool
    # Return true if tree satisfies constraint
    return true
end

# 6. Use it!
addconstraint!(grammar, MyConstraint(2))
```

---

## Testing Constraints

### Using Test Helpers

```julia
using HerbConstraints, HerbSearch
include("path/to/test_helpers.jl")

grammar = @csgrammar begin
    Int = 1 | 2
    Int = Int + Int
end

constraint = Forbidden(RuleNode(2, [VarNode(:a), VarNode(:a)]))

# Test single constraint
test_constraint!(grammar, constraint, max_size=6)

# Test multiple constraints
test_constraints!(grammar, [constraint], max_size=6)
```

### Manual Testing

```julia
# 1. Enumerate all programs
grammar = @csgrammar begin
    Int = 1 | 2
    Int = Int + Int
end

iter_unconstrained = BFSIterator(grammar, :Int, max_size=5)
unconstrained_programs = collect(iter_unconstrained)

# 2. Filter manually
constraint = Forbidden(RuleNode(2, [VarNode(:a), VarNode(:a)]))
valid_programs = filter(p -> check_tree(constraint, p), unconstrained_programs)

# 3. Enumerate with constraint
addconstraint!(grammar, constraint)
iter_constrained = BFSIterator(grammar, :Int, max_size=5)
constrained_programs = collect(iter_constrained)

# 4. Verify same result
@assert length(valid_programs) == length(constrained_programs)
@assert Set(valid_programs) == Set(constrained_programs)
```

---

## Constraint Styles: HerbStyle vs ASPStyle

### HerbStyle (Default - Propagation-Based)

```julia
# Uses HerbConstraints propagation system
iterator = BFSIterator(grammar, :Int)  # Default is HerbStyle

# Or explicitly:
iterator = BFSIterator(grammar, :Int)
@assert constraint_style(iterator) == HerbStyle()

# Internally uses UniformSolver for fixed-shaped trees
```

### ASPStyle (Alternative - ASP/Clingo-Based)

```julia
# Uses Answer Set Programming (requires Clingo)
iterator = BFSASPIterator(grammar, :Int)  # ASP-based
@assert constraint_style(iterator) == ASPStyle()

# Same constraints, different enforcement mechanism
# Internally uses ASPSolver for fixed-shaped trees
```

### Comparison

```julia
grammar = @csgrammar begin
    Int = 1 | 2
    Int = Int + Int
end
addconstraint!(grammar, Forbidden(RuleNode(2, [VarNode(:a), VarNode(:a)])))

# Both give same results
herb_iter = BFSIterator(grammar, :Int, max_size=5)
asp_iter = BFSASPIterator(grammar, :Int, max_size=5)

herb_programs = collect(herb_iter)
asp_programs = collect(asp_iter)

@assert Set(herb_programs) == Set(asp_programs)
```

---

## Common Patterns

### Pattern 1: Incremental Constraint Addition

```julia
grammar = @csgrammar begin
    Int = 1 | 2
    Int = Int + Int
    Int = Int * Int
end

# Start with no constraints
iter1 = BFSIterator(grammar, :Int, max_size=5)
count1 = length(iter1)
println("Without constraints: $count1 programs")

# Add first constraint
addconstraint!(grammar, Forbidden(RuleNode(2, [VarNode(:a), VarNode(:a)])))
iter2 = BFSIterator(grammar, :Int, max_size=5)
count2 = length(iter2)
println("With 1 constraint: $count2 programs (pruned $(count1 - count2))")

# Add second constraint
addconstraint!(grammar, Forbidden(RuleNode(3, [VarNode(:a), VarNode(:a)])))
iter3 = BFSIterator(grammar, :Int, max_size=5)
count3 = length(iter3)
println("With 2 constraints: $count3 programs (pruned $(count2 - count3))")
```

### Pattern 2: Testing Constraint Coverage

```julia
# Verify all enumerated programs satisfy constraints
grammar = @csgrammar begin
    Int = 1 | 2 | 3
    Int = Int + Int
    Int = Int * Int
end

constraints = [
    Forbidden(RuleNode(2, [VarNode(:a), VarNode(:a)])),
    Contains(1),
    Unique(3)
]

for c in constraints
    addconstraint!(grammar, c)
end

iterator = BFSIterator(grammar, :Int, max_size=6)

for program in iterator
    for constraint in constraints
        @assert check_tree(constraint, program) "Program $program violates $constraint"
    end
end

println("All programs satisfy all constraints!")
```

### Pattern 3: Constraint-Guided Search

```julia
# Use constraints to guide synthesis

synthesis_grammar = @csgrammar begin
    Expr = x
    Expr = 1 | 2 | 3
    Expr = Expr + Expr
    Expr = Expr * Expr
end

# Require program to contain '+' and '*'
addconstraint!(synthesis_grammar, Contains(4))  # Rule 4 is +
addconstraint!(synthesis_grammar, Contains(5))  # Rule 5 is *

# Forbid nested multiplications
addconstraint!(synthesis_grammar, Forbidden(RuleNode(5, [
    VarNode(:x),
    RuleNode(5, [VarNode(:y), VarNode(:z)])
])))

iterator = BFSIterator(synthesis_grammar, :Expr, max_size=7)

# Iterate over only programs that:
# - Contain both + and *
# - Don't have nested multiplications
for program in iterator
    println("Valid program: ", rulenode2expr(program, synthesis_grammar))
end
```

---

## File Reference for Implementation Details

To understand constraint implementation details, consult:

| What | Where |
|------|-------|
| Grammar constraint definition | `/HerbConstraints/src/grammarconstraints/[constraint_name].jl` |
| Local constraint definition | `/HerbConstraints/src/localconstraints/local_[constraint_name].jl` |
| Solver interface | `/HerbConstraints/src/solver/solver.jl` |
| GenericSolver details | `/HerbConstraints/src/solver/generic_solver/generic_solver.jl` |
| UniformSolver details | `/HerbConstraints/src/solver/uniform_solver/uniform_solver.jl` |
| Iterator integration | `/HerbSearch/src/top_down_iterator.jl` |
| Test utilities | `/HerbSearch/test/test_helpers.jl` |
| Constraint tests | `/HerbSearch/test/test_constraints.jl` |

