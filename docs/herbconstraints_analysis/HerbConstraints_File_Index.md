# HerbConstraints - Complete File Index

## Key Files by Category

### HerbConstraints Core Files

#### Module and Abstract Types
- `/Users/howie/.julia/dev/HerbConstraints/src/HerbConstraints.jl` - Main module (168 lines)
  - AbstractGrammarConstraint (lines 11-18)
  - AbstractLocalConstraint (lines 20-33)
  - get_priority function (lines 36-44)

#### Solver Architecture
- `/Users/howie/.julia/dev/HerbConstraints/src/solver/solver.jl` - Abstract Solver interface (75 lines)
  - Abstract Solver type
  - fix_point!() mechanism
  - schedule!() for constraint scheduling
  - shouldschedule() for filtering

- `/Users/howie/.julia/dev/HerbConstraints/src/solver/generic_solver/generic_solver.jl` - GenericSolver implementation (334 lines)
  - GenericSolver struct definition (lines 16-24)
  - post!() function (lines 105-115)
  - new_state!() function (lines 123-139)
  - notify_new_nodes() (lines 329-333)
  - notify_tree_manipulation() (lines 296-306)

- `/Users/howie/.julia/dev/HerbConstraints/src/solver/uniform_solver/uniform_solver.jl` - UniformSolver implementation (234 lines)
  - UniformSolver struct (lines 4-16)
  - UniformSolver constructor (lines 22-41)
  - notify_new_nodes() for uniform trees (lines 48-61)
  - deactivate!() (lines 131-147)

#### Grammar Constraints (User-Facing)
- `/Users/howie/.julia/dev/HerbConstraints/src/grammarconstraints/forbidden.jl` (136 lines)
- `/Users/howie/.julia/dev/HerbConstraints/src/grammarconstraints/ordered.jl`
- `/Users/howie/.julia/dev/HerbConstraints/src/grammarconstraints/contains.jl`
- `/Users/howie/.julia/dev/HerbConstraints/src/grammarconstraints/contains_subtree.jl`
- `/Users/howie/.julia/dev/HerbConstraints/src/grammarconstraints/forbidden_sequence.jl`
- `/Users/howie/.julia/dev/HerbConstraints/src/grammarconstraints/unique.jl`

#### Local Constraints (Runtime Enforcement)
- `/Users/howie/.julia/dev/HerbConstraints/src/localconstraints/local_forbidden.jl` (50 lines)
  - LocalForbidden struct
  - propagate!() implementation (lines 21-49)

- `/Users/howie/.julia/dev/HerbConstraints/src/localconstraints/local_ordered.jl`
- `/Users/howie/.julia/dev/HerbConstraints/src/localconstraints/local_contains.jl`
- `/Users/howie/.julia/dev/HerbConstraints/src/localconstraints/local_contains_subtree.jl`
- `/Users/howie/.julia/dev/HerbConstraints/src/localconstraints/local_forbidden_sequence.jl`
- `/Users/howie/.julia/dev/HerbConstraints/src/localconstraints/local_unique.jl`

#### Tree Manipulations
- `/Users/howie/.julia/dev/HerbConstraints/src/solver/generic_solver/treemanipulations.jl`
  - remove!() - Remove rule from domain
  - remove_all_but!() - Keep single rule
  - substitute!() - Replace node
  - remove_below!() - Remove from subtree
  - remove_above!() - Remove from ancestors

#### Pattern Matching
- `/Users/howie/.julia/dev/HerbConstraints/src/patternmatch.jl`
  - pattern_match() - Core matching algorithm
  - PatternMatchResult types

#### ASP Solver
- `/Users/howie/.julia/dev/HerbConstraints/src/solver/asp.jl` - ASP solver interface (54 lines)
  - ASPSolver struct
  - ASP constraint transformation

