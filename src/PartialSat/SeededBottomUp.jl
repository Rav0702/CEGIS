"""
    SeededBottomUp.jl

Seeding a bottom-up iterator's bank with externally-collected programs.

HerbSearch's bottom-up iterators build new programs by combining the ones in
their *bank*, but `populate_bank!` natively seeds only the grammar's terminals.
This file adds the missing piece: a `CostBasedBottomUpIterator` subtype whose
bank is also pre-loaded with `seed_programs` (e.g. the partial solutions that
satisfy ≥ half the spec constraints, from `collect_satisfying`). The inherited
`combine` step then assembles new programs on top of those seeds, so a partial
solution like `max(x, y)` becomes a building block the search can wrap in one
more `ifelse` to reach `max(x, y, z)` — instead of rebuilding it from scratch.
"""

# NOTE: HerbSearch.BankEntry is qualified (not imported) to avoid colliding with
# PartialSat's own `BankEntry` (the partial-solution-bank entry).
import HerbSearch: populate_bank!, get_bank, get_entries, get_measure_limit,
    AccessAddress, get_measures, get_types, get_programs,
    AbstractCostBasedBottomUpIterator, MeasureHashedBank

HerbSearch.@programiterator SeededCostBUIterator(
    bank = MeasureHashedBank{Float64,RuleNode}(),
    max_cost::Float64 = Inf,
    current_costs::Vector{Float64} = Float64[],
    program_to_outputs::Union{Nothing,Function} = nothing,
    seed_programs::Vector{RuleNode} = RuleNode[],
    seed_cost::Float64 = 1.0,
) <: AbstractCostBasedBottomUpIterator

@doc """
    SeededCostBUIterator(grammar, start_symbol; seed_programs, seed_cost, current_costs, max_depth, max_size, max_cost)

A cost-based bottom-up iterator whose bank is pre-seeded with `seed_programs`.

Each seed is inserted as a bank entry of cost `seed_cost` (default `1.0`) — i.e.
treated as a cheap *atom* rather than re-charged for its internal structure, so
combinations that reuse it surface early in the cost-ordered enumeration. This is
what turns banked partial solutions into accelerating building blocks. All other
behavior is inherited from `CostBasedBottomUpIterator`.
""" SeededCostBUIterator

"""
    populate_bank!(iter::SeededCostBUIterator)

Seed the grammar terminals (inherited behavior) and then inject every
`seed_program` as a bank entry of cost `seed_cost`, skipping seeds that exceed
the depth/size/cost limits or that already occur in the bank. Returns the
`AccessAddress`es for the full seeded bank.
"""
function HerbSearch.populate_bank!(iter::SeededCostBUIterator)
    # Inherited terminal seeding.
    invoke(populate_bank!, Tuple{AbstractCostBasedBottomUpIterator}, iter)

    bank = get_bank(iter)
    grammar = HerbConstraints.get_grammar(iter)
    for prog in iter.seed_programs
        (HerbCore.depth(prog) >= HerbSearch.get_max_depth(iter) ||
         length(prog) >= HerbSearch.get_max_size(iter) ||
         iter.seed_cost > get_measure_limit(iter)) && continue
        T = HerbGrammar.return_type(grammar, prog)
        existing = get_programs(bank, T, iter.seed_cost)
        any(p -> p == prog, existing) && continue   # de-dup against bank
        push!(get_entries(bank, T, iter.seed_cost), HerbSearch.BankEntry{RuleNode}(prog, true))
    end

    # Rebuild the initial address window over the full (seeded) bank.
    out = AccessAddress[]
    for T in get_types(bank), c in get_measures(bank, T)
        c <= get_measure_limit(iter) || continue
        for (i, prog) in enumerate(get_programs(bank, T, c))
            push!(out, AccessAddress{Float64}(T, c, i, HerbCore.depth(prog), length(prog), true))
        end
    end
    return out
end
