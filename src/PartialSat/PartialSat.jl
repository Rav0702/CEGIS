"""
    module PartialSat

**Guided search through partial specification satisfaction.**

A SyGuS spec is a *conjunction* of constraint predicates (the `(constraint …)`
clauses). The standard CEGIS verifier treats them all-or-nothing: a candidate is
either fully correct or yields a counterexample. This module instead asks *how
many* of the predicates a candidate satisfies, and uses that count as a fitness
signal to guide enumeration and to collect partial programs ("building blocks").

## Three pieces

1. **Evaluation** (`evaluate_partial_satisfaction`) — for each constraint `Cᵢ`,
   ask Z3 whether the candidate satisfies it for *all* inputs. Concretely we
   install the candidate as a `define-fun` and check `(assert (not Cᵢ))`:
   `unsat` ⟹ satisfied, `sat` ⟹ violated (with a witnessing input). The score is
   `#satisfied / #total`. This is sound (each `Cᵢ` is checked universally, not on
   a sample) and answers the user's question — yes, it is a Z3 query, one per
   constraint.

2. **A bank of building blocks** (`PartialSolutionBank`) — partial programs keyed
   by *which subset* of constraints they satisfy, keeping the smallest program
   per subset. `complementary_cover` greedily selects blocks whose satisfied-sets
   union to the whole spec — candidate ingredients for a complete solution.

3. **Guided search** (`guided_partial_search`) — enumerate with any
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

export PartialSatResult, PartialSolutionBank, BankEntry,
       evaluate_partial_satisfaction, candidate_exprs_from_rulenode,
       record!, building_blocks, complementary_cover, guided_partial_search,
       collect_satisfying, SeededCostBUIterator

# ─────────────────────────────────────────────────────────────────────────────
# Evaluation
# ─────────────────────────────────────────────────────────────────────────────

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
expect, via the direct `RuleNode → SMT-LIB2` converter. Assumes a single
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
    evaluate_partial_satisfaction(spec, grammar, program; verbose=false) :: PartialSatResult

Convenience overload that converts a candidate `RuleNode` to SMT first.
"""
function evaluate_partial_satisfaction(spec::CEXGeneration.Spec,
                                       grammar::AbstractGrammar,
                                       program::AbstractRuleNode;
                                       verbose::Bool=false)::PartialSatResult
    return evaluate_partial_satisfaction(spec, candidate_exprs_from_rulenode(spec, grammar, program); verbose)
end

# ─────────────────────────────────────────────────────────────────────────────
# Building-block bank
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# Guided search
# ─────────────────────────────────────────────────────────────────────────────

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
                               verbose::Bool=true,
                               log_every::Int=0)
    bank = PartialSolutionBank(length(spec.constraints))
    full = nothing
    n = 0
    best_seen = -1
    n_skipped = 0
    n_unknown = 0

    for program in iterator
        n += 1
        n > max_enumerations && break

        exprs = try
            candidate_exprs_from_rulenode(spec, grammar, program)
        catch e
            n_skipped += 1
            verbose && @warn "skipping uncoercible candidate at enum $n" exception = e
            continue
        end
        result = evaluate_partial_satisfaction(spec, exprs)
        readable = rulenode2expr(program, grammar)
        entry = record!(bank, program, readable, result)

        unknowns = unknown_indices(result)
        if !isempty(unknowns)
            n_unknown += length(unknowns)
            verbose && @warn "Z3 returned `unknown` — these constraints were not decided" enum = n constraints = unknowns program = readable
        end

        if log_every > 0 && n % log_every == 0
            println("[enum $n] score $(result.n_satisfied)/$(result.n_total)  $readable")
        end

        if result.n_satisfied > best_seen
            best_seen = result.n_satisfied
            if verbose
                println("[enum $n] new best: $(result.n_satisfied)/$(result.n_total)  $readable")
                print(_format_breakdown(spec, result))
            end
        end

        if is_full(result)
            full = entry
            if verbose
                println("[enum $n] FULL solution: $readable  (Z3-verified $(result.n_satisfied)/$(result.n_total))")
                print(_format_breakdown(spec, result))
            end
            break
        end
    end

    verbose && println("[done] enumerated=$n  skipped=$n_skipped  unknown-checks=$n_unknown  banked-subsets=$(length(bank.by_subset))")
    return (; full, bank, enumerated = n, skipped = n_skipped, unknown_checks = n_unknown)
end

# Seeded bottom-up iterator: build new programs on top of collected partials.
include("SeededBottomUp.jl")

end # module PartialSat