- `/Users/howie/.julia/dev/HerbConstraints/ext/ASPExt/` - ASP extension (requires Clingo)
  - ASPExt.jl
  - asp_constraint_transformations.jl
  - asp_tree_transformations.jl
  - asp_uniform_tree_solver.jl

---

### HerbSearch Iterator Files

#### Program Iterator Base
- `/Users/howie/.julia/dev/HerbSearch/src/program_iterator.jl` (324 lines)
  - Abstract ProgramIterator type (lines 1-12)
  - get_solver() function (lines 19-21)
  - @programiterator macro (lines 150-160)

#### Top-Down Iterators
- `/Users/howie/.julia/dev/HerbSearch/src/top_down_iterator.jl` (435 lines)
  - Abstract TopDownIterator type (lines 1-11)
  - ConstraintStyle abstract type (lines 14-28)
  - constraint_style() function (lines 31-35)
  - BFSIterator definition (line 125)
  - DFSIterator definition (line 155)
  - BFSASPIterator definition (line 137)
  - DFSASPIterator definition (line 185)
  - _make_uniform_iterator() for HerbStyle (lines 387-390)
  - _make_uniform_iterator() for ASPStyle (lines 392-395)
  - Base.iterate() implementation (lines 262-434)

#### Uniform Iterator (Fixed-Shaped Trees)
- `/Users/howie/.julia/dev/HerbSearch/src/uniform_iterator.jl` (175 lines)
  - UniformIterator struct (lines 18-24)
  - UniformIterator constructor (lines 33-42)
  - generate_branches() (lines 75-89)
  - next_solution!() (lines 98-146)

#### Uniform ASP Iterator
- `/Users/howie/.julia/dev/HerbSearch/src/uniform_asp_iterator.jl` (201 lines)
  - UniformASPIterator struct (lines 16-22)
  - UniformASPIterator constructor (lines 29-37)
  - next_solution!() (lines 95-106)

#### Bottom-Up Iterators
- `/Users/howie/.julia/dev/HerbSearch/src/bottom_up_iterator.jl` (850 lines)
  - Abstract BottomUpIterator type (lines 4-36)
  - MeasureHashedBank struct (lines 80-96)
  - AccessAddress struct (lines 183-190)
  - CombineAddress struct (lines 220-244)
  - populate_bank!() (lines 377-412)
  - combine() (lines 523-606)
  - compute_new_horizon() (lines 445-509)
  - add_to_bank!() (lines 618-661)

- `/Users/howie/.julia/dev/HerbSearch/src/bottom_up_iterators/shapebased_bus.jl`
  - SizeBasedBottomUpIterator
  - DepthBasedBottomUpIterator

- `/Users/howie/.julia/dev/HerbSearch/src/bottom_up_iterators/costbased_bus.jl`
  - CostBasedBottomUpIterator

#### Random Search Iterator
- `/Users/howie/.julia/dev/HerbSearch/src/random_iterator.jl` (72 lines)
  - rand_with_constraints!() (lines 1-6)
  - _rand_with_constraints!() helpers (lines 8-52)
  - RandomSearchIterator definition (lines 55-58)
  - Base.iterate() with constraint support (lines 63-72)

#### Search Procedure
- `/Users/howie/.julia/dev/HerbSearch/src/search_procedure.jl` (70 lines)
  - synth() function for synthesis
  - SynthResult enum

---

### Grammar Storage (HerbGrammar)

#### Context-Sensitive Grammar
- `/Users/howie/.julia/dev/HerbGrammar/src/csg/csg.jl` (304 lines)
  - ContextSensitiveGrammar struct (lines 26-37)
  - constraints field (line 36)
  - addconstraint!() function (lines 173-198)
  - clearconstraints!() function (line 198)
  - expr2csgrammar() (lines 72-82)
  - @csgrammar macro (lines 118-120)

#### Grammar I/O
- `/Users/howie/.julia/dev/HerbGrammar/src/grammar_io.jl`
  - store_csg() - Save grammar with constraints
  - read_csg() - Load grammar with constraints
  - read_pcsg() - Load probabilistic grammar with constraints

