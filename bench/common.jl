#=
bench/common.jl — shared by the run supervisor and its workers.

Loads nothing from CEGIS, so the supervisor starts instantly and can write rows
(e.g. a `crashed` row) without paying for a package load.

The unit of storage is a RUN: one arm, run over a suite of specs and a seed
list, stored self-describingly under `results/runs/<name>/`. Comparison happens
afterwards, between any two stored runs (`bench/diagnose.py`). A run's
`manifest.toml` records everything a later comparison must check — the arm's
effective configuration, per-spec budgets and file hashes, a hash of the source
tree, git state, host and parallelism.
=#

using Dates, SHA, TOML

const CEGIS_ROOT = normpath(joinpath(@__DIR__, ".."))

# ── specs ────────────────────────────────────────────────────────────────────
#
# tier A = regression guard (baseline ~70-95%), B = core (30-70%, where
# significance is won), C = hard (10-40%, scaling claims).
# `calibrated = true` only where a baseline solve rate was actually measured at
# this budget. Everything else is provisional: calibrate (baseline arm, ~20
# seeds, candidate budgets) and FREEZE before relying on it. Re-tuning a budget
# after seeing an arm's results is p-hacking.

const SPECS = Dict{String,NamedTuple}(
    # tier A
    "max2"           => (path = "spec_files/phase3_benchmarks/max2_simple.sl", tier = :A, budget = 20.0,
                         pop_size = 200, max_depth = 4, depth_cap = 8,  calibrated = false),
    "max3"           => (path = "spec_files/phase3_benchmarks/max3_simple.sl", tier = :A, budget = 20.0,
                         pop_size = 200, max_depth = 5, depth_cap = 8,  calibrated = false),
    "max4"           => (path = "spec_files/phase3_benchmarks/max4_simple.sl", tier = :A, budget = 20.0,
                         pop_size = 400, max_depth = 6, depth_cap = 10, calibrated = false),
    "median3.cdgp"   => (path = "spec_files/paired/cdgp/median3.sl", tier = :A, budget = 20.0,
                         pop_size = 200, max_depth = 5, depth_cap = 10, calibrated = false),
    "range3.cdgp"    => (path = "spec_files/paired/cdgp/range3.sl", tier = :A, budget = 30.0,
                         pop_size = 200, max_depth = 5, depth_cap = 10, calibrated = false),
    # tier B
    "max5"           => (path = "spec_files/phase3_benchmarks/max5_simple.sl", tier = :B, budget = 60.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = true),   # 74-78% (hybrid-nowit)
    "countpos3.cdgp" => (path = "spec_files/paired/cdgp/countpos3.sl", tier = :B, budget = 60.0,
                         pop_size = 200, max_depth = 5, depth_cap = 10, calibrated = true),   # 73-77%
    "countpos3.ours" => (path = "spec_files/paired/ours/countpos3.sl", tier = :B, budget = 60.0,
                         pop_size = 200, max_depth = 5, depth_cap = 10, calibrated = false),
    "median3.ours"   => (path = "spec_files/paired/ours/median3.sl", tier = :B, budget = 60.0,
                         pop_size = 200, max_depth = 5, depth_cap = 10, calibrated = false),
    "range3.ours"    => (path = "spec_files/paired/ours/range3.sl", tier = :B, budget = 60.0,
                         pop_size = 200, max_depth = 5, depth_cap = 10, calibrated = false),
    "countpos2.cdgp" => (path = "spec_files/paired/cdgp/countpos2.sl", tier = :B, budget = 60.0,
                         pop_size = 200, max_depth = 5, depth_cap = 10, calibrated = false),
    "isseries3.cdgp" => (path = "spec_files/paired/cdgp/isseries3.sl", tier = :B, budget = 60.0,
                         pop_size = 200, max_depth = 5, depth_cap = 10, calibrated = false),
    "issorted4.cdgp" => (path = "spec_files/paired/cdgp/issorted4.sl", tier = :B, budget = 60.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),
    # tier C
    "max6"           => (path = "spec_files/phase3_benchmarks/max6_simple.sl", tier = :C, budget = 80.0,
                         pop_size = 400, max_depth = 6, depth_cap = 14, calibrated = true),   # 4/10 @80s (pilot-scale-lex)
    "issorted5.cdgp" => (path = "spec_files/paired/cdgp/issorted5.sl", tier = :C, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 14, calibrated = false),
    "countpos4.cdgp" => (path = "spec_files/paired/cdgp/countpos4.sl", tier = :C, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 14, calibrated = false),
    "max7"           => (path = "spec_files/phase3_benchmarks/max7_simple.sl", tier = :C, budget = 300.0,
                         pop_size = 400, max_depth = 7, depth_cap = 16, calibrated = true),   # 4/10 @300s (pilot-scale-lex)
    # Probes (2026-09-28): max8 with the generated grammar, and max7/max8 with the official
    # SyGuS-COMP LIA grammar (and/or/not; no *, <, >). Settings as max7 (depth cap n + 9), uncalibrated.
    "max8"           => (path = "spec_files/phase3_benchmarks/max8_simple.sl", tier = :C, budget = 300.0,
                         pop_size = 400, max_depth = 7, depth_cap = 17, calibrated = false),
    # Spec-enriched grammar pilot (RQ1_RQ2_PLAN.md §7.14): max6 with the official SyGuS-COMP LIA grammar,
    # max6's settings and budget, uncalibrated.
    "max6.sygus"     => (path = "spec_files/grammar_variants/max6_sygus.sl", tier = :C, budget = 80.0,
                         pop_size = 400, max_depth = 6, depth_cap = 14, calibrated = false),
    "max7.sygus"     => (path = "spec_files/grammar_variants/max7_sygus.sl", tier = :C, budget = 300.0,
                         pop_size = 400, max_depth = 7, depth_cap = 16, calibrated = false),
    "max8.sygus"     => (path = "spec_files/grammar_variants/max8_sygus.sl", tier = :C, budget = 300.0,
                         pop_size = 400, max_depth = 7, depth_cap = 17, calibrated = false),
    # Scaling probes for the recipe arms (RQ1_RQ2_PLAN.md §7.12), official SyGuS grammar, 5 min.
    "max18.sygus"    => (path = "spec_files/grammar_variants/max18_sygus.sl", tier = :C, budget = 300.0,
                         pop_size = 400, max_depth = 7, depth_cap = 27, calibrated = false),
    "max20.sygus"    => (path = "spec_files/grammar_variants/max20_sygus.sl", tier = :C, budget = 300.0,
                         pop_size = 400, max_depth = 7, depth_cap = 29, calibrated = false),
    # tier M — multi-answer: the spec accepts several outputs at some or all
    # inputs, so counterexamples become incomplete tests (src/GeneticSearch/
    # incomplete_tests.jl). Properties checked by scripts/verify_multi_answer_specs.jl.
    # Calibrated with baseline-lex on seeds 1001-1020 (run `cal-multi-lex`), never
    # on evaluation seeds. max3_slack and avoid2 solve in seconds: regression
    # guards, not discriminating.
    "max3_slack"     => (path = "spec_files/multi_answer/max3_slack.sl", tier = :M, budget = 20.0,
                         pop_size = 200, max_depth = 5, depth_cap = 8,  calibrated = true),   # 20/20 (guard)
    "avoid2"         => (path = "spec_files/multi_answer/avoid2.sl", tier = :M, budget = 30.0,
                         pop_size = 200, max_depth = 5, depth_cap = 10, calibrated = true),   # 18/20 (guard)
    "max4_slack"     => (path = "spec_files/multi_answer/max4_slack.sl", tier = :M, budget = 30.0,
                         pop_size = 400, max_depth = 6, depth_cap = 10, calibrated = true),   # 12/20 @30s (16/20 @60s)
    "range3_slack"   => (path = "spec_files/multi_answer/range3_slack.sl", tier = :M, budget = 60.0,
                         pop_size = 200, max_depth = 5, depth_cap = 10, calibrated = true),   # 10/20 @60s
    "above4"         => (path = "spec_files/multi_answer/above4.sl", tier = :M, budget = 45.0,
                         pop_size = 400, max_depth = 6, depth_cap = 10, calibrated = true),   # 10/20 @45s (4/20 @30s, 14/20 @60s)
    "max5_slack"     => (path = "spec_files/multi_answer/max5_slack.sl", tier = :M, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = true),   # 4/10 @300s (0/20 @60s)
    # above_n scaling family (one independent constraint per input). Settings follow a
    # rule, not per-spec tuning: pop 400, initial depth 6, depth cap n + 6 (above4's 10;
    # a chained sum of n terms needs about n + 3). Budgets from the scaling pilot.
    "above5"         => (path = "spec_files/multi_answer/above5.sl", tier = :M, budget = 160.0,
                         pop_size = 400, max_depth = 6, depth_cap = 11, calibrated = true),   # 5/10 @160s (pilot-scale-lex)
    "above6"         => (path = "spec_files/multi_answer/above6.sl", tier = :M, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = true),   # 3/10 @300s
    "above7"         => (path = "spec_files/multi_answer/above7.sl", tier = :M, budget = 900.0,
                         pop_size = 400, max_depth = 6, depth_cap = 13, calibrated = true),   # 0/10 @300s -> exploratory 900s x 10
    # tier K — case splits: one guarded constraint per input region (spec_files/case_split/).
    # Budgets from a baseline-lex pilot (seeds 1001-1010, 300 s); settings as max5.
    "countpos4.split" => (path = "spec_files/case_split/countpos4_split.sl", tier = :K, budget = 45.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = true),   # 5/10 @45s (pilot-split-lex)
    "array_search4"  => (path = "spec_files/case_split/array_search4.sl", tier = :K, budget = 20.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = true),   # 5/10 @20s (pilot-split-lex)
    # Partial-knowledge case split (spec_knowledge/PARTIAL_KNOWLEDGE.md): regions A, B write their answer
    # (recipes); C, D give only a relation (guard-only). Settings as the other case splits; budget from
    # the calibration run `cal-tiered-lex` (seeds 1001-1020).
    "tiered"         => (path = "spec_files/partial_knowledge/tiered.sl", tier = :K, budget = 180.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),  # too easy: 20/20, median 5 s (cal-tiered-lex)
    # Harder sibling: six regions over (x, y, z), 2 recipes + 4 guard-only. Budget from `cal-tiered3-lex`.
    "tiered3"        => (path = "spec_files/partial_knowledge/tiered3.sl", tier = :K, budget = 180.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = true),   # 10/20 @180s (cal-tiered3-lex)
    # Many-input partial-knowledge family (spec_knowledge/EXPERIMENTS.md E6c probe; scripts/gen_partial_family.py):
    # 6 regions, 2 answered; n inputs, answers of s nodes. Uncalibrated probe settings: 300 s, depth cap 16.
    "pk.n3s17"       => (path = "spec_files/partial_knowledge/family/pk_n3_m6_k2_s17_seed1.sl", tier = :P, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
    "pk.n6s17"       => (path = "spec_files/partial_knowledge/family/pk_n6_m6_k2_s17_seed1.sl", tier = :P, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
    "pk.n10s13"       => (path = "spec_files/partial_knowledge/family/pk_n10_m6_k2_s13_seed1.sl", tier = :P, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
    "pk.n10s17"       => (path = "spec_files/partial_knowledge/family/pk_n10_m6_k2_s17_seed1.sl", tier = :P, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
    "pk.n16s9"       => (path = "spec_files/partial_knowledge/family/pk_n16_m6_k2_s9_seed1.sl", tier = :P, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
    "pk.n16s13"       => (path = "spec_files/partial_knowledge/family/pk_n16_m6_k2_s13_seed1.sl", tier = :P, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
    "pk.n16s17"       => (path = "spec_files/partial_knowledge/family/pk_n16_m6_k2_s17_seed1.sl", tier = :P, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
    # Second ordered case split (RQ1_RQ2_PLAN.md §7.9): array_search4's regions, variable outputs.
    "array_ceil4"    => (path = "spec_files/case_split/array_ceil4.sl", tier = :K, budget = 20.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),  # placeholder until a pilot
    # Grammar ablation (RQ1_RQ2_PLAN.md §7.9): max6 + and/or/not.
    "max6.logic"     => (path = "spec_files/grammar_variants/max6_logic.sl", tier = :C, budget = 105.0,
                         pop_size = 400, max_depth = 6, depth_cap = 14, calibrated = true),   # 10/20 @105s (cal-max6logic-lex)
    # Confirmatory phase (spec_knowledge/FULL_SCALE_PLAN.md). Tier F: complete knowledge, ten families (RQ2, RQ3), plus
    # the reserve f.sign. Tier G: partial knowledge, seven structural classes (RQ4). Inclusion rules 1 and 2 checked by
    # scripts/check_inclusion.jl. Budgets are placeholders: calibration (rule 3) freezes them, passed by --budget.
    "f.max7"         => (path = "spec_files/grammar_variants/max7_sygus.sl", tier = :F, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 14, calibrated = false),
    "f.array_search3" => (path = "spec_files/confirmatory/array_search3.sl", tier = :F, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),
    "f.array_sum3"   => (path = "spec_files/confirmatory/array_sum3_15.sl", tier = :F, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),
    "f.range3"       => (path = "spec_files/paired/cdgp/range3.sl", tier = :F, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),
    "f.median3"      => (path = "spec_files/paired/cdgp/median3.sl", tier = :F, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),
    "f.countpos2"    => (path = "spec_files/paired/cdgp/countpos2.sl", tier = :F, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),
    "f.condsum"      => (path = "spec_files/confirmatory/conditional_sum_hard.sl", tier = :F, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 18, calibrated = false),  # seed chains 16-18 deep
    "f.max4_slack"   => (path = "spec_files/multi_answer/max4_slack.sl", tier = :F, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 14, calibrated = false),  # seed chains 12-14 deep
    "f.clamp"        => (path = "spec_files/confirmatory/clamp_value_easy.sl", tier = :F, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),
    "f.abs"          => (path = "spec_files/confirmatory/abs_value_easy.sl", tier = :F, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),
    "f.sign"         => (path = "spec_files/confirmatory/sign_function_easy.sl", tier = :F, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),
    "g.tiered3"      => (path = "spec_files/partial_knowledge/tiered3.sl", tier = :G, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),
    "g.hidden3"      => (path = "spec_files/partial_knowledge/hidden3.sl", tier = :G, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),
    "g.recur3"       => (path = "spec_files/partial_knowledge/recur3.sl", tier = :G, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 12, calibrated = false),
    "g.pk3"          => (path = "spec_files/partial_knowledge/family/pk_n3_m6_k2_s9_seed1.sl", tier = :G, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
    "g.pk3w2"        => (path = "spec_files/partial_knowledge/family/pk_n3_m6_k2_s9_w2_seed1.sl", tier = :G, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
    "g.pk3k4"        => (path = "spec_files/partial_knowledge/family/pk_n3_m6_k4_s9_seed1.sl", tier = :G, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
    "g.pk3k1"        => (path = "spec_files/partial_knowledge/family/pk_n3_m6_k1_s9_seed1.sl", tier = :G, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
    "g.pk3m8"        => (path = "spec_files/partial_knowledge/family/pk_n3_m8_k2_s9_seed1.sl", tier = :G, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
    "g.pk6"          => (path = "spec_files/partial_knowledge/family/pk_n6_m6_k2_s17_seed1.sl", tier = :G, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
    "g.pk10"         => (path = "spec_files/partial_knowledge/family/pk_n10_m6_k2_s13_seed1.sl", tier = :G, budget = 300.0,
                         pop_size = 400, max_depth = 6, depth_cap = 16, calibrated = false),
)

"""Named spec lists. `core` holds only specs calibrated into the discriminating band."""
const SUITES = Dict{String,Vector{String}}(
    "quick" => ["max2", "max3", "max4", "median3.cdgp", "range3.cdgp"],
    "core"  => sort([k for (k, v) in SPECS if v.tier === :B && v.calibrated]),
    "b"     => sort([k for (k, v) in SPECS if v.tier === :B]),
    "multi" => sort([k for (k, v) in SPECS if v.tier === :M]),
    # Scaling study: separable family (above_n) vs coupled family (max_n).
    "scale" => ["above4", "above5", "above6", "above7", "max5", "max6", "max7"],
    "split" => ["countpos4.split", "array_search4"],
    "full"  => sort(collect(keys(SPECS))),
)

# ── memory guard ─────────────────────────────────────────────────────────────
#
# A worker does not START a timed seed while the machine is short of memory:
# under pressure the search slows (distorting wall-clock budgets) and z3
# subprocesses fail to start (observed 2026-09-26: 88 correct programs recorded
# as `unverified`). Waiting happens before the clock starts, so it cannot bias a
# seed; the wait and the free memory at the start are recorded per seed and
# `diagnose.py` warns about runs with low-memory seeds.
const MIN_FREE_MB = 1500      # one worker needs ~0.7-1.1 GB, plus headroom for z3
const MEM_WAIT_MAX_S = 900    # then run anyway, flagged by sys_free_mb
const REVERIFY_ATTEMPTS = 3   # re-verification retries before recording `error`
# CPU contention: budgets are wall-clock, so another busy process slows the search
# (observed 2026-09-26: 30-40% slower generations for ~3 h, far fewer solves). Each
# seed records the machine-wide busy fraction during its timed search; `diagnose.py`
# flags seeds whose load exceeds what the run's own workers explain (jobs / threads)
# by more than this many cores' worth. Windows background load is ~0.7 of a core.
const CPU_EXCESS_CORES = 3.0

# ── arms ─────────────────────────────────────────────────────────────────────
#
# Plain data (symbols, numbers). The worker turns `selection` into an Arborist
# strategy object. Any key other than `selection` is passed to `run_cdgp`, so a
# new idea behind a new keyword needs only a new entry here — or, for a one-off,
# `--set key=value` on the command line.

const ARMS = Dict{String,NamedTuple}(
    "baseline-cdgp"  => (fitness = :tests,  selection = :tournament),
    "baseline-lex"   => (fitness = :tests,  selection = :lexicase),
    # E3 (spec_knowledge/EXPERIMENTS.md): starting tests before generation 0. regions = one per satisfiable
    # premise of the spec's implications; random = the same number of uniform random inputs (control).
    "lex-seed-regions" => (fitness = :tests, selection = :lexicase, seed_tests = :regions),
    "lex-seed-random"  => (fitness = :tests, selection = :lexicase, seed_tests = :random),
    # E3b: one point per premise drawn uniformly from inside the region (not z3's boundary model).
    "lex-seed-inner"   => (fitness = :tests, selection = :lexicase, seed_tests = :regions_inner),
    # E4: the spec's recipes and region guards as programs in 10% of the first population (seed_programs.jl).
    # guard = every region's guard, random leaves; partial = half the items, recipe answers kept; full = every
    # item, recipe answers kept; inert = the guard shape with unsatisfiable guards (placebo).
    "lex-init-guard"   => (fitness = :tests, selection = :lexicase, seed_programs = :guard),
    "lex-init-partial" => (fitness = :tests, selection = :lexicase, seed_programs = :partial),
    "lex-init-full"    => (fitness = :tests, selection = :lexicase, seed_programs = :full),
    "lex-init-inert"   => (fitness = :tests, selection = :lexicase, seed_programs = :inert),
    # Ablation for multi-answer specs: every counterexample a complete test
    # with Z3's arbitrary output (the behaviour before incomplete tests).
    # Identical to baseline-lex on single-answer specs.
    "baseline-lex-legacy" => (fitness = :tests, selection = :lexicase, incomplete_tests = false),
    # Proposal 2: one test per violated constraint per verification, instead of
    # one counterexample per verification. `-1` caps it at one test per
    # verification: the same per-constraint Z3 path, isolating "more tests per
    # verification" from "a different verifier".
    "lex-percon"     => (fitness = :tests,  selection = :lexicase, cex_mode = :per_constraint),
    "lex-percon-1"   => (fitness = :tests,  selection = :lexicase, cex_mode = :per_constraint,
                         max_new_tests = 1),
    # hybrid-tour is the tournament twin of hybrid-nowit: no witness battery.
    "hybrid-tour"    => (fitness = :hybrid, selection = :tournament, witness_cases = false),
    "hybrid-nowit"   => (fitness = :hybrid, selection = :lexicase, witness_cases = false),
    "hybrid-frozen"  => (fitness = :hybrid, selection = :lexicase, witness_cases = true,
                         witness_policy = :none),
    "hybrid-ratio"   => (fitness = :hybrid, selection = :lexicase, witness_cases = true,
                         witness_policy = :ratio, witness_test_ratio = 0.5),
    # hybrid-ratio as run before 2026-09-26, when the hybrid capped its tests at 64.
    "hybrid-ratio-cap64" => (fitness = :hybrid, selection = :lexicase, witness_cases = true,
                         witness_policy = :ratio, witness_test_ratio = 0.5, max_tests = 64),
    # RQ2 stage 3 (RQ1_RQ2_PLAN.md §7.5): baseline-lex whose mutation writes a guarded
    # partial repair ite(g, e, n) at an SMT-localized node for parents failing some tests
    # (GuidedPatchMutation); placebo = same work, random subtree at the same site.
    # rate 0.3 / budget 8 chosen by the stage 3a calibration pilot (seeds 1001-1020,
    # scripts/attic/stage3_calibration.py; RQ1_RQ2_PLAN.md §7.6).
    "lex-guided"     => (fitness = :tests, selection = :lexicase, guided = :patch,
                         guided_rate = 0.3, guided_budget = 8, guided_min_pass = 8),
    "lex-guided-placebo" => (fitness = :tests, selection = :lexicase, guided = :placebo,
                         guided_rate = 0.3, guided_budget = 8, guided_min_pass = 8),
    # guided v2 (RQ1_RQ2_PLAN.md §7.10): sampled localization, smaller term pool, builds on the
    # 32 most recent passing tests + validation on all, cache kept across test growth.
    "lex-guided-v2"  => (fitness = :tests, selection = :lexicase, guided = :patch,
                         guided_rate = 0.3, guided_budget = 8, guided_min_pass = 8,
                         guided_sites = :l3_sampled, guided_candidates = 6, guided_extra = 2,
                         guided_max_pass = 32, guided_keep_cache = true),
    # guided v3 (RQ1_RQ2_PLAN.md §7.10b): v2 + spec-derived answer patches ite(G_t, t, ·).
    "lex-guided-v3"  => (fitness = :tests, selection = :lexicase, guided = :patch,
                         guided_rate = 0.3, guided_budget = 8, guided_min_pass = 8,
                         guided_sites = :l3_sampled, guided_candidates = 6, guided_extra = 2,
                         guided_max_pass = 32, guided_keep_cache = true, guided_shapes = :spec),
    # GA ablation (RQ1_RQ2_PLAN.md §7.12): the GA with answer recipes as its ONLY variation —
    # no crossover, every offspring a guided attempt, no localization, no subtree mutation (a
    # failed attempt copies the parent). Isolates what the GA adds on top of the recipes.
    # min_pass = 1: recipes take their guard from the spec, not the tests; with v3's 8 the population
    # never becomes eligible (tests stay at 2-7, nothing is ever applied; smoke 2026-09-28).
    "lex-recipes-only" => (fitness = :tests, selection = :lexicase, guided = :patch,
                         guided_rate = 1.0, guided_budget = 8, guided_min_pass = 1,
                         guided_sites = :none, guided_keep_cache = true, guided_shapes = :spec,
                         guided_fallback = :keep, crossover_rate = 0.0, mutation_rate = 1.0),
    # Non-GP reference (RQ1_RQ2_PLAN.md §7.12): CEGIS over the spec's answer recipes
    # (`RecipeIterator`, `run_recipe_cegis`); every counterexample adds the case whose guard fires there.
    # Deterministic, no population, no depth cap. The GA settings the worker passes are ignored.
    "recipe-cegis"   => (engine = :recipes,),
    # RQ3 arms go here: enum-cegis.
)

"""
    parse_overrides("witness_test_ratio=0.3,witness_policy=:fifo") -> Dict{Symbol,Any}

Literal values only: integers, floats, `true`/`false`, `:symbols`, and bare words
(taken as strings). Anything else is rejected rather than evaluated.
"""
function parse_overrides(s::AbstractString)::Dict{Symbol,Any}
    out = Dict{Symbol,Any}()
    isempty(strip(s)) && return out
    for item in split(s, ",")
        kv = split(item, "="; limit = 2)
        length(kv) == 2 || error("--set expects key=value, got `$item`")
        k, v = Symbol(strip(kv[1])), strip(kv[2])
        out[k] = v in ("true", "false") ? v == "true" :
                 startswith(v, ":") ? Symbol(v[2:end]) :
                 something(tryparse(Int, v), tryparse(Float64, v), String(v))
    end
    return out
end

"""TOML cannot hold Symbols: encode them as `":name"` strings (and back)."""
encode_cfg(cfg) = Dict{String,Any}(String(k) => (v isa Symbol ? ":" * String(v) : v) for (k, v) in pairs(cfg))
decode_cfg(d::AbstractDict) =
    (; (Symbol(k) => (v isa String && startswith(v, ":") ? Symbol(v[2:end]) : v) for (k, v) in d)...)

"""Stable 12-hex-digit hash of an arm's effective configuration."""
arm_hash(cfg) =
    bytes2hex(sha256(join(("$k=$(repr(v))" for (k, v) in sort(collect(pairs(cfg)); by = first)), ";")))[1:12]

spec_abspath(name::AbstractString) = joinpath(CEGIS_ROOT, SPECS[name].path)
spec_sha256(name::AbstractString) = bytes2hex(open(sha256, spec_abspath(name)))

"""
Grammar variant of a registered spec (`run.jl --variant NAME`): the same constraints with an enriched
or decoy grammar, from `scripts/gen_enriched_grammars.jl`. The run keeps the spec's registry key and
settings, so its seeds pair with ordinary runs of that spec in `diagnose.py`.
"""
variant_path(path::AbstractString, variant::AbstractString) =
    joinpath("spec_files", "enriched", replace(basename(path), ".sl" => "") * "_$variant.sl")

# ── provenance ───────────────────────────────────────────────────────────────

function git_provenance()
    sha = try
        readchomp(Cmd(`git rev-parse HEAD`; dir = CEGIS_ROOT))
    catch
        "unknown"
    end
    dirty = try
        !isempty(readchomp(Cmd(`git status --porcelain --untracked-files=no`; dir = CEGIS_ROOT)))
    catch
        true
    end
    return (git_sha = sha, git_dirty = dirty)
end

"""
Hash of every `.jl` file under `src/` (path and content). Distinguishes two
uncommitted states of the code, which the git sha cannot — the normal situation
when iterating on an idea.
"""
function code_sha256()
    files = String[]
    for (root, _, fs) in walkdir(joinpath(CEGIS_ROOT, "src")), f in fs
        endswith(f, ".jl") && push!(files, joinpath(root, f))
    end
    ctx = SHA.SHA256_CTX()
    for f in sort(files)
        SHA.update!(ctx, Vector{UInt8}(relpath(f, CEGIS_ROOT)))
        SHA.update!(ctx, read(f))
    end
    return bytes2hex(SHA.digest!(ctx))[1:16]
end

utc_now() = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS") * "Z"

hostname() = try
    gethostname()
catch
    "unknown"
end

# ── run directory layout ─────────────────────────────────────────────────────
#
# results/runs/<name>/
#   manifest.toml                  arm config, spec budgets+hashes, code hash, git, host, jobs
#   sessions.log                   one line per invocation (including resumes)
#   runs/<spec>.s<k>.csv           one row per seed          (shard k)
#   generations/<spec>.s<k>.csv    one row per generation per seed
#   artifacts/<spec>.s<k>.jsonl    per seed: program, status, the tests it generated
#   logs/<spec>.s<k>.log           worker output
#   inflight/<spec>.s<k>           seed currently running (crash detection)
#
# Each (spec, shard) file has exactly one writer, so parallel workers never
# interleave appends.

runs_root() = joinpath(CEGIS_ROOT, "results", "runs")
run_dir(name) = joinpath(runs_root(), name)
manifest_path(name) = joinpath(run_dir(name), "manifest.toml")
shard_stem(spec, k) = "$(spec).s$(k)"
runs_path(name, spec, k)        = joinpath(run_dir(name), "runs", shard_stem(spec, k) * ".csv")
generations_path(name, spec, k) = joinpath(run_dir(name), "generations", shard_stem(spec, k) * ".csv")
artifacts_path(name, spec, k)   = joinpath(run_dir(name), "artifacts", shard_stem(spec, k) * ".jsonl")
inflight_path(name, spec, k)    = joinpath(run_dir(name), "inflight", shard_stem(spec, k))
log_path(name, spec, k)         = joinpath(run_dir(name), "logs", shard_stem(spec, k) * ".log")

"""Every shard's runs file for `spec` in run `name`."""
function spec_run_files(name, spec)
    d = joinpath(run_dir(name), "runs")
    isdir(d) || return String[]
    pre = spec * ".s"
    return [joinpath(d, f) for f in readdir(d) if startswith(f, pre) && endswith(f, ".csv") &&
            all(isdigit, f[length(pre)+1:end-4])]
end

const RUN_COLUMNS = [
    "run", "spec", "tier", "arm", "seed", "shard", "status", "solved", "claimed", "verified",
    "time_to_solve_s", "censored", "budget_s", "elapsed_s", "generations", "solve_gen", "rounds",
    "pop_size", "z3_total", "z3_constraint_checks", "z3_cex_queries", "z3_complete_output",
    "z3_output_unique", "z3_subprocess", "z3_time_s", "z3_reverify", "tests_final",
    "incomplete_final", "single_answer", "unique_checks", "tests_unchecked", "tests_seeded",
    "cex_mode", "cex_fallback", "cex_events", "cex_witnesses", "cex_tests_added", "cex_dup",
    "cex_no_output", "cex_capped", "cex_multi_events", "cex_max_per_event", "witnesses_final",
    "witnesses_evicted", "harvested",
    "guided_mode", "guided_attempts", "guided_applied", "guided_analyses", "guided_site_builds",
    "guided_cache_hits", "guided_ineligible", "guided_no_site", "guided_no_patch",
    "guided_budget_skip", "guided_depth_reject", "guided_time_s",
    "guided_validate_reject", "guided_t_evidence", "guided_t_localize", "guided_t_build",
    "guided_t_validate", "guided_shape_applied", "guided_shape_reject",
    "best_fitness", "program_size", "program_depth",
    "val_acc_final", "val_pairs_final", "val_n", "validation_s", "rss_mb",
    "sys_free_mb", "mem_wait_s", "reverify_attempts", "cpu_busy",
    "git_sha", "git_dirty", "code_sha256", "spec_sha256", "arm_hash", "julia_version",
    "started_utc", "error", "program_expr",
]

const GEN_COLUMNS = [
    "run", "spec", "arm", "seed", "gen", "round", "elapsed_s", "best_fitness",
    "mean_fitness", "best_size", "tests", "incomplete_tests", "witnesses", "solved",
    "z3_constraint_checks", "z3_cex_queries", "z3_complete_output", "z3_output_unique",
    "z3_subprocess", "z3_total", "z3_time_s",
    "val_acc", "val_pairs", "unique_genomes", "mean_size", "max_size",
]

"""RFC-4180 field: quote when it contains a comma, quote or newline."""
function csv_field(x)
    s = x === nothing ? "" :
        x isa AbstractFloat ? (isnan(x) ? "" : isinf(x) ? (x > 0 ? "inf" : "-inf") : string(x)) :
        x isa Bool ? (x ? "1" : "0") : string(x)
    return any(c -> c in (',', '"', '\n', '\r'), s) ? "\"" * replace(s, "\"" => "\"\"") * "\"" : s
end

"""Append rows (each a Dict column => value) to `path`, writing the header on first use."""
function append_rows(path::AbstractString, columns::Vector{String}, rows)
    mkpath(dirname(path))
    fresh = !isfile(path) || filesize(path) == 0
    open(path, "a") do io
        fresh && println(io, join(columns, ","))
        for r in rows
            println(io, join((csv_field(get(r, c, nothing)) for c in columns), ","))
        end
    end
    return nothing
end

"""Seeds with a row (any status) in any shard of `spec` — skipped on resume."""
function done_seeds(name, spec)::Set{Int}
    seeds = Set{Int}()
    for path in spec_run_files(name, spec)
        for (i, line) in enumerate(eachline(path))
            i == 1 && continue
            f = split(line, ","; limit = 7)
            length(f) >= 5 || continue
            s = tryparse(Int, f[5])
            s === nothing || push!(seeds, s)
        end
    end
    return seeds
end

# ── minimal JSON (write-only, for artifacts) ─────────────────────────────────

json(x::Nothing) = "null"
json(x::Bool) = x ? "true" : "false"
json(x::Integer) = string(x)
json(x::AbstractFloat) = isfinite(x) ? string(x) : "null"
json(x::Symbol) = json(String(x))
function json(x::AbstractString)
    b = IOBuffer()
    print(b, '"')
    for c in x
        c == '"' ? print(b, "\\\"") : c == '\\' ? print(b, "\\\\") :
        c == '\n' ? print(b, "\\n") : c == '\r' ? print(b, "\\r") :
        c == '\t' ? print(b, "\\t") : c < ' ' ? print(b, "\\u", string(UInt16(c), base = 16, pad = 4)) :
        print(b, c)
    end
    print(b, '"')
    return String(take!(b))
end
json(x::AbstractDict) = "{" * join((json(string(k)) * ":" * json(v) for (k, v) in x), ",") * "}"
json(x::Union{AbstractVector,Tuple}) = "[" * join((json(v) for v in x), ",") * "]"
json(x) = json(string(x))

# ── rows the supervisor writes ───────────────────────────────────────────────

"""
A `crashed` row: the worker died uncatchably (e.g. a Z3 in-process abort) while
running `seed`. Written by the supervisor, the only party still alive.
"""
function crashed_row(name, spec, shard, seed, man; note = "process exited while running this seed")
    sm = man["specs"][spec]
    return Dict{String,Any}(
        "run" => name, "spec" => spec, "tier" => sm["tier"], "arm" => man["arm"], "seed" => seed,
        "shard" => shard, "status" => "crashed", "solved" => false, "claimed" => false,
        "verified" => false, "budget_s" => sm["budget"], "censored" => true,
        "time_to_solve_s" => sm["budget"],
        "git_sha" => man["git_sha"], "git_dirty" => man["git_dirty"],
        "code_sha256" => man["code_sha256"], "spec_sha256" => sm["sha256"],
        "arm_hash" => man["arm_hash"], "started_utc" => utc_now(), "error" => note)
end

# ── CLI helpers ──────────────────────────────────────────────────────────────

"""Parse `1:66`, `1,3,7` or `5` into a seed list."""
function parse_seeds(s::AbstractString)::Vector{Int}
    if occursin(':', s)
        lo, hi = split(s, ':')
        return collect(parse(Int, lo):parse(Int, hi))
    end
    return [parse(Int, x) for x in split(s, ",")]
end

"""Minimal `--key value` argument parser with defaults and unknown-key errors."""
function parse_cli(argv, defaults::Dict{String,String})
    opts = copy(defaults)
    i = 1
    while i <= length(argv)
        a = argv[i]
        startswith(a, "--") || error("unexpected argument `$a`")
        k = a[3:end]
        haskey(opts, k) || error("unknown option --$k; known: $(join(sort(collect(keys(opts))), ", "))")
        i < length(argv) || error("--$k needs a value")
        opts[k] = argv[i+1]
        i += 2
    end
    return opts
end
