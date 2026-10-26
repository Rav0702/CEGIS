#=
bench/run.jl — run ONE arm over a suite of specs and store it as a named run.

    julia bench/run.jl --arm baseline-cdgp --suite core --seeds 1:66
    julia bench/run.jl --arm hybrid-nowit  --suite core --seeds 1:66
    bench/.venv/Scripts/python bench/diagnose.py baseline-cdgp hybrid-nowit

Options
  --arm NAME        an entry of ARMS in bench/common.jl                (required)
  --name NAME       run directory name (default: the arm name)
  --suite NAME      quick | core | b | full      (or --specs a,b,c; exactly one)
  --seeds 1:66      seed list; the same seeds must be used for runs you compare
  --jobs 4          parallel workers — keep this THE SAME across runs you compare:
                    budgets are wall-clock, so more parallel load means less compute.
                    On the 12-thread dev machine 4 is the sweet spot: 2 -> 4 costs no
                    per-seed speed, 4 -> 6 costs ~50% (max5: 153 -> 227 ms/generation)
                    and so buys no throughput while changing solve rates (74% -> 50%).
  --shards auto     workers per spec (auto: enough to fill --jobs)
  --set k=v,...     override arm keywords for a one-off idea, e.g.
                    --set witness_test_ratio=0.3   (use with --name)
  --budget S        override every spec's registry budget (seconds)
  --depth-cap N     override every spec's registry depth cap (recorded in the manifest; runs with
                    different caps do not pair in diagnose.py)
  --val-n 256       validation battery size
  --variant NAME    run every spec with its grammar variant spec_files/enriched/<stem>_NAME.sl
                    (scripts/gen_enriched_grammars.jl: `case` = recipes as productions, `decoy` =
                    placebo); keys and settings stay the registry's, so seeds pair with plain runs

Re-running the same command RESUMES the run: finished seeds are skipped. A run
refuses to resume under a different arm configuration, spec file, budget, or
source tree (`--allow-code-change true` overrides the last, and marks the run so
the comparison warns) — otherwise one run would silently mix two versions of the
algorithm.

A crash (a Z3 in-process abort kills the process with no Julia exception) costs
one seed: the worker writes the seed it is about to run to an inflight marker,
and this supervisor records that seed as `crashed` and relaunches the worker.
=#

include(joinpath(@__DIR__, "common.jl"))

const OPTS = parse_cli(ARGS, Dict(
    "arm" => "", "name" => "", "suite" => "", "specs" => "", "seeds" => "1:30",
    "jobs" => "4", "shards" => "auto", "set" => "", "budget" => "", "val-n" => "256",
    "allow-code-change" => "false", "julia" => Base.julia_cmd().exec[1], "variant" => "", "depth-cap" => ""))

function fail(msg)
    printstyled("error: ", color = :red, bold = true)
    println(msg)
    exit(2)
end

const ARM = OPTS["arm"]
isempty(ARM) && fail("--arm is required (one of: $(join(sort(collect(keys(ARMS))), ", ")))")
haskey(ARMS, ARM) || fail("unknown arm `$ARM`; known: $(join(sort(collect(keys(ARMS))), ", "))")
const CFG = merge(ARMS[ARM], (; parse_overrides(OPTS["set"])...))
const NAME = isempty(OPTS["name"]) ? ARM : OPTS["name"]
occursin(r"^[A-Za-z0-9._+-]+$", NAME) || fail("--name may contain only letters, digits, . _ + -")
if !isempty(OPTS["set"]) && isempty(OPTS["name"])
    fail("--set changes the arm; give the run its own --name so it cannot be confused with `$ARM`")
end

const SPEC_NAMES = if !isempty(OPTS["suite"]) && !isempty(OPTS["specs"])
    fail("use --suite or --specs, not both")
elseif !isempty(OPTS["suite"])
    haskey(SUITES, OPTS["suite"]) || fail("unknown suite; known: $(join(sort(collect(keys(SUITES))), ", "))")
    SUITES[OPTS["suite"]]
elseif !isempty(OPTS["specs"])
    String.(split(OPTS["specs"], ","))
else
    fail("give --suite (quick | core | b | full) or --specs a,b")
end
for s in SPEC_NAMES
    haskey(SPECS, s) || fail("unknown spec `$s`")
