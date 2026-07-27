"""
    module PartialSat

Guided search through partial specification satisfaction.

A SyGuS spec is a *conjunction* of constraint predicates (the `(constraint …)`
clauses). The standard CEGIS verifier treats them all-or-nothing: a candidate is
either fully correct or yields a counterexample. This module instead asks *how
many* of the predicates a candidate satisfies, and uses that count as a fitness
signal to guide enumeration and to collect partial programs ("building blocks").

Three pieces:

1. Evaluation (`evaluate_partial_satisfaction`) — for each constraint `Ci`,
   ask Z3 whether the candidate satisfies it for *all* inputs. Concretely we
   install the candidate as a `define-fun` and check `(assert (not Ci))`:
   `unsat` => satisfied, `sat` => violated (with a witnessing input). The score is
   `#satisfied / #total`. This is sound: each `Ci` is checked universally (one Z3
   query per constraint), not on a sample.

2. A bank of building blocks (`PartialSolutionBank`) — partial programs keyed
   by *which subset* of constraints they satisfy, keeping the smallest program
   per subset. `complementary_cover` greedily selects blocks whose satisfied-sets
   union to the whole spec — candidate ingredients for a complete solution.

3. Guided search (`guided_partial_search`) — enumerate with any
   `ProgramIterator`, score every candidate, bank the partial ones, and stop when
   one satisfies every constraint.

The partial-satisfaction score is a *building-block* metric: it identifies
programs that get part of the job right (e.g. one branch of a `max`). How to
recombine them automatically is open; `complementary_cover` exposes the raw
material, and the score can drive a fitness-directed iterator.
"""
module PartialSat

using HerbCore
using HerbGrammar
using HerbConstraints
using HerbSearch
using ..CEXGeneration

# Stage timers (populated per `guided_partial_search` round). `check_tree` time is
# accumulated inside the constraint-aware `add_to_bank!` override (SeededBottomUp.jl);
# enumeration and Z3-scoring time are accumulated in the search loop below.
const CHECK_TREE_TIME  = Ref(0.0)   # seconds spent in HerbConstraints.check_tree
const CHECK_TREE_CALLS = Ref(0)     # number of programs constraint-checked before banking
const CHECK_TREE_PRUNED = Ref(0)    # programs rejected from the bank by a constraint

export PartialSatResult, PartialSolutionBank, BankEntry,
       evaluate_partial_satisfaction, candidate_exprs_from_rulenode,
       record!, building_blocks, complementary_cover, guided_partial_search,
       collect_satisfying, SeededCostBUIterator

# -----------------------------------------------------------------------------
# Evaluation
# -----------------------------------------------------------------------------

"""
    PartialSatResult

Outcome of evaluating a candidate against each spec constraint.

- `n_total` — number of constraints in the spec.
- `n_satisfied` — how many hold for *all* inputs.
- `satisfied` — per-constraint flags, in `spec.constraints` order.
- `violating_inputs` — for each unsatisfied constraint, a Z3 model (input that
  violates it) or `nothing` if Z3 returned `unknown`/no model.
- `score` — `n_satisfied / n_total` (1.0 for a spec with no constraints).
"""
struct PartialSatResult
    n_total::Int
    n_satisfied::Int
    satisfied::Vector{Bool}
    violating_inputs::Vector{Union{Nothing,Dict{String,Any}}}
    score::Float64
end

is_full(r::PartialSatResult) = r.n_total > 0 && r.n_satisfied == r.n_total

"Constraint indices where Z3 returned `unknown` (neither proven satisfied nor a violating input found)."
unknown_indices(r::PartialSatResult) =
    [i for i in 1:r.n_total if !r.satisfied[i] && r.violating_inputs[i] === nothing]

"Per-constraint status line: ✓ satisfied, ✗ violated (with witnessing input), ? unknown."
function _format_breakdown(spec::CEXGeneration.Spec, r::PartialSatResult)::String
    io = IOBuffer()
    for i in 1:r.n_total
        mark = r.satisfied[i] ? "✓" : (r.violating_inputs[i] === nothing ? "?" : "✗")
        suffix = (mark == "✗" && r.violating_inputs[i] !== nothing) ? "   (violated at $(r.violating_inputs[i]))" : ""
        println(io, "        [$mark] C$i: $(spec.constraints[i])$suffix")
    end
    return String(take!(io))
end

