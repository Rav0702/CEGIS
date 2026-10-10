# HerbConstraints Architecture and Iterator Integration Analysis

## Summary of Findings

HerbConstraints is a **solver-based** constraint system that is designed to be **iterator-agnostic**. Constraints are applied through solvers, not directly through iterators, making them usable with any iterator that uses a compatible solver type.

---

## 1. What are HerbConstraints and Where are They Defined?

### Definition
HerbConstraints are domain constraints that restrict the space of programs that can be enumerated during synthesis. They are defined in `/Users/howie/.julia/dev/HerbConstraints/`.

### Key Architecture Components

**Two-Layer Constraint System:**

1. **Grammar Constraints** (`AbstractGrammarConstraint`): User-facing constraints stored in the grammar
   - Location: `/Users/howie/.julia/dev/HerbConstraints/src/grammarconstraints/`
   - Examples: `Forbidden`, `Ordered`, `Contains`, `ContainsSubtree`, `ForbiddenSequence`, `Unique`
   - Defined in `/Users/howie/.julia/dev/HerbConstraints/src/HerbConstraints.jl` (lines 11-18)

2. **Local Constraints** (`AbstractLocalConstraint`): Runtime constraints posted on solvers at specific tree locations
   - Location: `/Users/howie/.julia/dev/HerbConstraints/src/localconstraints/`
   - Examples: `LocalForbidden`, `LocalOrdered`, `LocalContains`, etc.
   - Defined in `/Users/howie/.julia/dev/HerbConstraints/src/HerbConstraints.jl` (lines 20-33)

### Constraint Storage

Constraints are stored in the **grammar** object:
- Type: `ContextSensitiveGrammar` from HerbGrammar
- Field: `constraints::Vector{AbstractConstraint}`
- Location: `/Users/howie/.julia/dev/HerbGrammar/src/csg/csg.jl` (line 36)
- Added via: `addconstraint!(grammar::ContextSensitiveGrammar, c::AbstractConstraint)` 
  - Location: `/Users/howie/.julia/dev/HerbGrammar/src/csg/csg.jl` (lines 173-198)

---

## 2. How are HerbConstraints Currently Used in Iterators?

### Constraint Flow Architecture

```
Grammar (with constraints) 
    ↓
Solver Type (GenericSolver or UniformSolver)
    ↓
Iterator (any TopDownIterator, etc.)
```

### Solver-Level Integration

**GenericSolver** (`/Users/howie/.julia/dev/HerbConstraints/src/solver/generic_solver/generic_solver.jl`):
- When a new node appears during search: `notify_new_nodes()` (lines 329-333)
- Calls `on_new_node()` for each grammar constraint (line 319)
- Grammar constraints post local constraints via `post!(solver, LocalConstraint)` (lines 105-115)
- Constraints are propagated via `fix_point!()` (lines 25-47)
- Tree manipulations trigger `notify_tree_manipulation()` (lines 296-306)

**UniformSolver** (`/Users/howie/.julia/dev/HerbConstraints/src/solver/uniform_solver/uniform_solver.jl`):
- Initializes with `notify_new_nodes()` (line 38)
- Calls `fix_point!()` (line 39)
- Similar propagation model to GenericSolver

### Propagation Mechanism

1. **Post**: New local constraint added to solver state
   - Active constraints tracked per state
   - Constraint added to propagation schedule (priority queue)

2. **Propagate**: `propagate!(solver::Solver, constraint::AbstractLocalConstraint)`
   - Each constraint type implements its own propagation logic
   - Example: `LocalForbidden.propagate!()` checks pattern matches
   - Can result in:
     - `deactivate!()`: Constraint satisfied, no more propagation
     - `set_infeasible!()`: State is infeasible
     - `remove!()`: Remove impossible rules from domains

3. **Fix Point**: Repeat propagation until fixed point reached
   - All scheduled constraints propagated
   - Tree manipulations from propagation reschedule affected constraints
   - Nested `fix_point!()` calls ignored via `fix_point_running` flag

---

## 3. Are HerbConstraints Specific to BU Iterators or Can They Be Used with Any Iterator?