end
const SEEDS = parse_seeds(OPTS["seeds"])
const NJOBS = parse(Int, OPTS["jobs"])
const NSHARDS = OPTS["shards"] == "auto" ? max(1, cld(NJOBS, length(SPEC_NAMES))) : parse(Int, OPTS["shards"])
const VAL_N = parse(Int, OPTS["val-n"])

# ── manifest: create, or check compatibility and extend ──────────────────────

function spec_entry(s)
    sp = SPECS[s]
    path = isempty(OPTS["variant"]) ? sp.path : variant_path(sp.path, OPTS["variant"])
    isfile(joinpath(CEGIS_ROOT, path)) || fail("spec `$s` has no `$(OPTS["variant"])` variant ($path)")
    e = Dict{String,Any}(
        "path" => path, "tier" => String(sp.tier),
        "budget" => isempty(OPTS["budget"]) ? sp.budget : parse(Float64, OPTS["budget"]),
        "pop_size" => sp.pop_size, "max_depth" => sp.max_depth,
        "depth_cap" => isempty(OPTS["depth-cap"]) ? sp.depth_cap : parse(Int, OPTS["depth-cap"]),
        "calibrated" => sp.calibrated, "sha256" => bytes2hex(open(sha256, joinpath(CEGIS_ROOT, path))))
    isempty(OPTS["variant"]) || (e["variant"] = OPTS["variant"])
    return e
end

function prepare_manifest()
    code = code_sha256()
    prov = git_provenance()
    ahash = arm_hash(CFG)
    path = manifest_path(NAME)
    if isfile(path)
        man = TOML.parsefile(path)
        man["arm_hash"] == ahash ||
            fail("run `$NAME` was made with a different arm configuration " *
                 "($(man["arm_hash"]) vs $ahash). Use --name to start a new run.")
        if man["code_sha256"] != code
            OPTS["allow-code-change"] == "true" ||
                fail("run `$NAME` was made with different source code " *
                     "($(man["code_sha256"]) vs $code). Use --name to start a new run " *
                     "(or --allow-code-change true to continue this one anyway; the comparison will warn).")
            man["code_changed_during_run"] = true
        end
        Int(man["val_n"]) == VAL_N || fail("run `$NAME` used --val-n $(man["val_n"])")
        for s in SPEC_NAMES
            new = spec_entry(s)
            if haskey(man["specs"], s)
                old = man["specs"][s]
                for k in ("sha256", "budget", "pop_size", "max_depth", "depth_cap")
                    old[k] == new[k] || fail("spec `$s` differs from when run `$NAME` started " *
                                             "($k: $(old[k]) vs $(new[k])). Use --name to start a new run.")
                end
            else
                man["specs"][s] = new
            end
        end
        Int(man["jobs"]) == NJOBS || (man["mixed_jobs"] = true)
    else
        man = Dict{String,Any}(
            "name" => NAME, "arm" => ARM, "arm_hash" => ahash, "arm_config" => encode_cfg(CFG),
            "code_sha256" => code, "git_sha" => prov.git_sha, "git_dirty" => prov.git_dirty,
            "julia_version" => string(VERSION), "host" => hostname(),
            "cpu_threads" => Sys.CPU_THREADS, "jobs" => NJOBS, "val_n" => VAL_N,
            "created_utc" => utc_now(), "code_changed_during_run" => false, "mixed_jobs" => false,
            "specs" => Dict{String,Any}(s => spec_entry(s) for s in SPEC_NAMES))
    end
    mkpath(run_dir(NAME))
    open(io -> TOML.print(io, man; sorted = true), path, "w")
    open(joinpath(run_dir(NAME), "sessions.log"), "a") do io
        println(io, "$(utc_now())  specs=$(join(SPEC_NAMES, ","))  seeds=$(OPTS["seeds"])  " *
                    "jobs=$NJOBS  shards=$NSHARDS  code=$code  git=$(first(prov.git_sha, 10))" *
                    "$(prov.git_dirty ? "+dirty" : "")")
    end
    return man
end

# ── scheduling ───────────────────────────────────────────────────────────────

"""Round-robin seed assignment: stable for a given seed list and shard count."""
shard_seeds(k) = [s for (i, s) in enumerate(SEEDS) if (i - 1) % NSHARDS + 1 == k]
remaining(spec, k) = filter(s -> !(s in done_seeds(NAME, spec)), shard_seeds(k))