"""
    candidate_exprs_from_rulenode(spec, grammar, program) :: Dict{String,String}

Convert a candidate `program` to the `func_name => SMT-LIB2` dict the queries
expect, via the direct `RuleNode -> SMT-LIB2` converter. Assumes a single
synthesis function (the common SyGuS case); maps it to the first `synth-fun`.
"""
function candidate_exprs_from_rulenode(spec::CEXGeneration.Spec,
                                       grammar::AbstractGrammar,
                                       program::AbstractRuleNode)::Dict{String,String}
    isempty(spec.synth_funs) && error("spec has no synth-fun to map the candidate to")
    func = spec.synth_funs[1].name
    return Dict(func => CEXGeneration.rulenode_to_smt2(program, grammar))
end

"""
    evaluate_partial_satisfaction(spec, candidate_exprs; verbose=false) :: PartialSatResult

Run one Z3 query per constraint and count how many the candidate satisfies for
all inputs. `candidate_exprs` maps each synth-fun name to its SMT-LIB2 body.
"""
function evaluate_partial_satisfaction(spec::CEXGeneration.Spec,
                                       candidate_exprs::Dict{String,String};
                                       verbose::Bool=false)::PartialSatResult
    constraints = spec.constraints
    n = length(constraints)
    satisfied = falses(n)
    violating = Vector{Union{Nothing,Dict{String,Any}}}(nothing, n)

    for (i, c) in enumerate(constraints)
        query = CEXGeneration.generate_partial_sat_query(spec, candidate_exprs, c)
        result = try
            CEXGeneration.verify_query(query)
        catch e
            verbose && @warn "partial-sat query failed for constraint $i" exception = e
            CEXGeneration.Z3Result(:unknown, Dict{String,Any}(), String[])
        end
        if result.status == :unsat
            satisfied[i] = true
        elseif result.status == :sat
            violating[i] = result.model
        end
        verbose && println("  constraint $i: $(result.status == :unsat ? "✓ satisfied" : result.status == :sat ? "✗ violated" : "? unknown")  —  $c")
    end

    ns = count(satisfied)
    return PartialSatResult(n, ns, satisfied, violating, n == 0 ? 1.0 : ns / n)
end

"""
    evaluate_partial_satisfaction(css::CEXGeneration.ConstraintSatSolver, candidate_exprs) :: PartialSatResult

Fast path: score via the persistent in-process `ConstraintSatSolver` (one
`check-sat-assuming` per constraint, no subprocess). Violating inputs are not
extracted on this path; a violated constraint gets an empty model dict so it is
counted as violated (not unknown).
"""
function evaluate_partial_satisfaction(css::CEXGeneration.ConstraintSatSolver,
                                       candidate_exprs::Dict{String,String})::PartialSatResult
    r = CEXGeneration.check_constraint_satisfaction(css, candidate_exprs)
    n = length(r.constraints)
    violating = Vector{Union{Nothing,Dict{String,Any}}}(nothing, n)
    for i in 1:n
        r.status[i] == :sat && (violating[i] = Dict{String,Any}())
    end
    ns = count(r.satisfied)
    return PartialSatResult(n, ns, collect(r.satisfied), violating, n == 0 ? 1.0 : ns / n)
end

"""
    evaluate_partial_satisfaction(spec, grammar, program; verbose=false) :: PartialSatResult

Convenience overload that converts a candidate `RuleNode` to SMT first.
"""
function evaluate_partial_satisfaction(spec::CEXGeneration.Spec,
                                       grammar::AbstractGrammar,
                                       program::AbstractRuleNode;
                                       verbose::Bool=false)::PartialSatResult
    return evaluate_partial_satisfaction(spec, candidate_exprs_from_rulenode(spec, grammar, program); verbose)
end

# -----------------------------------------------------------------------------
# Building-block bank
# -----------------------------------------------------------------------------

"""
A banked partial program: the program, its readable form, its node count, and
the `PartialSatResult` that earned it a place.
"""
struct BankEntry
    program::AbstractRuleNode
    expr::Any
    size::Int
    result::PartialSatResult
end

"""
    PartialSolutionBank

Keeps, for each *distinct subset* of satisfied constraints, the smallest program
that achieves it — the building blocks. `best` tracks the highest-scoring (then
smallest) program seen overall.
"""
mutable struct PartialSolutionBank
    n_total::Int
    by_subset::Dict{Vector{Int},BankEntry}
    best::Union{Nothing,BankEntry}
end

PartialSolutionBank(n_total::Int) =
    PartialSolutionBank(n_total, Dict{Vector{Int},BankEntry}(), nothing)

_node_count(p::AbstractRuleNode) = try
    length(p)
catch
    typemax(Int)
end