### Answer: **ITERATOR-AGNOSTIC** - Constraints work with ANY iterator using compatible solvers

### Iterator Coverage

**All Top-Down Iterators use GenericSolver + Constraint propagation:**
- `BFSIterator` ✓ (HerbStyle - uses propagation)
- `DFSIterator` ✓ (HerbStyle - uses propagation)
- `RandomIterator` ✓ (uses GenericSolver)
- Other TopDownIterators ✓

**Uniform Tree Enumeration (fixed-shaped) uses UniformSolver + Constraint propagation:**
- Both `BFSIterator` and `DFSIterator` internally use `UniformIterator` with `UniformSolver`
- Constraints are active here too
- Location: `/Users/howie/.julia/dev/HerbSearch/src/top_down_iterator.jl` (lines 387-390)

```julia
function _make_uniform_iterator(::HerbStyle, solver::Solver, iter::TopDownIterator)
    uniform_solver = UniformSolver(get_grammar(solver), get_tree(solver), with_statistics=solver.statistics)
    return UniformIterator(uniform_solver, iter)
end
```

**ASP-Style Iterators (Alternative enforcement):**
- `BFSASPIterator` ✓ (ASPStyle - uses ASP solver instead)
- `DFSASPIterator` ✓ (ASPStyle - uses ASP solver instead)
- Location: `/Users/howie/.julia/dev/HerbSearch/src/top_down_iterator.jl` (lines 392-395)

```julia
function _make_uniform_iterator(::ASPStyle, solver::Solver, iter::TopDownIterator)
    uniform_solver = HerbConstraints.ASPSolver(get_grammar(solver), get_tree(solver), with_statistics=solver.statistics)
    return UniformASPIterator(uniform_solver, iter)
end
```

**Bottom-Up Iterators:**
- Bottom-up iterators (`SizeBasedBottomUpIterator`, `DepthBasedBottomUpIterator`, etc.) support constraints
- Tested in: `/Users/howie/.julia/dev/HerbSearch/test/test_bottom_up.jl` (lines 137-151)
- They use the same generic solver mechanism with constraint posting
- Example test constraint check: `@test all(check_tree(forbidden_plus_same, p) for p in progs)`

**RandomIterator:**
- Uses `GenericSolver` with constraint support
- Has `rand_with_constraints!()` helper that respects constraint feasibility
- Location: `/Users/howie/.julia/dev/HerbSearch/src/random_iterator.jl` (lines 1-51)

### Key Finding: 
**The constraint system is decoupled from iterator logic.** Constraints are enforced at the solver level through the propagation mechanism, meaning any iterator that:
1. Uses a `Solver` (GenericSolver or UniformSolver)
2. Calls `notify_new_nodes()` when tree structure changes
3. Respects `isfeasible()` checks

...will automatically respect constraints.

---

## 4. How do Constraints Filter/Prune the Search Space During Enumeration?

### Domain Reduction Mechanism

**Step 1: Pattern Matching and Deduction**

Each constraint type has a `propagate!()` function that analyzes the current tree:

Example: `LocalForbidden.propagate!()` 
- Location: `/Users/howie/.julia/dev/HerbConstraints/src/localconstraints/local_forbidden.jl`
- Line 21-49

```julia
function propagate!(solver::Solver, c::LocalForbidden)
    node = get_node_at_location(solver, c.path)
    @match pattern_match(node, c.tree) begin
        ::PatternMatchHardFail => deactivate!(solver, c)  # Already satisfied
        ::PatternMatchSoftFail => ()                       # Needs re-propagation
        ::PatternMatchSuccess => set_infeasible!(solver)   # Conflict!
        match::PatternMatchSuccessWhenHoleAssignedTo => begin
            # Deduction: Remove the conflicting rule
            path = vcat(c.path, get_path(node, match.hole))
            deactivate!(solver, c)
            remove!(solver, path, match.ind)
        end
    end
end
```

**Step 2: Domain Manipulation**

The solver performs tree manipulations that remove impossible rules:
- `remove!(solver, path, rule_index)`: Remove a single rule from a hole's domain
- `remove_all_but!(solver, path, rule)`: Keep only one rule
- `substitute!(solver, path, node)`: Replace node with specific value

