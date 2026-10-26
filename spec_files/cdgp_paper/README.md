# CDGP paper LIA benchmark suite

Specs for the LIA benchmark family used by Błądek, Krawiec & Swan,
*Counterexample-Driven Genetic Programming* (Evolutionary Computation 26(3),
2018; GECCO 2017; IJCAI 2018), so our results can be placed next to theirs.

They were run with `scripts/compare_with_cdgp_paper.jl` (now in the git-ignored `scripts/attic/`),
which reports **success rate over independent seeds** and re-verifies every
success with an out-of-process Z3 query.

## Coverage

| Paper problem | Arity | Semantics | Spec |
|---|---|---|---|
| CountPos | 2, 3, 4 | number of positive arguments | `countpos{2,3,4}.sl` |
| IsSeries | 3, 4 | do arguments form an arithmetic series? | `isseries{3,4}.sl` |
| IsSorted | 4, 5 | are arguments in ascending order? | `issorted{4,5}.sl` |
| Max | 4 | maximum of arguments | *official* `max4.sl` ¹ |
| Median | 3 | median of arguments | `median3.sl` |
| Range | 3 | range (max − min) of arguments | `range3.sl` |
| Search | 2, 3, 4 | index of an argument among the others | *official* `array_search_{2,3,4}.sl` ¹ |
| Sum | 2, 3, 4 | sum of arguments | `sum{2,3,4}.sl` |

¹ Already present in the SyGuS-COMP set at
`../../../benchmarks/comp/2017/General_Track/`. Prefer those originals over
re-authoring — they are the files the literature actually used.

Note `array_sum_N_M.sl` in that directory is **not** the paper's `Sum`: it is a
*thresholded* sum (`= 0` unless the total exceeds a constant). That is our
`fnd_sum` benchmark. Plain `Sum` is written here.

## Grammar

Every spec declares the grammar in the official SyGuS-COMP style used by
`max4.sl`:

```
Start     ::= <vars> | 0 | 1 | Start + Start | Start - Start | ite(StartBool, Start, Start)
StartBool ::= and | or | not | Start <= Start | Start = Start | Start >= Start
```

For the **predicate** problems (`IsSeries`, `IsSorted`, return sort `Bool`) the
Bool non-terminal is declared first, so it is the start symbol.
`build_grammar_from_sygus` maps non-terminals by *sort*, not position, and
`sygus_start_symbol(spec)` returns `:BoolExpr` for these — the search and the
SMT conversion both need it, since converting a predicate body in `:int`
context would wrap it in a Bool→Int coercion and emit an ill-sorted query.

**Expressibility was checked by construction** — every problem has a solution
inside this grammar:

| Problem | A solution in the grammar |
|---|---|
| CountPos | `ite(x >= 1, 1, 0) + …` (integers: `x > 0` ⇔ `x >= 1`) |
| IsSeries | `(y - x) = (z - y)`, conjoined for arity 4 |
| IsSorted | `and(x <= y, and(y <= z, z <= w))` |
| Median | nested `ite` over `<=` |
| Range | `max(…) - min(…)`, each a nested `ite` |
| Sum | `x + y + …` |

Note the grammar has **no `<` or `>`**, so strict comparisons must be
reformulated (`x > 0` as `x >= 1`, `x < y` as `not (y <= x)` or `(x <= y) and
not (x = y)`). Constraints are unrestricted SMT-LIB and *do* use `>`, so the
synthesis task is genuinely to re-express the specification in a poorer
operator set — not to copy it.

## Specification style

Each spec is a single functional-definition constraint,
`(= (f args) <definition>)`. This pins the semantics exactly to the paper's
description and leaves no ambiguity about what counts as correct. It differs
from the property-style specs of `max4.sl` (which constrains bounds and
membership rather than giving a formula) — worth remembering when comparing
difficulty, since a functional definition gives the counterexample generator a
single equation to falsify rather than several independent properties.
