# Running the benchmarks

All commands run from the repo root. Install deps once:

    julia --project -e 'using Pkg; Pkg.instantiate()'

The e-graph pruning benchmark shells out to a separate environment (Metatheory
pins an older DataStructures than HerbSearch, so they can't share one). Set it up
once too:

    julia --project=tools/egraph_gen -e 'using Pkg; Pkg.instantiate()'

## max_N (partial-sat + seeded bottom-up)

Finds the largest `max_N` solvable by scoring candidates on how many spec
constraints they satisfy, banking the good partial programs, and seeding the next
round with them.

    julia --project scripts/iterative_seeded_max.jl

Specs live in `benchmarks/max_n/` (max3..max8).

## Formal-spec problems

Same solver on small universally-quantified specs (min2, abs, clamp01, min3, ...).
Pass names to run a subset, or nothing for all.

    julia --project scripts/run_formal_problems.jl
    julia --project scripts/run_formal_problems.jl min2 abs

Specs live in `benchmarks/formal/`.

## Partial-satisfaction demo

Scores a candidate constraint-by-constraint and runs the guided search directly,
without the seeding loop.

    julia --project scripts/test_partial_satisfaction.jl

## E-graph-derived pruning

Derives grammar constraints from equality saturation and reports the search-space
reduction on max2/max3.

    julia --project scripts/test_egraph_derived_constraints.jl