Location: `/Users/howie/.julia/dev/HerbConstraints/src/solver/generic_solver/treemanipulations.jl`

**Step 3: Constraint Repropagation**

When a domain is modified:
- `notify_tree_manipulation()` is called
- All constraints that could be affected are scheduled
- Fixed point iteration ensures all consequences are drawn

Location: `/Users/howie/.julia/dev/HerbConstraints/src/solver/solver.jl` (lines 65-74)

```julia
function shouldschedule(::Solver, constraint::AbstractLocalConstraint, path::Vector{Int})::Bool
    return (length(path) >= length(constraint.path)) && (path[1:length(constraint.path)] == constraint.path)
end
```

**Step 4: Feasibility Checks**

During enumeration, iterators check `isfeasible(solver)`:
- If any domain becomes empty (non-trivial inconsistency): infeasible
- If explicit `set_infeasible!()` called: infeasible
- Iterators backtrack from infeasible states

---

## 5. What Would be Required to Add HerbConstraints to a BFS Iterator?

### Answer: **BFSIterator Already Has Full Constraint Support!**

The `BFSIterator` in `/Users/howie/.julia/dev/HerbSearch/src/top_down_iterator.jl` (line 125):
- Inherits from `AbstractBFSIterator <: TopDownIterator`
- Uses `GenericSolver` for variable-shaped trees
- Uses `UniformSolver` for fixed-shaped trees
- Both solvers have full constraint propagation

**Constraints are automatically active:**

```julia
# Adding constraints to any iterator is as simple as:
grammar = @csgrammar begin
    Int = 1
    Int = Int + Int
end

forbidden_constraint = Forbidden(RuleNode(2, [VarNode(:a), VarNode(:a)]))
addconstraint!(grammar, forbidden_constraint)

# BFSIterator automatically respects the constraint
iterator = BFSIterator(grammar, :Int, max_size=5)
for program in iterator
    @assert check_tree(forbidden_constraint, program)
end
```

**Manual implementation (if starting from scratch):**

1. Create iterator that uses `GenericSolver` or `UniformSolver`
2. Initialize solver with grammar (constraints auto-loaded)
3. Call `notify_new_nodes()` when expanding tree
4. Check `isfeasible()` before continuing search
5. Call `fix_point!()` after tree modifications

Minimal example structure:
```julia
mutable struct CustomIterator <: ProgramIterator
    solver::Solver
    # ... other fields
end

function Base.iterate(iter::CustomIterator)
    # Solver already has constraints from grammar
    state = save_state!(get_solver(iter))
    # ... search logic
    if isfeasible(get_solver(iter))
        return program, state
    end
end
```

---

## 6. Are There Any Existing Examples of Constraints Being Applied to Different Iterator Types?

### Yes - Comprehensive Testing Coverage

**1. Uniform Iterator Tests**
- File: `/Users/howie/.julia/dev/HerbSearch/test/test_uniform_iterator.jl`
- Tests: Forbidden, Ordered constraints with `UniformIterator`

**2. Uniform ASP Iterator Tests**
- File: `/Users/howie/.julia/dev/HerbSearch/test/test_uniform_asp_iterator.jl`
- Tests: Same constraints but via ASP enforcement
- Same test structure as regular UniformIterator

**3. Generic Constraint Tests**
- File: `/Users/howie/.julia/dev/HerbSearch/test/test_constraints.jl` (lines 1-123)
- Tests all constraint types with `BFSIterator`
- Multiple constraints tested together

**4. Specific Constraint Type Tests**
- `test_forbidden.jl`: Forbidden constraints
- `test_ordered.jl`: Ordered constraints  
- `test_contains.jl`: Contains constraints
- `test_contains_subtree.jl`: ContainsSubtree constraints
- `test_unique.jl`: Unique constraints
- All use `BFSIterator`

