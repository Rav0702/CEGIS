"""
    z3_stats.jl

Process-wide accounting of every Z3 call this module makes, broken down by the
kind of work, so benchmarks can report solver cost exactly rather than through
whatever counter an individual evaluator happens to keep.

All in-process solver work funnels through five sites — the per-constraint
`check-sat-assuming` (`_csat_check_assuming`), `find_counterexample`,
`complete_output`, the output-uniqueness queries (`output_is_unique`,
`spec_single_answer`) — and every subprocess query through `_z3_exec`. Counting at
those sites catches every caller, including ones that no evaluator owns (a
harness's out-of-process re-verification, for instance).

The counters are plain fields, not atomics: the GA evaluators run with
`parallel=false` because they mutate shared state, and a benchmark worker runs
one search at a time. To attribute calls to one run, snapshot with `z3_stats()`
before and after it and subtract (`z3_stats_diff`).
"""

"""Cumulative Z3 call counts for this process, by kind of work."""
mutable struct Z3CallStats
    constraint_checks::Int   # one per per-constraint check-sat-assuming (ConstraintSatSolver)
    cex_queries::Int         # one per in-process counterexample search (CexSolver)
    complete_output::Int     # one per output-completion query (turning a witness into a test)
    output_unique::Int       # one per uniqueness query (complete vs incomplete test; spec single-answer check)
    subprocess::Int          # one per `z3` binary invocation (verify_query and friends)
    time_s::Float64          # wall-clock spent inside all of the above
end

const _Z3_STATS = Z3CallStats(0, 0, 0, 0, 0, 0.0)

"""
    z3_stats() -> NamedTuple

Snapshot of the process-wide Z3 counters. `total` sums the five call kinds.
"""
function z3_stats()
    s = _Z3_STATS
    return (constraint_checks = s.constraint_checks, cex_queries = s.cex_queries,
            complete_output = s.complete_output, output_unique = s.output_unique,
            subprocess = s.subprocess,
            total = s.constraint_checks + s.cex_queries + s.complete_output +
                    s.output_unique + s.subprocess,
            time_s = s.time_s)
end

"""
    z3_stats_diff(after, before) -> NamedTuple

Calls made between two `z3_stats()` snapshots.
"""
z3_stats_diff(a, b) = (constraint_checks = a.constraint_checks - b.constraint_checks,
                       cex_queries = a.cex_queries - b.cex_queries,
                       complete_output = a.complete_output - b.complete_output,
                       output_unique = a.output_unique - b.output_unique,
                       subprocess = a.subprocess - b.subprocess,
                       total = a.total - b.total,
                       time_s = a.time_s - b.time_s)

"""Zero every counter (for tests; benchmarks should diff snapshots instead)."""
function reset_z3_stats!()
    s = _Z3_STATS
    s.constraint_checks = 0
    s.cex_queries = 0
    s.complete_output = 0
    s.output_unique = 0
    s.subprocess = 0
    s.time_s = 0.0
    return nothing
end

"""Record one call of `kind` that started at `t0 = time_ns()`."""
@inline function _z3_count!(kind::Symbol, t0::UInt64)
    s = _Z3_STATS
    if kind === :constraint_checks
        s.constraint_checks += 1
    elseif kind === :cex_queries
        s.cex_queries += 1
    elseif kind === :complete_output
        s.complete_output += 1
    elseif kind === :output_unique
        s.output_unique += 1
    else
        s.subprocess += 1
    end
    s.time_s += (time_ns() - t0) / 1e9
    return nothing
end