"""
    record!(bank, program, expr, result) :: BankEntry

Insert a scored program. It is kept iff it is the smallest program yet seen for
its satisfied-subset. Updates `bank.best`. Returns the entry built for it.
"""
function record!(bank::PartialSolutionBank, program::AbstractRuleNode, expr, result::PartialSatResult)::BankEntry
    entry = BankEntry(program, expr, _node_count(program), result)
    key = findall(result.satisfied)

    current = get(bank.by_subset, key, nothing)
    if current === nothing || entry.size < current.size
        bank.by_subset[key] = entry
    end

    if bank.best === nothing ||
       result.n_satisfied > bank.best.result.n_satisfied ||
       (result.n_satisfied == bank.best.result.n_satisfied && entry.size < bank.best.size)
        bank.best = entry
    end
    return entry
end

"""
    building_blocks(bank) :: Vector{BankEntry}

All banked partial programs, best first (more constraints satisfied, then
smaller). One representative per satisfied-subset.
"""
building_blocks(bank::PartialSolutionBank) =
    sort(collect(values(bank.by_subset)); by = e -> (-e.result.n_satisfied, e.size))

"""
    collect_satisfying(bank; threshold=0.5, composite_only=true) :: Vector{RuleNode}

The banked programs whose partial-satisfaction score is `≥ threshold` (default
half the constraints), as `RuleNode`s ready to seed a `SeededCostBUIterator`.
`composite_only` (default `true`) drops size-1 programs — bare terminals are
already in any bottom-up bank, so only non-trivial building blocks are returned.
"""
function collect_satisfying(bank::PartialSolutionBank; threshold::Real=0.5, composite_only::Bool=true)::Vector{RuleNode}
    out = RuleNode[]
    for e in values(bank.by_subset)
        e.result.score >= threshold || continue
        composite_only && e.size <= 1 && continue
        e.program isa RuleNode && push!(out, e.program)
    end
    return out
end

"""
    complementary_cover(bank) :: Union{Nothing,Vector{BankEntry}}

Greedy set cover over banked blocks: repeatedly pick the block adding the most
not-yet-covered constraints until all are covered. Returns the chosen blocks, or
`nothing` if the banked blocks cannot jointly cover the spec. These are the
"ingredients" whose behaviors, combined, would satisfy every predicate.
"""
function complementary_cover(bank::PartialSolutionBank)::Union{Nothing,Vector{BankEntry}}
    bank.n_total == 0 && return BankEntry[]
    covered = Set{Int}()
    chosen = BankEntry[]
    entries = collect(values(bank.by_subset))
    while length(covered) < bank.n_total
        best_entry = nothing
        best_gain = 0
        for e in entries
            gain = count(i -> !(i in covered), findall(e.result.satisfied))
            if gain > best_gain
                best_gain = gain
                best_entry = e
            end
        end
        best_entry === nothing && return nothing   # no progress possible
        push!(chosen, best_entry)
        union!(covered, findall(best_entry.result.satisfied))
    end
    return chosen
end

# -----------------------------------------------------------------------------
# Guided search
# -----------------------------------------------------------------------------