const WORKER = joinpath(@__DIR__, "worker.jl")

function launch(spec, k)
    todo = remaining(spec, k)
    isempty(todo) && return nothing
    mkpath(dirname(log_path(NAME, spec, k)))
    io = open(log_path(NAME, spec, k), "a")
    args = ["--run", NAME, "--spec", spec, "--shard", string(k), "--seeds", join(todo, ",")]
    cmd = Cmd(`$(OPTS["julia"]) --project=$CEGIS_ROOT $WORKER $args`; dir = CEGIS_ROOT)
    return (proc = run(pipeline(cmd; stdout = io, stderr = io); wait = false),
            io = io, spec = spec, shard = k)
end

function summarise(man)
    println("\n$(rpad("spec", 16)) $(lpad("seeds", 5)) $(lpad("solved", 7)) $(lpad("rate", 5))  " *
            "$(lpad("crashed", 7)) $(lpad("error", 5))  budget")
    for s in SPEC_NAMES
        lines = String[]
        for f in spec_run_files(NAME, s)
            append!(lines, collect(eachline(f))[2:end])
        end
        n = length(lines)
        st(x) = count(l -> occursin(",$x,", l), lines)
        ns = st("solved")
        println("$(rpad(s, 16)) $(lpad(n, 5)) $(lpad(ns, 7)) $(lpad(n == 0 ? "-" : "$(round(Int, 100ns / n))%", 5))  " *
                "$(lpad(st("crashed"), 7)) $(lpad(st("error"), 5))  $(man["specs"][s]["budget"]) s")
    end
    println("\nstored in $(relpath(run_dir(NAME), CEGIS_ROOT))")
    println("report:   bench/.venv/Scripts/python bench/diagnose.py $NAME")
    println("compare:  bench/.venv/Scripts/python bench/diagnose.py <baseline-run> $NAME")
end

function main()
    man = prepare_manifest()
    groups = [(s, k) for s in SPEC_NAMES for k in 1:NSHARDS]
    total = length(SPEC_NAMES) * length(SEEDS)
    todo = sum(length(remaining(s, k)) for (s, k) in groups; init = 0)
    println("run $NAME  arm $ARM ($(man["arm_hash"]))  code $(man["code_sha256"])")
    println("  specs $(join(SPEC_NAMES, ", "))  ·  $(length(SEEDS)) seeds  ·  " *
            "$todo of $total runs to do  ·  $NJOBS jobs, $NSHARDS shard(s) per spec")
    flush(stdout)

    queue = copy(groups)
    running = []
    failures = Dict{Tuple{String,Int},Int}()
    while !isempty(queue) || !isempty(running)
        while length(running) < NJOBS && !isempty(queue)
            (s, k) = popfirst!(queue)
            job = launch(s, k)
            job === nothing || push!(running, job)
        end
        sleep(2)
        for job in copy(running)
            process_running(job.proc) && continue
            filter!(j -> j !== job, running)
            close(job.io)
            key = (job.spec, job.shard)
            marker = inflight_path(NAME, job.spec, job.shard)
            if isfile(marker)
                seed = parse(Int, strip(read(marker, String)))
                append_rows(runs_path(NAME, job.spec, job.shard), RUN_COLUMNS,
                            [crashed_row(NAME, job.spec, job.shard, seed, man;
                                         note = "worker exited (code $(job.proc.exitcode)) while running this seed")])
                rm(marker; force = true)
                println("  CRASH  $(job.spec) seed $seed (exit $(job.proc.exitcode)) — recorded, resuming")
                push!(queue, key)
            elseif job.proc.exitcode != 0
                n = failures[key] = get(failures, key, 0) + 1
                if n <= 2
                    println("  worker $(job.spec)/s$(job.shard) failed to start (exit $(job.proc.exitcode)); retry $n/2")
                    push!(queue, key)
                else
                    println("  GIVING UP on $(job.spec)/s$(job.shard) — see $(log_path(NAME, job.spec, job.shard))")
                end
            elseif !isempty(remaining(job.spec, job.shard))
                push!(queue, key)
            end
            flush(stdout)
        end
    end
    open(joinpath(run_dir(NAME), "sessions.log"), "a") do io
        println(io, "$(utc_now())  finished")
    end
    summarise(man)
end

main()
