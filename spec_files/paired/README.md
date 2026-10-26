# Paired benchmark set — specification style as a controlled variable

Two directories with **matched filenames**, so a runner pairs them by basename:

| | contents |
|---|---|
| `ours/` | our specs — copied **byte-for-byte** from `spec_files/cdgp_paper/` (and, for `max4`, the SyGuS-COMP file). Almost all are a single functional-definition constraint. |
| `cdgp/` | CDGP's specification of the *same function*, in their case-split style: one constraint per region of the input space. |
| `equiv/` | one `.smt2` per pair proving the two sides admit the same function. |

Both sides of a pair carry an **identical `synth-fun` signature and grammar
block**, so a paired sweep varies specification style and nothing else. This
generalises the ad-hoc median3 / range3 / countpos3 experiment in
[`../../docs/CDGP_BENCHMARK_COMPARISON.md`](../../docs/CDGP_BENCHMARK_COMPARISON.md)
Part 4 to the whole LIA set.

Everything under `cdgp/` and `equiv/` is **generated** — edit
[`build_pairs.py`](build_pairs.py), not the files.

```bash
python spec_files/paired/build_pairs.py                # regenerate + verify
python spec_files/paired/build_pairs.py --verify-only  # just re-run the checks
```

## The pairs

| pair | ours | cdgp | regions CDGP splits on | status |
|---|---|---|---|---|
| `countpos2` | 1 | **4** | 2² sign combinations | verified |
| `countpos3` | 1 | **8** | 2³ sign combinations | verified |
| `median3` | 1 | **6** | 3! orderings | verified |
| `range3` | 1 | **6** | 3! orderings | verified |
| `isseries3` | 1 | **2** | predicate true / false | verified · sort adapted |
| `isseries4` | 1 | **2** | predicate true / false | verified · sort adapted |
| `issorted4` | 1 | **2** | predicate true / false | verified · sort adapted |
| `issorted5` | 1 | **2** | predicate true / false | verified · sort adapted |
| `countpos4` | 1 | 1 | — | verified · **no contrast** |
| `max4` | 5 | 5 | — | verified · **no contrast** |

All 10 pairs return `unsat unsat`. All 20 files parse and build a grammar
through the CEGIS pipeline; within every pair the two sides produce the same
rule count and the same start symbol.

## How a pair is verified

`equiv/<name>.smt2` asserts **pointwise mutual entailment** between the two
constraint sets over an uninterpreted `f`:

```
push;  ours  /\ not theirs ;  check-sat   -> must be unsat
push;  theirs /\ not ours  ;  check-sat   -> must be unsat
```

Both `unsat` means neither spec admits a function the other rejects — they are
the same specification. Pointwise (free constants rather than quantifiers) is
sound here because every constraint in every spec mentions the synth-fun at one
and the same argument tuple; all these problems are single-invocation.

The checks were **mutation-tested**, since a check that can only answer `unsat`
proves nothing. Corrupting one region's answer in `median3`, deleting a region
from `countpos3`, and flipping a guard in `issorted4` each produced `sat`.

## Two deliberate deviations

**1. Return sort aligned on the four predicates.** CDGP declares
`ArithmeticSeries{3,4}` and `SortedAscending{4,5}` as **Int**-valued functions
returning 1/0; our `isseries*` / `issorted*` declare them **Bool**. Those are
different synthesis problems — different start non-terminal, different SMT sort
— so a literal transcription would not be a controlled pair, and the sort, not
the style, would be doing the work.

The generated files rewrite their `(= (f …) 1)` / `(= (f …) 0)` to
`true` / `false`. This preserves their case-split **structure** (the
experimental variable) while holding return sort fixed. Their Int-valued form
is the easier problem — `ite(cond,1,0)` solves it — so ours is the stricter one
either way.

**2. `max4` takes its grammar from the SyGuS-COMP file.** Our
`phase3_benchmarks/max4_simple.sl` declares no grammar, and the paired design
needs one. `ours/max4.sl` is therefore SyGuS-COMP 2017 `max4.sl` verbatim,
whose constraints are identical to `max4_simple.sl`'s modulo `x0…x3` ↔ `x y z w`.

## The two no-contrast pairs — read before sweeping

`countpos4` and `max4` have the **same constraint count on both sides**. They
are not style experiments; they are controls, and a "result" read off them is
noise.

- **`countpos4`** — CDGP did not case-split this one. `CountPositive4.sl` uses a
  `define-fun isPos` preamble and a single constraint (2⁴ = 16 regions was
  presumably too many to write out). The preamble additionally forces the
  subprocess Z3 path, because the in-process `ConstraintSatSolver` / `CexSolver`
  reject preamble helpers at construction.
- **`max4`** — CDGP's `fg_max4.sl` *is* SyGuS-COMP's `max4.sl` with the grammar
  block deleted. Both sides carry the same five declarative constraints. This
  makes it a useful **noise floor**: a smoke run confirmed both arms produce
  identical generations, tests, Z3 calls, program size and program text on a
  shared seed, so any divergence in a real sweep is variance, not signal.

## Excluded

| problem | why |
|---|---|
| `sum2`, `sum3`, `sum4` | No CDGP counterpart. Their `fg_array_sum_{2,3,4}_15` is a *thresholded* sum (`0` unless the total exceeds 15), which is our `fnd_sum`, not plain Sum. |
| `fg_array_search_{2,3,4}` | We have no counterpart in `cdgp_paper/`; both sides would have to be authored, so neither side would be "unchanged". |
| `fg_array_sum_{2,3,4}_15` | Our analogue `phase3_benchmarks/fnd_sum_simple.sl` is already case-split (3 implications), so the pair would have no style contrast — and it is a different threshold (5 vs 15) and arity. |
| `resources/LIA/other/*.sl` | CDGP's grammar-carrying variants of these same problems. Their grammar blocks contain `(=> StartBool StartBool)`, and `SYGUS_OP_MAP` in `src/GrammarBuilding/SygusGrammar.jl` has no `=>` entry, so `build_grammar_from_sygus` errors on them. We use our own grammar blocks instead, which avoids this — but the gap is worth closing. |

## Running a paired sweep

[`run_paired.jl`](run_paired.jl) is the scratchpad `style_arms.jl` pointed at
these directories, with two changes: the arms read `ours/<problem>.sl` and
`cdgp/<problem>.sl`, and the GP knobs scale with arity (the set spans 2–5
arguments, where the old runner hard-coded arity 3).

```bash
julia --project=. spec_files/paired/run_paired.jl --problem median3
julia --project=. spec_files/paired/run_paired.jl --problem issorted4 \
      --seeds 1:10 --time 60 --configs tests+tour,hybrid+lex-nowit
```

Options: `--problem`, `--seeds 1:10` (or `1,3,7`), `--time` (seconds per run),
`--arms ours,cdgp-split`, `--configs tests+tour,hybrid+lex-nowit`.

Every claimed success is re-verified with an independent out-of-process Z3
query; only `:unsat` counts as solved. Predicate pairs are converted in `:bool`
context, so the Bool-sorted specs re-verify correctly.

To sweep everything, loop over the basenames of `ours/` — skipping `countpos4`
and `max4` unless you want the controls.
