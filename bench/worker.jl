#=
bench/worker.jl — run one shard of one spec for a stored run.

    julia --project=. bench/worker.jl --run NAME --spec max5 --shard 1 --seeds 1,4,7

Launched by bench/run.jl, which restarts it after a crash. Everything about the
run — arm configuration, budget, battery size — comes from the run's
`manifest.toml`, so a worker can never disagree with the run it belongs to.
Seeds already present in any shard file are skipped, so a worker is always safe
to re-run.

Per seed:
  1. write the inflight marker (so an uncatchable death is attributable)
  2. run_cdgp with a CDGPTrace, under the spec's wall-clock budget
  3. re-verify any claimed solution with an out-of-process Z3 query
  4. score every recorded best genome on the fixed ValidationBattery
     (after the search, so it costs nothing inside the budget)
  5. append generation rows, the artifact line, then the run row; clear the marker

The run row is written last: its presence is what marks a seed complete.

Primary endpoint (administrative censoring at the budget):
  solved = verified by out-of-process Z3 AND reached within `budget_s`.
The deadline is checked between rounds, so a round may overrun it; a solve
inside that overrun is recorded as `verified` but not `solved`.
=#

include(joinpath(@__DIR__, "common.jl"))

const OPTS = parse_cli(ARGS, Dict("run" => "", "spec" => "", "shard" => "1", "seeds" => ""))
for k in ("run", "spec", "seeds")
    isempty(OPTS[k]) && error("--$k is required")
end
const RUN, SPEC = OPTS["run"], OPTS["spec"]
const SHARD = parse(Int, OPTS["shard"])
const SEEDS = parse_seeds(OPTS["seeds"])
isfile(manifest_path(RUN)) || error("no manifest for run `$RUN` — start runs with bench/run.jl")
const MAN = TOML.parsefile(manifest_path(RUN))
haskey(MAN["specs"], SPEC) || error("spec `$SPEC` is not part of run `$RUN`")
const SM = MAN["specs"][SPEC]
const ARMCFG = decode_cfg(MAN["arm_config"])
const BUDGET = Float64(SM["budget"])

push!(LOAD_PATH, joinpath(CEGIS_ROOT, "src"))
using HerbCore, HerbGrammar, HerbConstraints, HerbInterpret, HerbSearch, HerbSpecification
include(joinpath(CEGIS_ROOT, "src", "CEGIS.jl"))
import Arborist
const CG = CEGIS.CEXGeneration
const GS = CEGIS.GeneticSearch
CG.set_default_candidate_parser(CG.SymbolicCandidateParser())

const PATH = joinpath(CEGIS_ROOT, SM["path"])
bytes2hex(open(sha256, PATH)) == SM["sha256"] ||
    error("spec file $(SM["path"]) changed since run `$RUN` started — start a new run")
const SPEC_OBJ = CG.parse_spec_from_file(PATH)
const HAS_GRAMMAR = SPEC_OBJ.synth_funs[1].grammar !== nothing
const GRAMMAR = HAS_GRAMMAR ? CEGIS.GrammarBuilding.build_grammar_from_sygus(SPEC_OBJ) :
                              CEGIS.build_grammar_from_spec(PATH)
const START = HAS_GRAMMAR ? CEGIS.GrammarBuilding.sygus_start_symbol(SPEC_OBJ) : :Expr
# Fixed battery seed (the constructor default): every run and seed of this spec
# is scored on identical inputs, so validation accuracy is comparable across runs.
const BATTERY = GS.ValidationBattery(SPEC_OBJ, GRAMMAR; n = Int(MAN["val_n"]))

"""run_cdgp keyword arguments for this arm on this spec."""
function run_kwargs()
    kw = Dict{Symbol,Any}(pairs(ARMCFG))
    sel = pop!(kw, :selection, :tournament)
    kw[:selection] = sel === :lexicase ? Arborist.LexicaseSelection() : nothing
    kw[:engine] = get(kw, :engine, :ga)
    # A generation budget (E5b: `--set generations=N`) on top of the wall-clock one; by default effectively none.
    gens = pop!(kw, :generations, 100_000)
    return (; kw..., grammar = GRAMMAR, start_symbol = START, max_time = BUDGET,
              generations = gens, generations_per_round = 10,
              pop_size = Int(SM["pop_size"]), max_depth = Int(SM["max_depth"]),
              depth_cap = Int(SM["depth_cap"]), verbose = false)