#### Grammar Base
- `/Users/howie/.julia/dev/HerbGrammar/src/grammar_base.jl`
  - add_rule!() - Updates constraints on rule addition (lines 146-186)

---

### Test Files

#### Constraint Tests (HerbSearch)
- `/Users/howie/.julia/dev/HerbSearch/test/test_constraints.jl` (123 lines)
  - All constraint types tested with BFSIterator
  - test_constraint!() and test_constraints!() usage

- `/Users/howie/.julia/dev/HerbSearch/test/test_forbidden.jl`
  - Forbidden constraint tests

- `/Users/howie/.julia/dev/HerbSearch/test/test_ordered.jl`
  - Ordered constraint tests

- `/Users/howie/.julia/dev/HerbSearch/test/test_contains.jl`
  - Contains constraint tests

- `/Users/howie/.julia/dev/HerbSearch/test/test_contains_subtree.jl`
  - ContainsSubtree constraint tests

- `/Users/howie/.julia/dev/HerbSearch/test/test_unique.jl`
  - Unique constraint tests

- `/Users/howie/.julia/dev/HerbSearch/test/test_forbidden_sequence.jl`
  - ForbiddenSequence constraint tests

#### Iterator Tests
- `/Users/howie/.julia/dev/HerbSearch/test/test_uniform_iterator.jl`
  - UniformIterator with constraints (lines 31-130)

- `/Users/howie/.julia/dev/HerbSearch/test/test_uniform_asp_iterator.jl`
  - UniformASPIterator with constraints

- `/Users/howie/.julia/dev/HerbSearch/test/test_bottom_up.jl` (296 lines)
  - Bottom-up iterators with constraints (lines 137-151)

- `/Users/howie/.julia/dev/HerbSearch/test/test_context_free_iterators.jl`
  - BFS, DFS, and other top-down iterators

#### Stochastic/Advanced
- `/Users/howie/.julia/dev/HerbSearch/test/test_stochastic/test_stochastic_with_constraints.jl`
  - Stochastic iterators with constraints

- `/Users/howie/.julia/dev/HerbSearch/test/test_sampling.jl` (lines 69-90)
  - Sampling with constraints

- `/Users/howie/.julia/dev/HerbSearch/test/test_realistic_searches.jl`
  - Real-world constraint examples

#### Test Helpers
- `/Users/howie/.julia/dev/HerbSearch/test/test_helpers.jl`
  - test_constraint!() helper function
  - test_constraints!() helper function
  - Used throughout all constraint tests

#### HerbConstraints Tests
- `/Users/howie/.julia/dev/HerbConstraints/test/check_constraints_test.jl`
  - check_tree() function tests

- `/Users/howie/.julia/dev/HerbConstraints/test/grammarconstraints_test.jl`
  - Grammar constraint tests

- `/Users/howie/.julia/dev/HerbConstraints/test/pattern_match_test.jl`
  - Pattern matching tests

- `/Users/howie/.julia/dev/HerbConstraints/test/solver/` directory
  - Various solver tests

---

## File Location Summary