**5. Bottom-Up Iterator with Constraints**
- File: `/Users/howie/.julia/dev/HerbSearch/test/test_bottom_up.jl` (lines 137-151)
- Tests: `Forbidden` constraint with `SizeBasedBottomUpIterator`
- Code:
```julia
@testset "Constraint checking" begin
    @testset "Search respects Forbidden" begin
        g = (@csgrammar begin
            Int = 1 | 2
            Int = Int + Int
        end)
        forbidden_plus_same = Forbidden(RuleNode(3, [VarNode(:a), VarNode(:a)]))
        HerbConstraints.addconstraint!(g, forbidden_plus_same)
        iter = make_iter(g; max_depth=3, max_size=5)
        progs = [freeze_state(p) for p in iter]
        @test all(check_tree(forbidden_plus_same, p) for p in progs)
    end
end
```

**6. Stochastic Iterators with Constraints**
- File: `/Users/howie/.julia/dev/HerbSearch/test/test_stochastic/test_stochastic_with_constraints.jl`
- Tests: Multiple constraint types with stochastic search

**7. Realistic Search Examples**
- File: `/Users/howie/.julia/dev/HerbSearch/test/test_realistic_searches.jl`
- Complex grammars with multiple constraint types

**8. Sampling with Constraints**
- File: `/Users/howie/.julia/dev/HerbSearch/test/test_sampling.jl` (lines 69-90)
- Tests: `Contains` constraint with sampling

### Test Helper Functions

Comprehensive test utilities in `/Users/howie/.julia/dev/HerbSearch/test/test_helpers.jl`:

```julia
function test_constraint!(grammar::AbstractGrammar, constraint::AbstractGrammarConstraint; 
                         max_size=typemax(Int), max_depth=typemax(Int))
    # Tests if propagating the constraint during a top-down iteration yields 
    # the correct number of programs
end

function test_constraints!(grammar::AbstractGrammar, constraints::Vector{<:AbstractGrammarConstraint};
                          max_size=typemax(Int), max_depth=typemax(Int), allow_trivial=false)
    # Tests multiple constraints together
end
```

---

## 7. Key Files and Code Sections Demonstrating Constraint Architecture

### Core HerbConstraints Files

| File | Purpose | Key Lines |
|------|---------|-----------|
| `HerbConstraints.jl` | Module exports, abstract type definitions | 1-168 |
| `solver/solver.jl` | Abstract Solver interface, `fix_point!()` | 1-75 |
| `solver/generic_solver/generic_solver.jl` | GenericSolver implementation, constraint posting | 16-334 |
| `solver/uniform_solver/uniform_solver.jl` | UniformSolver (backtracking capable) | 1-234 |
| `grammarconstraints/forbidden.jl` | User-facing Forbidden constraint | 1-136 |
| `localconstraints/local_forbidden.jl` | Runtime forbidden constraint enforcement | 1-50 |

### Key HerbSearch Integration Files

| File | Purpose | Key Lines |
|------|---------|-----------|
| `program_iterator.jl` | Abstract iterator, solver field access | 1-324 |
| `top_down_iterator.jl` | BFSIterator, DFSIterator, solver creation | 1-435 |
| `uniform_iterator.jl` | Inner iterator using UniformSolver | 1-175 |
| `uniform_asp_iterator.jl` | Inner iterator using ASPSolver | 1-201 |
| `bottom_up_iterator.jl` | Bottom-up search with solver integration | 1-850 |
| `random_iterator.jl` | Random search with constraint feasibility checks | 1-72 |

### Key Grammar/Storage Files

| File | Purpose | Key Lines |
|------|---------|-----------|
| `HerbGrammar/csg/csg.jl` | ContextSensitiveGrammar with constraints field | 1-304 |
| `HerbGrammar/csg/csg.jl` | `addconstraint!()`, `clearconstraints!()` | 173-198 |

### Test Examples

| File | Coverage | Examples |
|------|----------|----------|
| `HerbSearch/test/test_constraints.jl` | All constraint types with BFSIterator | Lines 1-123 |
| `HerbSearch/test/test_bottom_up.jl` | Forbidden + bottom-up | Lines 137-151 |
| `HerbSearch/test/test_uniform_iterator.jl` | Forbidden, Ordered + UniformIterator | Lines 31-130 |
| `HerbConstraints/test/check_constraints_test.jl` | Constraint checking functions | - |

---

