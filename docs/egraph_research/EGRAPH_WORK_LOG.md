# E-Graph–Derived Constraints — Work Log

**Session date:** June 11–14, 2026
**Branch:** `egraphs-implementation`
**Author:** Fable 5 (Claude Code), driven by Stanisław Howard

This document records what was built in this session to implement the paper's
research question:

> Use e-graphs to identify structural equivalences and redundancies derived
> from the formal specification, transfer those insights into HerbConstraints,
> and prune the synthesis search space at the syntactic level — reducing the
> total number of candidates enumerated.

---

## 1. Summary of what was done

1. **Diagnosed the original plan.** The pre-existing `METATHEORY_INTEGRATION_PLAN.md`
   proposed an online `EquivalenceIterator` that checks each candidate against a
   growing e-graph *during* search. Identified this as the weak version of the
   research question (per-candidate cost, after-the-fact filtering, one iterator
   at a time) and replaced it with an **offline analysis → constraint
   compilation** design.

2. **Resolved a hard dependency conflict.** Metatheory.jl (≤ 2.0.2) pins
   `DataStructures 0.18`; HerbSearch 1.0.2 requires `0.19`. They cannot share a
   Julia environment. Solution: an **isolated environment** for the e-graph
   backend, invoked as a subprocess.

3. **Built the saturation backend** (`tools/egraph_gen/`): Metatheory 2.0.2 +
   a `saturate.jl` script. Protocol: plain Julia term strings in → one e-class
   id per term out.

4. **Built the constraint-derivation module** (`src/EGraphPruning/`): pattern
   enumeration → symmetry probes → subprocess saturation → constraint
   compilation with soundness + subsumption checks and provenance strings.

5. **Wired it into CEGIS** (`src/CEGIS.jl`): exported as `CEGIS.EGraphPruning`;
   entry point `add_derived_constraints!(grammar; max_depth, theory)`.

6. **Wrote an evaluation harness** (`scripts/test_egraph_derived_constraints.jl`):
   search-space counting (with vs. without derived constraints) + a full CEGIS
   run to confirm completeness modulo equivalence.

7. **Rewrote the plan** (`METATHEORY_INTEGRATION_PLAN.md`) around the new design,
   with the soundness argument, phased roadmap, and evaluation plan filled in
   with measured numbers.

---

## 2. Files created / modified

| File | Status | Purpose |
|---|---|---|
| `tools/egraph_gen/Project.toml`, `Manifest.toml` | new | Isolated env pinning Metatheory 2.0.2 |
| `tools/egraph_gen/saturate.jl` | new | Equality-saturation backend (LIA theory); terms in → class ids out |
| `src/EGraphPruning/EGraphPruning.jl` | new | Pattern enumeration, probes, subprocess client, constraint compilation |
| `src/CEGIS.jl` | modified | `include` + export `EGraphPruning` |
| `scripts/test_egraph_derived_constraints.jl` | new | Evaluation harness (counting + CEGIS sanity run) |
| `METATHEORY_INTEGRATION_PLAN.md` | rewritten | Design, soundness, roadmap, evaluation plan |

---

## 3. How the constraints are derived (the pipeline)

The whole pipeline is **offline** — it runs once per grammar, before any search.

### Step 1 — Enumerate grammar-specific patterns
`enumerate_patterns` builds every term shape the grammar can produce up to
depth 2:
- internal nodes = the grammar's own rules (`+`, `−`, `*`, `<`, `≤`, `==`, `ifelse`);
- leaves = the grammar's constants (`0`, `1`, plus constants **mined from the
  spec text**) or **typed holes** (`VarNode(:a)` = "any `Expr` subtree",
  `VarNode(:p)` = "any `BoolExpr` subtree");
- holes are named canonically in first-occurrence order and may repeat, so
  `a − a` (same subtree twice) is distinct from `a − b`.

Grammar variables (`x0`, `x1`) are deliberately **not** used as leaves: a hole
subsumes them, and equational logic is closed under substitution, so an
equivalence proven over a free hole holds for every subtree placed there.
→ 94 patterns for the max2 grammar.

### Step 2 — Symmetry probes
Canonical naming makes `a + b` and `b + a` the *same* pattern, hiding
commutativity. So for each pair of binary rules of matching type, probe terms
`r1(q1, q2)` vs `r2(q2, q1)` are added:
- `r1 == r2` collide → rule is **commutative** → `Ordered`;
- `r1 ≠ r2` collide → **mirror rules** (`a < b ≡ b > a`) → eliminate one rule.
→ 34 probes for max2.

### Step 3 — Equality saturation (how collision is determined)
All ~162 terms go into **one** e-graph in the subprocess:
1. **Insert** every term (hash-consed; identical subterms shared). No collisions yet.
2. **Saturate** under the rewrite theory until fixpoint (bounded, `timeout=12`):
   - *match* a rule's LHS against stored e-nodes,
   - *union* the matched class with the RHS class (union-find),
   - *congruence closure* merges parents of merged subterms automatically.
   Merges **chain**: `a==a → true` and `a≤a → true` (matched with the hole
   bound to `0`) never reference each other, yet `a == a` and `0 ≤ 0` end up in
   one class.
3. **Read off** `find(g, id)` per term → one integer each. **Two patterns
   collide iff their integers are equal.** Same id is a machine-checkable proof
   of equivalence under the theory.