end
const KW = run_kwargs()

"""The arm's synthesizer: the GA (`run_cdgp`), or the non-GP recipe CEGIS for `engine = :recipes`."""
run_arm(; kw...) = KW.engine === :recipes ? CEGIS.run_recipe_cegis(PATH; KW..., kw...) :
                                            GS.run_cdgp(PATH; KW..., kw...)

const Z3_WATCHDOG_S = 60.0   # a re-verification z3 still running after this is killed

"""
Run the z3 binary on a query and return its verdict: `:unsat`, `:sat`, or `:error`.

Guarded by a watchdog. On 2026-09-27 Claude Code killed the shell that launched a
run (memory pressure); its console died with it, the workers carried on, and from
then on every process they started failed to initialise (0xc0000142, "unable to
start correctly") and sat behind a modal error dialog until someone clicked it —
freezing all workers for hours. Reproduced and confirmed: once the console is gone,
no child process can start, however it is launched (detached, NUL stdin, hidden),
and suppressing error dialogs does not stop this one. The cure is not to lose the
console (launch runs outside Claude Code's background shells; see bench/README.md);
this watchdog only guarantees that a stuck z3 costs `Z3_WATCHDOG_S`, not hours.
The query and verdict are the same as `CEXGeneration.verify_query`; counted as a
subprocess call.
"""
function z3_detached(query::String)::Symbol
    tmp = tempname() * ".smt2"
    try
        write(tmp, query)
        out, err = IOBuffer(), IOBuffer()
        t0 = time_ns()
        try
            proc = run(pipeline(Cmd(`z3 $tmp`; ignorestatus = true, detach = true, windows_hide = true);
                                stdin = devnull, stdout = out, stderr = err); wait = false)
            t = time()
            while process_running(proc) && time() - t < Z3_WATCHDOG_S
                sleep(0.05)
            end
            if process_running(proc)
                kill(proc)
                return :error
            end
            wait(proc)
        finally
            CG._z3_count!(:subprocess, t0)
        end
        lines = filter(!isempty, strip.(split(String(take!(out)), '\n')))
        isempty(lines) && return :error
        return lines[1] == "unsat" ? :unsat : lines[1] == "sat" ? :sat : :error
    catch
        return :error
    finally
        isfile(tmp) && rm(tmp; force = true)
    end
end

function reverify(tree)::Symbol
    try
        sf = SPEC_OBJ.synth_funs[1]
        smt = CG.rulenode_to_smt2(tree, GRAMMAR; context_type = sf.sort == "Bool" ? :bool : :int)
        return z3_detached(CG.generate_cex_query(SPEC_OBJ, Dict(sf.name => smt)))
    catch
        return :error
    end
end

"""
Re-verify with retries. Only `:unsat` (correct) and `:sat` (a counterexample
exists) are verdicts; anything else — z3 failed to start, crashed, printed
nothing — is an infrastructure failure, retried after a GC and a pause, and
reported as such rather than as a verdict. Returns `(status, attempts)`.
"""
function reverify_retry(tree)
    st = :error
    for attempt in 1:REVERIFY_ATTEMPTS
        st = reverify(tree)
        st in (:unsat, :sat) && return (st, attempt)
        GC.gc()
        sleep(2.0 * attempt)
    end
    return (st, REVERIFY_ATTEMPTS)
end

free_mb() = Sys.free_memory() / 2^20

"""Machine-wide CPU ticks (busy, total) summed over every core."""
function cpu_ticks()
    info = Sys.cpu_info()
    busy = sum(c.cpu_times!user + c.cpu_times!nice + c.cpu_times!sys + c.cpu_times!irq for c in info)
    return (busy, busy + sum(c.cpu_times!idle for c in info))
end

cpu_busy_between(a, b) = b[2] > a[2] ? (b[1] - a[1]) / (b[2] - a[2]) : NaN

