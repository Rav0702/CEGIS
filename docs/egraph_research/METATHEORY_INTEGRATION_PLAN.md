# E-Graph–Derived Constraints: Plan & Design

**Research question.** *We propose using e-graphs to identify structural
equivalences and redundancies derived from the formal specification. This
research focuses on transferring these structural insights into
HerbConstraints, allowing the solver to prune the search space at the syntactic
level. We aim to reduce the total number of candidates that need to be
enumerated.*

**Status:** Phase 1 (MVP) implemented — `src/EGraphPruning/`,
`tools/egraph_gen/`, `scripts/test_egraph_derived_constraints.jl`.

---

## 1. Core Idea

The pipeline is **offline analysis → constraint compilation → constrained
enumeration**:

```
Specification (.sl)
      │  (logic detection: LIA → grammar + rewrite theory)
      ▼
Grammar (HerbGrammar)
      │  1. enumerate small grammar *patterns* (RuleNode trees with VarNode holes)
      │  2. emit symmetry probes per binary-rule pair
      ▼
E-graph equality saturation (Metatheory.jl, isolated subprocess)
      │  3. e-class ids: same id ⟺ proven equivalent under the theory
      ▼
Constraint compilation (EGraphPruning)
      │  4. per e-class: keep minimal canonical member, compile the rest into
      │     Forbidden patterns; commutativity → Ordered; mirrored rules
      │     (a < b ≡ b > a) → eliminate one rule wholesale
      ▼
Grammar + derived HerbConstraints
      │  5. any constraint-aware iterator (BFS/DFS/BU via GenericSolver)
      ▼
CEGIS loop — fewer candidates enumerated, fewer oracle/SMT calls
```

### Why compile into constraints instead of filtering candidates online?

An earlier draft of this plan proposed an `EquivalenceIterator` that checks
each enumerated candidate against an e-graph. That approach is strictly weaker:

| | Online e-graph filter | Compiled HerbConstraints |
|---|---|---|
| When pruning happens | after a candidate is fully built | during enumeration, inside the solver's propagation |
| Pruning granularity | one candidate at a time | a forbidden *subpattern* removes **every** program containing it (multiplicative) |
| Per-candidate cost during search | e-graph insertion + saturation | none (constraints are propagated incrementally) |
| Iterator support | needs a wrapper per iterator | automatic for every iterator using `GenericSolver` |
| Memory | e-graph grows with search | constant (fixed constraint set) |

The e-graph is used where it is strong — *discovering* equivalences offline,
including derived ones that require chaining several rewrite rules — and
HerbConstraints are used where they are strong — *enforcing* syntactic
restrictions cheaply during search. This also automates and supersedes the 7
hand-written constraints from `scripts/test_bfs_with_constraints.jl`: the MVP
re-derives all 7 automatically and finds ~11 more (see §5).

### Relation to the specification

"Derived from the formal specification" enters in three escalating stages:

1. **Now (Phase 1):** the spec determines the grammar (operators, variables,
   constants mined from constraints) and the logic (`(set-logic LIA)` selects
   the LIA rewrite theory). The equivalences are therefore relative to the
   spec's term language.
2. **Phase 2:** spec-specific *ground* facts — constants appearing in the spec
   generate extra ground terms/probes (e.g. if `2` is in the grammar, `a + a ≡
   2 * a` becomes exploitable; already active in the MVP).
3. **Phase 3 (research):** mine rewrite rules from the spec's axioms
   themselves, e.g. `symmetric_max.sl` declares symmetry of the target
   function — such universally-quantified constraints translate directly into
   rewrite rules / argument-symmetry constraints.

---

## 2. Architecture

### Two Julia environments (forced, but architecturally clean)

Metatheory.jl (≤ 2.0.2, incl. master) pins `DataStructures 0.18`; HerbSearch
1.0.2 requires `DataStructures 0.19`. They **cannot coexist** in one
environment. Consequently:

- `tools/egraph_gen/` — isolated environment containing only Metatheory.jl and
  `saturate.jl`, the saturation backend. Protocol: a file of plain Julia term
  strings in, one e-class id per term out.
- `src/EGraphPruning/EGraphPruning.jl` — main-environment module (depends only
  on HerbCore/HerbGrammar/HerbConstraints). Enumerates patterns, invokes the
  backend as a subprocess, compiles constraints.

The subprocess costs ~10–20 s of Julia startup per derivation. Since derivation
is offline and per-grammar (not per-candidate), this is acceptable; Phase 2
adds artifact caching so repeated runs on the same grammar are free.

### Pipeline components