"""
    guided_partial_search(spec, grammar, iterator; max_enumerations=10_000, verbose=true, log_every=0)

Enumerate candidates from `iterator`, score each by partial satisfaction, bank
the partial programs, and stop at the first candidate that satisfies *every*
constraint.

Intermediate logging (when `verbose`): each new best and the full solution print
their per-constraint breakdown (✓/✗/?), Z3 `unknown` results are surfaced as
warnings, and `log_every > 0` prints a progress line every `log_every`
candidates. A final summary reports enumerations, skips, and total unknown checks
so you can confirm every constraint was actually decided by Z3.

Returns `(; full, bank, enumerated, skipped, unknown_checks)` where `full` is the
`BankEntry` of a complete solution (or `nothing`), and `bank` is the
`PartialSolutionBank` of building blocks.
"""
function guided_partial_search(spec::CEXGeneration.Spec,
                               grammar::AbstractGrammar,
                               iterator;
                               max_enumerations::Int=10_000,
                               max_time::Float64=Inf,
                               verbose::Bool=false,
                               log_every::Int=0,
                               csat_solver=nothing,
                               bank::Union{Nothing,PartialSolutionBank}=nothing,
                               seen::Union{Nothing,Set{String}}=nothing)
    bank = bank === nothing ? PartialSolutionBank(length(spec.constraints)) : bank
    full = nothing
    n = 0
    scored = 0
    best_seen = bank.best === nothing ? -1 : bank.best.result.n_satisfied
    n_skipped = 0
    n_unknown = 0
    n_subsets_before = length(bank.by_subset)
    last_scored_log = 0
    start_time = time()

    # Per-round stage timers. `t_enum` covers the iterator step (combine + bank +
    # observational-equivalence + the constraint-aware add_to_bank!); `t_score`
    # covers Z3 partial-satisfaction scoring; check_tree time/counts live in the
    # module-level Refs, reset here so each round reports its own numbers.
    t_enum = 0.0
    t_score = 0.0
    CHECK_TREE_TIME[] = 0.0
    CHECK_TREE_CALLS[] = 0
    CHECK_TREE_PRUNED[] = 0

    _t = time(); itstate = iterate(iterator); t_enum += time() - _t
    while itstate !== nothing
        program, state = itstate
        n += 1
        if n > max_enumerations || time() - start_time > max_time
            break
        end

        exprs = try
            candidate_exprs_from_rulenode(spec, grammar, program)
        catch
            n_skipped += 1
            _t = time(); itstate = iterate(iterator, state); t_enum += time() - _t
            continue
        end

        # Skip candidates already scored in a previous round.
        if seen !== nothing
            body = first(values(exprs))
            if body in seen
                _t = time(); itstate = iterate(iterator, state); t_enum += time() - _t
                continue
            end
            push!(seen, body)
        end

        _ts = time()
        result = csat_solver === nothing ?
            evaluate_partial_satisfaction(spec, exprs) :
            evaluate_partial_satisfaction(csat_solver, exprs)
        t_score += time() - _ts
        scored += 1
        readable = rulenode2expr(program, grammar)
        subsets_before_record = length(bank.by_subset)
        entry = record!(bank, freeze_state(program), readable, result)
        new_subset = length(bank.by_subset) > subsets_before_record

        n_unknown += length(unknown_indices(result))

        # Periodic progress: enumerated vs. scored (scored excludes seen/skipped),
        # current best, bank growth, throughput, and the candidate under inspection.
        if log_every > 0 && n % log_every == 0
            rate = scored > 0 ? round(scored / max(time() - start_time, 1e-6), digits=1) : 0.0
            println("  [enum $n] scored=$scored (Δ$(scored - last_scored_log)) best=$(best_seen)/$(result.n_total) " *
                    "subsets=$(length(bank.by_subset)) $(rate)/s  elapsed=$(round(time() - start_time, digits=1))s  ~ $readable")
            last_scored_log = scored
            flush(stdout)
        end

        # A genuinely new satisfied-subset that isn't a new record still tells us the
        # bank is diversifying — log it under verbose so seeding decisions are traceable.
        if verbose && new_subset && result.n_satisfied >= 1 && result.n_satisfied <= best_seen
            println("  [enum $n] banked subset $(findall(result.satisfied)) ($(result.n_satisfied)/$(result.n_total)) size=$(entry.size)  $readable")
            flush(stdout)
        end

        if result.n_satisfied > best_seen
            best_seen = result.n_satisfied
            if verbose
                println("  [enum $n] ★ new best $(result.n_satisfied)/$(result.n_total)  size=$(entry.size)  $readable")
                print(_format_breakdown(spec, result))
                flush(stdout)
            end
        end

        if is_full(result)
            full = entry
            println("  [enum $n] ✔ FULL solution: $readable  ($(result.n_satisfied)/$(result.n_total) constraints, Z3-verified universally)")
            flush(stdout)
            break
        end

        _t = time(); itstate = iterate(iterator, state); t_enum += time() - _t
    end

    if verbose
        total = max(time() - start_time, 1e-9)
        ct = CHECK_TREE_TIME[]
        println("  [round done] enumerated=$n scored=$scored skipped=$n_skipped unknown-checks=$n_unknown " *
                "banked-subsets=$(length(bank.by_subset)) (+$(length(bank.by_subset) - n_subsets_before))  " *
                "time=$(round(total, digits=1))s")
        println("  [stage timers] enumerate/bank=$(round(t_enum, digits=1))s ($(round(100t_enum/total))%)  " *
                "z3-score=$(round(t_score, digits=1))s ($(round(100t_score/total))%)  " *
                "check_tree=$(round(ct, digits=2))s ($(round(100ct/total; digits=1))%) over $(CHECK_TREE_CALLS[]) calls, pruned $(CHECK_TREE_PRUNED[]) from bank")
        flush(stdout)
    end
    return (; full, bank, enumerated = n, scored, skipped = n_skipped, unknown_checks = n_unknown)
end

# Seeded bottom-up iterator: build new programs on top of collected partials.
include("SeededBottomUp.jl")

end # module PartialSat