"""
Memory guard, before the seed's clock starts: collect garbage, then wait while
free memory is below `MIN_FREE_MB` (at most `MEM_WAIT_MAX_S`). Returns
`(free_mb_at_start, seconds_waited)`.
"""
function wait_for_memory()
    GC.gc()
    t = time()
    while free_mb() < MIN_FREE_MB && time() - t < MEM_WAIT_MAX_S
        sleep(5.0)
        GC.gc()
    end
    waited = time() - t
    waited > 1 && println("  waited $(round(waited; digits = 1)) s for memory " *
                          "($(round(Int, free_mb())) MB free)")
    return (free_mb(), waited)
end

tree_depth(n) = isempty(n.children) ? 1 : 1 + maximum(tree_depth, n.children)

function base_row(seed, started)
    return Dict{String,Any}(
        "run" => RUN, "spec" => SPEC, "tier" => SM["tier"], "arm" => MAN["arm"], "seed" => seed,
        "shard" => SHARD, "budget_s" => BUDGET, "pop_size" => SM["pop_size"],
        "val_n" => length(BATTERY), "git_sha" => MAN["git_sha"], "git_dirty" => MAN["git_dirty"],
        "code_sha256" => MAN["code_sha256"], "spec_sha256" => SM["sha256"],
        "arm_hash" => MAN["arm_hash"], "julia_version" => string(VERSION), "started_utc" => started)
end