This answers all ~4,400 pattern pairs in a single bounded saturation instead of
pairwise rewriting (which would not even terminate with commutativity).

### Step 4 — Compile classes into constraints
Group patterns by class id (and by non-terminal type). In each class:
- the **minimal** member under `(size, #holes, string)` is the **canonical** (kept);
- every other member becomes a candidate `Forbidden(member)`.

Two filters guarantee **completeness modulo equivalence** (every pruned program
has a still-enumerable equivalent):
- **Soundness guard** — reject `Forbidden(m)` if its canonical isn't strictly
  smaller *and* `m` matches the canonical itself. This rejected `Forbidden(a<a)`:
  the only grammar-derivable representatives of `false` are `0<0`-shaped, i.e.
  instances of `a<a`; pruning them would make `false` underivable. The check is
  relative to what *this grammar* can still express.
- **Subsumption** — most-general patterns processed first; specific patterns
  already covered are skipped.

Commutative probes → `Ordered(r(a,b),[a,b])`; mirror probes → `Forbidden` of the
whole redundant rule (removes `>` and `>=` for max2).

---

## 4. Which iterator is used

- **Constraint derivation:** no Herb iterator — a small custom recursion over
  grammar patterns (not program search).
- **Synthesis & search-space counting:** plain **`BFSIterator`** (top-down).
- **Enforcement is iterator-agnostic:** constraints are attached to the grammar
  (`addconstraint!`) and enforced by `GenericSolver`'s propagation, so the same
  derived set would prune DFS / MLFS / bottom-up identically. BFS is just what
  the evaluation uses.
- **No bottom-up program construction is involved yet.** BU iterators exist in
  HerbSearch (with their own *observational* equivalence) but were not part of
  this evaluation; integrating them — and measuring the complementarity of
  syntactic vs. observational pruning — is future work.

---

## 5. Results (depth-2 patterns)

**18 constraints derived automatically for max2 — a strict superset of the 7
hand-written ones**, e.g.:

| Kind | Constraints | Provenance |
|---|---|---|
| `ordered` | `Ordered(a+b)`, `Ordered(a*b)`, `Ordered(a==b)` | commutativity |
| `rule_eliminated` | `Forbidden(a>b)`, `Forbidden(a>=b)` | mirrors of `<`, `<=` |
| `forbidden` | `a+0`, `0+a`, `a−0`, `a*1`, `1*a` | ≡ `a` |
| `forbidden` | `a−a`, `a*0`, `0*a` | ≡ `0` |
| `forbidden` | `ifelse(p,a,a)` | ≡ `a` |
| `forbidden` | `a==a`, `1<=1` | ≡ `0<=0` (kept `true`) |
| `forbidden` | `1<1` | ≡ `0<0` (kept `false`) |
| *rejected* | `Forbidden(a<a)` | unsound — would prune all of `false` |

**Search-space reduction (programs enumerated at depth ≤ 3):**

| Benchmark | Baseline | With derived constraints | Reduction |
|---|---|---|---|
| max2 | 224,516 | 17,554 | **−92.2%** |
| max3 | 819,330 | 79,911 | **−90.2%** |

**End-to-end CEGIS (depth 5):**
- **max2: success** in 4 iterations → `ifelse(x0 < x1, x1, x0)` (semantically
  correct; the `<`-form because `>` was eliminated as a redundant mirror rule).
- **max3: failure** — a *pre-existing* depth limitation (it also failed with the
  manual constraints; needs deeper nesting or a bottom-up iterator, not more
  pruning).

---

## 6. Properties for the paper

- **No false positives** — every emitted constraint carries a saturation proof;
  the constraint set is correct by construction, not by manual inspection.
- **False negatives are harmless** — bounded saturation can only *miss*
  equivalences (lost pruning), never report false ones, so completeness is
  preserved.
- **Knowledge vs. enforcement, cleanly separated** — the rewrite theory is the
  knowledge (chosen by the spec's logic); the e-graph is the inference engine
  that closes it under composition/congruence restricted to the grammar's term
  space; HerbConstraints are the cheap enforcement medium.
- **Grammar-adaptive** — patterns are generated *from* each grammar's rules and
  spec-mined constants, so the same pipeline projects the generic theory onto
  any benchmark automatically.

---

## 7. Known gaps / next steps

- **Ordered/Forbidden interaction** — equal-size canonical selection uses
  string order, which must agree with Herb's internal `Ordered` node order;
  Phase 2 should tie-break using Herb's ordering directly.
- **Depth-3 patterns** — unlock chained redundancies (`(a+b)−b ≡ a`) and the
  conditional swap-symmetry `ifelse(a<b, b, a) ≡ ifelse(b<a, a, b)` that halves
  the max-style solution space; needs term-count management.
- **Constraint caching** — serialize derived constraints keyed by a grammar
  hash to skip the ~15 s subprocess on repeat runs.
- **More theories** — Boolean (De Morgan) and bitvector, selected by spec logic.
- **Bottom-up integration** — combine with observational equivalence and
  measure complementarity.
- **Spec-mined rewrite rules** — translate universally-quantified spec axioms
  (e.g. symmetry in `symmetric_max.sl`) into theory rules: the strongest form
  of "equivalences derived from the formal specification".