```
/Users/howie/.julia/dev/
├── HerbConstraints/
│   ├── src/
│   │   ├── HerbConstraints.jl                          [Module root]
│   │   ├── solver/
│   │   │   ├── solver.jl                              [Abstract interface]
│   │   │   ├── generic_solver/
│   │   │   │   ├── generic_solver.jl                 [Main solver]
│   │   │   │   └── treemanipulations.jl              [Tree ops]
│   │   │   ├── uniform_solver/
│   │   │   │   ├── uniform_solver.jl                 [Backtracking solver]
│   │   │   │   └── ...
│   │   │   └── asp.jl                                [ASP solver]
│   │   ├── grammarconstraints/
│   │   │   ├── forbidden.jl
│   │   │   ├── ordered.jl
│   │   │   ├── contains.jl
│   │   │   ├── contains_subtree.jl
│   │   │   ├── forbidden_sequence.jl
│   │   │   └── unique.jl
│   │   ├── localconstraints/
│   │   │   ├── local_forbidden.jl
│   │   │   ├── local_ordered.jl
│   │   │   ├── local_contains.jl
│   │   │   ├── local_contains_subtree.jl
│   │   │   ├── local_forbidden_sequence.jl
│   │   │   └── local_unique.jl
│   │   ├── patternmatch.jl                            [Pattern matching]
│   │   └── ...
│   ├── ext/
│   │   └── ASPExt/                                    [ASP extension]
│   └── test/
│       ├── check_constraints_test.jl
│       ├── grammarconstraints_test.jl
│       └── ...
├── HerbSearch/
│   ├── src/
│   │   ├── program_iterator.jl                        [Base iterator]
│   │   ├── top_down_iterator.jl                       [BFS/DFS/etc]
│   │   ├── uniform_iterator.jl                        [Fixed-shape]
│   │   ├── uniform_asp_iterator.jl                    [ASP variant]
│   │   ├── bottom_up_iterator.jl                      [Bottom-up]
│   │   ├── bottom_up_iterators/
│   │   │   ├── shapebased_bus.jl
│   │   │   └── costbased_bus.jl
│   │   ├── random_iterator.jl                         [Random search]
│   │   ├── search_procedure.jl
│   │   └── ...
│   └── test/
│       ├── test_constraints.jl
│       ├── test_uniform_iterator.jl
│       ├── test_uniform_asp_iterator.jl
│       ├── test_bottom_up.jl
│       ├── test_forbidden.jl
│       ├── test_ordered.jl
│       ├── test_contains.jl
│       ├── test_unique.jl
│       ├── test_forbidden_sequence.jl
│       ├── test_sampling.jl
│       ├── test_stochastic/
│       │   └── test_stochastic_with_constraints.jl
│       ├── test_helpers.jl
│       └── ...
└── HerbGrammar/
    ├── src/
    │   ├── csg/
    │   │   └── csg.jl                                 [ContextSensitiveGrammar]
    │   ├── grammar_base.jl
    │   ├── grammar_io.jl
    │   └── ...
    └── test/
        └── ...
```

---

## Quick Navigation

### To Understand Constraint Architecture:
1. Start: `/Users/howie/.julia/dev/HerbConstraints/src/HerbConstraints.jl` (lines 11-33)
2. Solver interface: `/Users/howie/.julia/dev/HerbConstraints/src/solver/solver.jl`
3. Implementation: `/Users/howie/.julia/dev/HerbConstraints/src/solver/generic_solver/generic_solver.jl`

### To See Constraint Usage in Iterators:
1. Top-down: `/Users/howie/.julia/dev/HerbSearch/src/top_down_iterator.jl` (lines 387-395)
2. Tests: `/Users/howie/.julia/dev/HerbSearch/test/test_constraints.jl`
3. Bottom-up: `/Users/howie/.julia/dev/HerbSearch/test/test_bottom_up.jl` (lines 137-151)

### To Implement New Constraints:
1. Example: `/Users/howie/.julia/dev/HerbConstraints/src/grammarconstraints/forbidden.jl`
2. Runtime: `/Users/howie/.julia/dev/HerbConstraints/src/localconstraints/local_forbidden.jl`
3. Tests: `/Users/howie/.julia/dev/HerbSearch/test/test_constraints.jl`

### To Debug Constraint Behavior:
1. Pattern matching: `/Users/howie/.julia/dev/HerbConstraints/src/patternmatch.jl`
2. Tree manipulations: `/Users/howie/.julia/dev/HerbConstraints/src/solver/generic_solver/treemanipulations.jl`
3. Propagation: `/Users/howie/.julia/dev/HerbConstraints/src/solver/solver.jl` (lines 25-47)