function run_seed(seed::Int)
    marker = inflight_path(RUN, SPEC, SHARD)
    mem_free, mem_wait = wait_for_memory()
    mkpath(dirname(marker))
    write(marker, string(seed))
    started = utc_now()

    tr = GS.CDGPTrace()
    z0 = CG.z3_stats()
    c0 = cpu_ticks()
    t0 = time()
    res = nothing
    err = ""
    try
        res = run_arm(; seed = seed, trace = tr)
    catch e
        err = sprint(showerror, e)
    end
    elapsed = time() - t0
    cpu_busy = cpu_busy_between(c0, cpu_ticks())   # machine-wide, over the timed search
    zs = CG.z3_stats_diff(CG.z3_stats(), z0)

    row = base_row(seed, started)
    row["sys_free_mb"] = round(Int, mem_free)
    row["mem_wait_s"] = round(mem_wait; digits = 1)
    row["cpu_busy"] = round(cpu_busy; digits = 3)
    if res === nothing
        merge!(row, Dict("status" => "error", "solved" => false, "claimed" => false,
                         "verified" => false, "censored" => true, "time_to_solve_s" => BUDGET,
                         "elapsed_s" => elapsed, "error" => first(err, 500)))
        append_rows(runs_path(RUN, SPEC, SHARD), RUN_COLUMNS, [row])
        rm(marker; force = true)
        return "E"
    end

    claimed = res.solved && res.program !== nothing
    zr0 = CG.z3_stats()
    rev, rev_attempts = claimed ? reverify_retry(res.program.tree) : (:none, 0)
    verified = rev === :unsat
    # A claim the independent check could not judge is an infrastructure
    # failure, not a soundness failure: `error` (dropped from both arms of a
    # comparison), never `unverified`.
    reverify_failed = claimed && !(rev in (:unsat, :sat))
    zrev = CG.z3_stats_diff(CG.z3_stats(), zr0).total

    # Post-hoc validation, outside the timed search.
    tv = time()
    vals = GS.trace_validation(tr, BATTERY)
    final = res.program === nothing ? (acc = NaN, pairs = NaN) : GS.validation_scores(BATTERY, res.program)
    validation_s = time() - tv
    if verified && final.acc != 1.0
        @warn "verified program scores acc=$(final.acc) on the battery — pointwise and SMT semantics disagree" SPEC seed
    end

    solve_t = isnan(tr.solve_elapsed_s) ? elapsed : tr.solve_elapsed_s
    solved = verified && solve_t <= BUDGET
    status = solved ? "solved" : reverify_failed ? "error" :
             (claimed && !verified) ? "unverified" : "censored"

    # ── generation rows ──
    round_stats = Dict(tr.round_end_gen[r] => r for r in eachindex(tr.round_end_gen))
    grows = Vector{Dict{String,Any}}(undef, length(tr))
    for i in 1:length(tr)
        v = get(vals, tr.best_key[i], (acc = NaN, pairs = NaN))
        r = get(round_stats, tr.gen[i], 0)
        zt = tr.z3_constraint_checks[i] + tr.z3_cex_queries[i] + tr.z3_complete_output[i] +
             tr.z3_output_unique[i] + tr.z3_subprocess[i]
        grows[i] = Dict{String,Any}(
            "run" => RUN, "spec" => SPEC, "arm" => MAN["arm"], "seed" => seed,
            "gen" => tr.gen[i], "round" => tr.round[i], "elapsed_s" => round(tr.elapsed_s[i]; digits = 4),
            "best_fitness" => tr.best_fitness[i], "mean_fitness" => tr.mean_fitness[i],
            "best_size" => tr.best_size[i], "tests" => tr.tests[i],
            "incomplete_tests" => tr.incomplete_tests[i], "witnesses" => tr.witnesses[i],
            "solved" => tr.solved[i],
            "z3_constraint_checks" => tr.z3_constraint_checks[i], "z3_cex_queries" => tr.z3_cex_queries[i],
            "z3_complete_output" => tr.z3_complete_output[i], "z3_output_unique" => tr.z3_output_unique[i],
            "z3_subprocess" => tr.z3_subprocess[i],
            "z3_total" => zt, "z3_time_s" => round(tr.z3_time_s[i]; digits = 4),
            "val_acc" => v.acc, "val_pairs" => v.pairs,
            "unique_genomes" => r > 0 ? tr.unique_genomes[r] : nothing,
            "mean_size" => r > 0 ? round(tr.mean_size[r]; digits = 2) : nothing,
            "max_size" => r > 0 ? tr.max_size[r] : nothing)
    end
    append_rows(generations_path(RUN, SPEC, SHARD), GEN_COLUMNS, grows)

    # ── artifact: what this seed produced ──
    prog = res.program
    art = Dict{String,Any}(
        "run" => RUN, "spec" => SPEC, "seed" => seed, "status" => status,
        "verified" => verified, "time_to_solve_s" => solved ? solve_t : nothing,
        "solve_gen" => tr.solve_gen, "generations" => res.generations,
        "program" => res.expr,
        "program_size" => prog === nothing ? nothing : length(prog.tree),
        "val_acc" => final.acc,
        "tests" => [Dict("in" => Dict(String(k) => v for (k, v) in t.in), "out" => t.out)
                    for t in res.test_cases],
        # Inputs only: the spec accepts several outputs there (free-var names).
        "incomplete_tests" => res.incomplete_tests,
        "completion" => Dict(String(k) => v for (k, v) in pairs(res.completion)),
        "harvest" => Dict(String(k) => (v isa Symbol ? String(v) : v) for (k, v) in pairs(res.harvest)),
        "guided" => Dict(String(k) => (v isa Symbol ? String(v) : v) for (k, v) in pairs(res.guided)),
        "witnesses_final" => res.witnesses)
    mkpath(dirname(artifacts_path(RUN, SPEC, SHARD)))
    open(io -> println(io, json(art)), artifacts_path(RUN, SPEC, SHARD), "a")

    # ── run row (written last: marks the seed complete) ──
    merge!(row, Dict{String,Any}(
        "status" => status, "solved" => solved, "claimed" => claimed, "verified" => verified,
        "time_to_solve_s" => solved ? round(solve_t; digits = 4) : BUDGET, "censored" => !solved,
        "elapsed_s" => round(elapsed; digits = 4), "generations" => res.generations,
        "solve_gen" => tr.solve_gen, "rounds" => res.rounds,
        "z3_total" => zs.total, "z3_constraint_checks" => zs.constraint_checks,
        "z3_cex_queries" => zs.cex_queries, "z3_complete_output" => zs.complete_output,
        "z3_output_unique" => zs.output_unique,
        "z3_subprocess" => zs.subprocess, "z3_time_s" => round(zs.time_s; digits = 4),
        "z3_reverify" => zrev,
        # tests_final counts both kinds; incomplete_final is the incomplete subset.
        "tests_final" => length(res.test_cases) + length(res.incomplete_tests),
        "incomplete_final" => length(res.incomplete_tests),
        "single_answer" => res.completion.single_answer,
        "unique_checks" => res.completion.unique_checks,
        "tests_unchecked" => res.completion.unchecked,
        "tests_seeded" => get(res.completion, :seeded, 0),
        "cex_mode" => String(res.harvest.mode), "cex_fallback" => res.harvest.fallback,
        "cex_events" => res.harvest.events, "cex_witnesses" => res.harvest.witnesses,
        "cex_tests_added" => res.harvest.added, "cex_dup" => res.harvest.dup,
        "cex_no_output" => res.harvest.no_output, "cex_capped" => res.harvest.capped,
        "cex_multi_events" => res.harvest.multi_events,
        "cex_max_per_event" => res.harvest.max_per_event,
        "witnesses_final" => res.witnesses,
        "witnesses_evicted" => tr.witnesses_evicted, "harvested" => tr.harvested,
        "guided_mode" => String(res.guided.mode), "guided_attempts" => res.guided.attempts,
        "guided_applied" => res.guided.applied, "guided_analyses" => res.guided.analyses,
        "guided_site_builds" => res.guided.site_builds, "guided_cache_hits" => res.guided.cache_hits,
        "guided_ineligible" => res.guided.ineligible, "guided_no_site" => res.guided.no_site,
        "guided_no_patch" => res.guided.no_patch, "guided_budget_skip" => res.guided.budget_skip,
        "guided_depth_reject" => res.guided.depth_reject, "guided_time_s" => res.guided.time_s,
        "guided_validate_reject" => res.guided.validate_reject,
        "guided_t_evidence" => res.guided.t_evidence, "guided_t_localize" => res.guided.t_localize,
        "guided_t_build" => res.guided.t_build, "guided_t_validate" => res.guided.t_validate,
        "guided_shape_applied" => res.guided.shape_applied, "guided_shape_reject" => res.guided.shape_reject,
        "best_fitness" => res.best_fitness,
        "program_size" => prog === nothing ? nothing : length(prog.tree),
        "program_depth" => prog === nothing ? nothing : tree_depth(prog.tree),
        "val_acc_final" => final.acc, "val_pairs_final" => final.pairs,
        "validation_s" => round(validation_s; digits = 3),
        "rss_mb" => round(Sys.maxrss() / 2^20; digits = 1),
        "reverify_attempts" => rev_attempts,
        "error" => reverify_failed ?
            "re-verification failed after $rev_attempts attempts (z3 status :$rev)" : "",
        "program_expr" => res.expr))
    append_rows(runs_path(RUN, SPEC, SHARD), RUN_COLUMNS, [row])
    rm(marker; force = true)
    return solved ? "." : status == "unverified" ? "U" : status == "error" ? "E" : "x"