## 8. Constraint Architecture Summary Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    User Code                                │
│  grammar = @csgrammar begin ... end                         │
│  addconstraint!(grammar, Forbidden(...))                    │
└────────────────────┬────────────────────────────────────────┘
                     │ constraints field
                     ▼
┌─────────────────────────────────────────────────────────────┐
│        Grammar (ContextSensitiveGrammar)                    │
│  - rules, types, domains, childtypes                        │
│  - constraints: Vector{AbstractConstraint}                  │
└────────────────┬──────────────────────────────────────────┘
                 │ passed to constructor
                 ▼
┌─────────────────────────────────────────────────────────────┐
│              Iterator (e.g., BFSIterator)                   │
│  @programiterator BFSIterator() <: TopDownIterator          │
│  - solver::Solver                                           │
└──────────┬──────────────────────────────────────────────────┘
           │ creates/holds
           ▼
┌──────────────────────────────────────────────────────────────┐
│         Solver (GenericSolver or UniformSolver)              │
│  - grammar (with constraints)                               │
│  - schedule: PriorityQueue{AbstractLocalConstraint}         │
│  - fix_point_running: Bool                                  │
└───┬──────────────────────────────────────────────────────────┘
    │
    ├─ On tree expansion: notify_new_nodes(solver, tree, path)
    │                     ├─ For each grammar constraint c:
    │                     │  └─ on_new_node(solver, c, path)
    │                     │     └─ post!(solver, LocalConstraint(...))
    │
    ├─ On post(): Constraint added to schedule
    │
    ├─ Call fix_point!()
    │  ├─ Pop constraint from schedule
    │  ├─ Call propagate!(solver, constraint)
    │  │  ├─ Pattern matching to find deductions
    │  │  ├─ remove!() / remove_all_but!() / ...
    │  │  └─ deactivate!() or set_infeasible!()
    │  ├─ On tree manipulation:
    │  │  └─ notify_tree_manipulation(solver, path)
    │  │     └─ Schedule affected constraints
    │  └─ Repeat until schedule empty
    │
    └─ Iterator checks isfeasible() and backtracks if false

┌──────────────────────────────────────────────────────────────┐
│         Result: Feasible Programs Only                       │
│  All enumerated programs satisfy the constraints             │
└──────────────────────────────────────────────────────────────┘
```

---

## 9. Why Constraints are Iterator-Agnostic

### Design Principle: Separation of Concerns

1. **Constraints operate at solver level**, not iterator level
   - Solvers manage tree structure and domains
   - Iterators manage search strategy and ordering
   - Two concerns are independent

2. **Multiple solver-iterator combinations possible:**
   - GenericSolver + BFSIterator ✓
   - GenericSolver + DFSIterator ✓
   - GenericSolver + RandomIterator ✓
   - UniformSolver + UniformIterator (used by BFS/DFS for fixed shapes) ✓
   - ASPSolver + UniformASPIterator ✓
   - GenericSolver + BottomUpIterator ✓

3. **Constraint enforcement is identical across iterators:**
   - Same constraint posting mechanism
   - Same propagation algorithm
   - Same feasibility checks
   - Only search strategy differs

### Implementation Support

Every solver type implements:
- `notify_new_nodes(solver, tree, path)`: Post constraints
- `post!(solver, constraint)`: Add to schedule
- `propagate!(solver, constraint)`: Execute deductions
- `fix_point!(solver)`: Reach consistency
- `isfeasible(solver)`: Check state validity

This interface makes constraints **plug-and-play** with any iterator using compatible solvers.

---

## Conclusion

HerbConstraints represent a **clean, modular architecture** where:

1. **Constraints are iterator-agnostic** - enforced at solver level
2. **Any solver-using iterator automatically gets constraint support**
3. **Multiple constraint enforcement strategies available** (propagation vs ASP)
4. **Two-layer constraint system enables flexibility** (grammar constraints delegate to local constraints)
5. **Comprehensive test coverage** across BFS, DFS, random, and bottom-up iterators

This design allows adding HerbConstraints to new iterators by simply:
- Using a Solver (GenericSolver or UniformSolver)
- Calling `notify_new_nodes()` on tree changes
- Checking `isfeasible()` for validity

The solver handles all constraint logic automatically.
