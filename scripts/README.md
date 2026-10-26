# scripts/

This folder holds the scripts the final paper uses. The split follows the results tables `FULL_SCALE_PLAN.md` keeps
and drops (Part A, and C1 and C3–C5). They stay at the paths the experiment register cites. The register
(`spec_knowledge/EXPERIMENTS.md`) and the design documents (`docs/`) are kept outside the repository, in
`../CEGIS-docs/`, and git ignores them here.

The other 46 scripts are leftovers from exploratory work the paper no longer reports, and from early demos. They live
in the private docs repository `../CEGIS-docs/scripts/attic/`, and `attic/` here is a directory junction to it, which
this repository's git ignores. `attic/README.md` lists them. A registered command that names `scripts/<x>` for one of
them now means `scripts/attic/<x>`.

[Writing a script](#writing-a-script) explains how a new script is put together.

## Used by the final paper (31)

### Confirmatory phase: specs, checks and deterministic runs

| script | role |
|---|---|
| `gen_enriched_grammars.jl` | Writes `spec_files/enriched/<stem>_<variant>.sl`: case, guard, inert, decoy, scrambled, atoms, blocks and their placebos. Regenerating an existing file reproduces it byte for byte |
| `make_confirmatory_specs.py` | `spec_files/confirmatory/`: CDGP and early-benchmark constraints with the CDGP-paper grammar added (pool 1) |
| `gen_partial_family.py` | The generated partial-knowledge specs in `spec_files/partial_knowledge/family/` (pool 2, the `g.pk*` keys) |
| `gen_scaled_specs.py` | Scaled members of the max, above and array-search families (`spec_files/scaled/`, and `max<n>_sygus.sl` into `spec_files/grammar_variants/`, among them `f.max7`) |
| `check_inclusion.jl` | Inclusion rules 1 and 2: knowledge in the file's own grammar, and the chain depth within the cap |
| `check_partial_family.jl` | What the compiler extracts from the partial-knowledge specs, and whether each is single-answer |
| `check_replay.jl` | Replay regression: stored seeds must follow the same trajectory under the current code. Run it after every `src/` change |
| `pick_budget.py` | The calibration rule (inclusion rule 3): the budget nearest 50% inside the 30–70% band |
| `e6a_cegis.jl` | Enumerative CEGIS (Herb BFS with the Z3 oracle) per grammar variant, and the decomposed fair rival (RQ2b, RQ4b) |
| `cvc5_compare.py` | cvc5 on spec files, with a Z3 check of every solution (RQ2b, RQ4b) |
| `recipe_cegis_timing.jl` | Wall time of the deductive ceiling, recipe CEGIS (RQ2b) |
| `unfolded_sizes.py` | Program sizes in grammar nodes and unfolded into the original grammar |
| `rq1_coverage_survey.jl`, `rq1_survey_summary.py` | RQ1: what the compiler extracts from each benchmark population, and the summary tables |

### Utilities

| script | role |
|---|---|
| `artifact_io.jl` | Shared helpers for reading stored runs: per-seed artifacts and program strings back to `RuleNode`s |
| `verify_program_against_spec.jl` | Checks a given program against a spec file |
| `verify_multi_answer_specs.jl` | The properties the multi-answer specs rely on (`f.max4_slack`) |
| `measure_trace_overhead.jl` | How much of the timed search the harness's own tracing costs |
| `run_full_tests.sh` | The full test suite, logged to `results/full_tests.log` |

### Exploratory results the thesis keeps

| script | experiment |
|---|---|
| `run_e4_main.sh`, `e4_analysis.py` | E4: knowledge as seeds of the first population |
| `run_e5a_main.sh`, `e5a_analysis.py` | E5a: the guard alone and the graded placebos |
| `run_e5_main.sh`, `e5_analysis.py` | E5: granularity, atoms and blocks with their inert twins (rerun 2026-10-25) |
| `run_e6a.sh`, `run_e6a_stage1.sh`, `run_e6a_main.sh`, `run_cal_tiered3.sh` | E6a: partial knowledge on `tiered3`, with its calibration |
| `run_main_v3.sh`, `run_recipe_arms.sh` | The ablation: guided patch v3, recipe CEGIS and the recipes-only GA |

### Measurement

`contention/` holds the contention measurement behind "four workers, never six": the thesis cites its 1.4–1.8× slowdown
with no arm bias.

## Writing a script

Every script runs from the repository root. The file name says the script's role:

| prefix | role | output |
|---|---|---|
| `gen_` | writes spec files | `spec_files/<folder>/`; regenerating must reproduce existing files byte for byte |
| `check_`, `verify_` | checks a property and prints the verdict | stdout |
| `run_*.sh` | a run chain: one registered experiment | runs in `results/runs/`, log in `results/<name>.log` |
| `<exp>_analysis.py` | the registered analysis of one experiment | `results/<exp>_analysis.md` |
| anything else | a survey, a measurement or a probe | `results/<name>/` |

**The header** opens every script. It states:
- what the script computes;
- what it reads and writes;
- the exact command line, with each argument's default.

For a run chain, the header also names the experiment and the `src/` hash it was registered under. Stored runs in
`results/runs/` are never written by a script other than the harness.

### Julia

```julia
#=
scripts/check_something.jl — what it checks, in one sentence.

    julia --project=. scripts/check_something.jl [max_time_s=120] spec.sl [spec.sl ...]

Reads the spec files; prints one line per spec.
=#
using HerbCore, HerbGrammar, HerbConstraints, HerbInterpret, HerbSearch, HerbSpecification
include(joinpath(@__DIR__, "..", "src", "CEGIS.jl"))

max_time = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 120.0
```

- Load `HerbGrammar` at the top level: generated grammars are evaluated in `Main`.
- Positional arguments with defaults, as above. `using HerbCore, HerbGrammar, CEGIS` works as well (as in
  `check_replay.jl`).
- To read stored runs, `include(joinpath(@__DIR__, "artifact_io.jl"))` after the `using` line.
- Any auxiliary Z3 query (uniqueness, output oracle) needs its own Z3 context. A term built in the search's context
  changes the models Z3 returns there.

### Python

```python
#!/usr/bin/env python3
"""
What it computes, from which runs.

    PYTHONIOENCODING=utf-8 bench/.venv/Scripts/python scripts/x_analysis.py > results/x_analysis.md
"""
import csv, glob, os
from scipy.stats import binomtest
```

Run it with `bench/.venv`. Its packages are pinned in `bench/requirements.txt`, and `pip` needs
`--cert bench/.venv/os-roots.pem` on this machine. Paired comparisons use exact McNemar by seed, with Holm within each
registered family.

### Run chains

```bash
#!/usr/bin/env bash
# C3 RQ2a: baseline-lex on orig / inert / guard / case, pool 1, seeds 2001-2066. Registered <date>, src hash <hash>.
cd "$(dirname "$0")/.." || exit 1
LOG=results/rq2a.log
: > "$LOG"
SPECS=f.max7,f.array_search3
run() { echo "START $* $(date -u +%FT%TZ)" >> "$LOG"; julia bench/run.jl "$@" >> "$LOG" 2>&1; echo "END $? $(date -u +%FT%TZ)" >> "$LOG"; }
run --arm baseline-lex --name rq2a-guard --specs $SPECS --seeds 2001:2066 --jobs 4 --shards 4 --variant guard
run --arm baseline-lex --name rq2a-inert --specs $SPECS --seeds 2001:2066 --jobs 4 --shards 4 --variant inert
echo "RQ2A-DONE $(date -u +%FT%TZ)" >> "$LOG"
```

Before the launch:
- **Register first.** The experiment's entry in the register comes before any of its runs and cites the `src/` hash
  (`code_sha256()` in `bench/common.jl`).
- **Keep compared arms alike.** Arms that are compared share seeds, `--jobs 4 --shards 4` and the session: budgets are
  wall-clock, so load changes solve rates. Primary arms go first, and all arms of a spec run back to back.
- **Use `--variant` for grammar knowledge.** It swaps in `spec_files/enriched/<stem>_<variant>.sl` and keeps the
  registry's settings, so seeds pair with plain runs.
- **Re-running a chain resumes it.** Finished seeds are skipped. A run refuses to continue under a changed arm, spec,
  budget or source tree.

**Launch it from PowerShell, in its own hidden console:**

```powershell
Start-Process 'C:\Program Files\Git\usr\bin\bash.exe' -ArgumentList '-lc','"cd ~/.julia/dev/CEGIS && scripts/run_x.sh"' -WindowStyle Hidden
```

- The `bash` on `PATH` is WSL's, so give Git's bash by its full path.
- Never start a chain from a Claude Code background shell. If that shell is killed, every Z3 subprocess fails behind a
  modal error dialog.

While the chain runs:
- Run nothing else heavy on the machine, and close games.
- Do not edit `src/` or `bench/`: the workers load them at launch.
- Do not edit the chain itself: bash reads the file as it goes.

Follow progress through the `START`/`END` lines and the final `DONE` marker in the log.