end

"""
Compile every hot code path before the first timed seed. Without this, whichever
seed runs first in a process pays for JIT compilation inside its budget
(measured: ~5 s on max2, where later seeds solve in under 0.4 s). Two rounds on
the same spec and arm cover evaluation, Z3 checks, harvesting, the callback and
round-boundary eviction. `run_cdgp` reseeds the RNG on entry, so nothing leaks
into the real seeds; no rows are written.
"""
function warmup()
    t = time()
    try
        tr = GS.CDGPTrace()
        res = run_arm(; seed = 0, max_time = 3.0, generations = 20, trace = tr)
        GS.trace_validation(tr, BATTERY)
        if res.program !== nothing
            reverify(res.program.tree)
            GS.validation_scores(BATTERY, res.program)
        end
    catch e
        @warn "warm-up failed; the first seed may carry compilation time" exception = e
    end
    return time() - t
end

let done = done_seeds(RUN, SPEC)
    todo = filter(s -> !(s in done), SEEDS)
    println("worker $RUN  $SPEC shard $SHARD  arm $(MAN["arm"])  budget $(BUDGET)s  " *
            "seeds todo $(length(todo))/$(length(SEEDS))")
    flush(stdout)
    isempty(todo) || println("  warm-up $(round(warmup(); digits = 1)) s (untimed, discarded)")
    flush(stdout)
    for s in todo
        mark = run_seed(s)
        println("  seed $s $mark"); flush(stdout)
    end
end