**1. Pattern enumeration** (`enumerate_patterns`). Enumerates `RuleNode` trees
up to `max_depth` (default 2) over the grammar where leaves are either
*constant terminals* (0, 1, …) or *typed holes* (`VarNode`). Holes are named
canonically in first-occurrence order with restricted growth (reuse an existing
hole or introduce one fresh), so each pattern is unique up to renaming.
Repeated holes capture nonlinear patterns (`a - a`). Grammar variables (x0, x1)
are *not* used as leaves — a hole subsumes them, and an equivalence proven over
free symbols holds for every substitution instance (equational logic is closed
under substitution). This is what licenses generalizing e-class facts into
`VarNode` patterns.

**2. Symmetry probes** (`symmetry_probes`). Hole-canonical naming makes
`a + b` and `b + a` the *same* pattern, so commutativity is invisible among
enumerated patterns. Dedicated probe pairs `r1(q1,q2)` vs `r2(q2,q1)` (and
`r2(q1,q2)`) for every binary rule pair detect:
- `r1 == r2` in one class → **commutative rule** → `Ordered(r(a,b), [a,b])`;
- `r1 ≠ r2` in one class → **mirrored/duplicate rule** (`a < b ≡ b > a`) →
  eliminate the redundant rule wholesale with `Forbidden(r2(a, b))`.
  For the LIA comparison set this removes `>` and `>=` entirely.

**3. Equality saturation** (`tools/egraph_gen/saturate.jl`). All pattern and
probe terms go into one e-graph; bounded saturation under the theory; the
backend prints `find(g, id)` per term. The theory currently covers: identity
and absorbing elements, commutativity/associativity, `a + a ≡ 2a`, comparison
mirror symmetries, reflexive-comparison collapse to `true`/`false`, and
`ifelse` collapse rules.

**4. Constraint compilation** (`derive_constraints`). Group patterns by
e-class and nonterminal type. In each group the canonical member is the minimum
under `(size, #holes, string)`; every other member is a candidate
`Forbidden(member)`. Candidates are processed most-general-first so general
patterns subsume specific ones.

### Soundness rules (completeness modulo equivalence)

A constraint set is admissible iff every pruned program has a semantically
equivalent program that remains enumerable. Enforced by:

1. **Same-type replacement.** A member is only forbidden against a canonical of
   the same nonterminal, so substituting canonical for member always yields a
   grammar-valid tree.
2. **Well-founded replacement.** If `|canonical| < |member|`, replacing matches
   strictly shrinks the tree, so rewriting terminates at an unpruned program.
3. **Equal-size guard.** If sizes are equal, `Forbidden(m)` is accepted only if
   `m` does *not* match the canonical itself (conservatively, holes count as
   "could match"). This rejects e.g. `Forbidden(a < a)`: every grammar-derivable
   representative of `false` (`0 < 0`, `1 < 1`, …) is an instance of `a < a`,
   so the constraint would prune the entire e-class.
4. **Saturation incompleteness is safe.** Bounded saturation can only *miss*
   equivalences (missed pruning), never report false ones.

Known gap (accepted for MVP, see §6): pairwise interaction between `Ordered`
and equal-size `Forbidden` constraints relies on the canonical order
(`string`-based) agreeing with Herb's internal `Ordered` node order. Phase 2
should make the compilation use Herb's ordering directly.

---

## 3. Implementation Phases

### Phase 1 — MVP (done)
- [x] `tools/egraph_gen/` isolated Metatheory 2.0.2 environment + `saturate.jl`
      backend (LIA theory).
- [x] `EGraphPruning` module: pattern enumeration (depth 2), pattern→Expr
      conversion, subprocess client, probes, constraint compilation with
      soundness + subsumption checks, provenance descriptions.
- [x] Wired into `CEGIS` (exported as `CEGIS.EGraphPruning`); entry point
      `add_derived_constraints!(grammar; max_depth, theory)`.
- [x] `scripts/test_egraph_derived_constraints.jl`: search-space counting with
      vs. without derived constraints + end-to-end CEGIS sanity run.

### Phase 2 — Depth, caching, robustness
- [ ] **Depth-3 patterns** (selective): unlocks `(a + b) - b ≡ a` and the
      conditional symmetry `ifelse(a < b, x, y) ≡ ifelse(b > a, x, y)`,
      including the max-pattern symmetry `ifelse(a < b, b, a) ≡ ifelse(b < a,
      a, b)` which halves the solution space for max-style benchmarks. Needs
      term-count management (restrict root/child rule combinations or sample).
- [ ] **Constraint artifact**: serialize derived constraints to a generated
      `.jl` file keyed by a grammar hash; skip the subprocess when cached.
      The artifact doubles as a human-readable appendix for the paper.
- [ ] **Ordering alignment**: tie-break canonical selection using Herb's
      `Ordered` node order to close the interaction gap in §2.
- [ ] **Theories**: add Boolean (`&&`/`||`/`!` with De Morgan) and BV theories,
      selected via spec logic, mirroring `GrammarConfig`'s operation sets.
- [ ] **Tests**: unit tests for pattern enumeration, the soundness guard
      (`a < a` rejection), and an exhaustive check that with constraints every
      pruned program at depth ≤ 3 has an enumerable equivalent (validates
      completeness-modulo-equivalence empirically).

### Phase 3 — Research extensions
- [ ] **Spec-mined rewrite rules**: translate universally-quantified spec
      axioms (e.g. symmetry in `symmetric_max.sl`) into additional rewrite
      rules / argument-symmetry constraints — the strongest version of
      "equivalences derived from the formal specification".
- [ ] **Bottom-up integration**: combine with `CostBasedBottomUpIterator`'s
      observational equivalence; measure whether syntactic (e-graph) and
      observational pruning are complementary (they should be: observational
      equivalence catches input-specific collisions, e-graph constraints catch
      universal ones *before* execution).
- [ ] **Cost-aware canonicals**: pick canonical representatives by the
      iterator's cost model instead of size, so pruning biases search toward
      cheap programs.

---

## 4. Evaluation Plan (for the paper)

**Metrics** (per benchmark): (a) number of candidates enumerated up to a fixed
depth (the direct measure of the research claim), (b) wall-clock synthesis
time, (c) number of oracle/SMT queries, (d) CEGIS iterations, (e) solution
found & semantically correct.

**Configurations**:
1. Baseline — no grammar constraints.
2. Manual — the 7 hand-written constraints (`test_bfs_with_constraints.jl`).
3. **Derived** — e-graph pipeline (this work), depth-2 patterns.
4. Derived + depth-3 (Phase 2).

**Benchmarks**: `spec_files/phase3_benchmarks/` (max2, max3, arith, guard,
fnd_sum, symmetric_max), plus the larger `benchmarks/` suites.

**Hypotheses**:
- H1: derived ⊇ manual (automation recovers the hand-written set). *Confirmed
  in MVP: all 7 recovered, 18 total derived.*
- H2: derived constraints reduce enumerated candidates substantially at equal
  depth (target: >80% as observed with the manual set). *Confirmed in MVP
  (depth ≤ 3 enumeration): max2 224,516 → 17,554 (−92.2%); max3 819,330 →
  79,911 (−90.2%).*
- H3: synthesis still succeeds (completeness preserved) and end-to-end time
  improves despite constraint-propagation overhead. *Partially confirmed:
  max2 synthesizes successfully (4 CEGIS iterations, semantically correct
  solution `ifelse(x0 < x1, x1, x0)` — note the `<`-form, since `>` was
  eliminated as a mirror rule). max3 still fails at depth 5 — a known
  pre-existing limitation (it also failed with manual constraints; it needs
  deeper nesting or a bottom-up iterator, not more pruning).*

**Threats / limitations to report**: derivation cost (one-off, ~10–20 s);
propagation overhead per node; depth-2 patterns miss deeper redundancies;
theory completeness; the `Ordered`-interaction gap (§2) until Phase 2 closes it.

---

## 5. MVP Result Snapshot (max2 grammar, depth-2 patterns)

18 constraints derived automatically (vs. 7 hand-written), e.g.:

| Kind | Constraint | Provenance (canonical kept) |
|---|---|---|
| ordered | `Ordered(a + b)`, `Ordered(a * b)`, `Ordered(a == b)` | commutativity |
| rule_eliminated | `Forbidden(a > b)`, `Forbidden(a >= b)` | mirrors of `<`, `<=` |
| forbidden | `a + 0`, `0 + a`, `a - 0`, `a * 1`, `1 * a` | ≡ `a` |
| forbidden | `a - a`, `a * 0`, `0 * a` | ≡ `0` |
| forbidden | `ifelse(p, a, a)` | ≡ `a` |
| forbidden | `a == a`, `1 <= 1` | ≡ `0 <= 0` (the kept `true`) |
| forbidden | `1 < 1` | ≡ `0 < 0` (the kept `false`) |
| *rejected* | `Forbidden(a < a)` | unsound — would prune all of `false` |

---

## 6. Known Risks

- **Ordered/Forbidden interaction** (§2): mitigated by canonical-order
  alignment in Phase 2; empirically validated meanwhile by the end-to-end
  synthesis sanity check in the test script.
- **Pattern explosion at depth ≥ 3**: combinatorial in rules × leaf choices;
  manage by restricting which rules may nest, or by sampling + verifying.
- **Reserved symbols**: hole/probe names (`a b c d p q r q1 q2`) must not
  collide with grammar variables; `check_symbol_collisions` errors loudly.
- **Subprocess fragility**: backend errors surface as parse failures of its
  stdout; acceptable for research code, wrap with clearer diagnostics later.
