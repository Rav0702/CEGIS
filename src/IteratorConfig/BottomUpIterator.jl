"""
    IteratorConfig/BottomUpIterator.jl

Configuration for **bottom-up** synthesis iterators, integrated into the same
`AbstractSynthesisIterator` / `create_iterator` framework as BFS/DFS so a
bottom-up search is a first-class, drop-in alternative everywhere CEGIS accepts
an iterator config.

Bottom-up search maintains a *bank* of already-built programs grouped by a
`measure` (size, depth, or cost) and grows the bank by combining bank members
under each operator. Unlike top-down enumeration, the bank is the natural place
to deduplicate redundant programs: `HerbSearch`'s `add_to_bank!` decides whether
a freshly combined program is worth keeping. Two complementary equivalence
notions can live there:

  * **Syntactic / algebraic** equivalence — `a + 0 ≡ a`, `a < b ≡ b > a`, …
    Currently supplied *offline* by `EGraphPruning` as `Forbidden`/`Ordered`
    grammar constraints (sound, example-independent). These are enforced inside
    the bottom-up loop too: `CostBasedBottomUpIterator` checks
    `HerbConstraints.check_tree` before yielding, and `SizeBasedBottomUpIterator`
    propagates them through its `GenericSolver`.

  * **Observational** equivalence — two programs producing identical outputs on
    the current I/O examples. This is the pruning that *only* a bottom-up bank
    can do, and that the offline e-graph fundamentally cannot (it is behavioral,
    not algebraic). Enable it by passing `program_to_outputs` (see below); the
    `CostBasedBottomUpIterator` then hashes outputs and drops duplicates.

See `docs/egraph_research/METATHEORY_INTEGRATION_PLAN.md` / `EGRAPH_WORK_LOG.md` for how an e-graph
could additionally serve as the *online* equivalence oracle in `add_to_bank!`.

## Usage

```julia
# size-indexed bank (uses GenericSolver constraint propagation, incl. derived)
cfg = BottomUpIteratorConfig(variant=:size, max_depth=5, max_size=20)

# cost-indexed bank, biased so ifelse/comparisons are enumerated earlier
cfg = BottomUpIteratorConfig(variant=:cost, max_depth=5, max_cost=Inf)

# cost-indexed bank with observational equivalence against I/O examples
cfg = BottomUpIteratorConfig(variant=:cost, program_to_outputs=my_eval_fn)

iter = create_iterator(cfg, grammar, :Expr)   # pruning is automatic
```
"""

using HerbCore
using HerbGrammar
using HerbSearch

"""
    rule_costs_with_bias(grammar; default_cost, ifelse_cost, compare_cost,
                         extra_costs=Dict()) :: Vector{Float64}

Per-rule cost vector for `CostBasedBottomUpIterator`. Lower cost ⇒ earlier
enumeration. Defaults bias toward solution-relevant operators (cheap `ifelse`
and comparisons) so max-style targets surface sooner; `extra_costs` (operator
symbol ⇒ cost) overrides any specific rule.
"""
function rule_costs_with_bias(grammar::AbstractGrammar;
    default_cost::Float64 = 1.0,
    ifelse_cost::Float64 = 0.2,
    compare_cost::Float64 = 0.5,
    extra_costs::AbstractDict{Symbol,Float64} = Dict{Symbol,Float64}(),
)
    costs = fill(default_cost, length(grammar.rules))
    for (idx, rule) in enumerate(grammar.rules)
        (rule isa Expr && rule.head === :call) || continue
        op = rule.args[1]
        if haskey(extra_costs, op)
            costs[idx] = extra_costs[op]
        elseif op === :ifelse
            costs[idx] = ifelse_cost
        elseif op in (:<, :>, :<=, :>=, :(==))
            costs[idx] = compare_cost
        end
    end
    return costs
end

"""
    BottomUpIteratorConfig <: AbstractSynthesisIterator

Configuration for a bottom-up iterator.

- `variant` — `:size`, `:depth`, or `:cost` (which measure indexes the bank).
- `max_depth`, `max_size` — solver bounds (apply to every variant).
- `max_cost` — cost ceiling (`:cost` variant only).
- `current_costs` — explicit per-rule cost vector; if `nothing` and `variant`
  is `:cost`, `rule_costs_with_bias` is used at construction time.
- `program_to_outputs` — `RuleNode -> outputs`; when supplied to the `:cost`
  variant, enables observational-equivalence dedup in the bank.
"""
struct BottomUpIteratorConfig <: AbstractSynthesisIterator
    variant            :: Symbol
    max_depth          :: Int
    max_size           :: Int
    max_cost           :: Float64
    current_costs      :: Union{Vector{Float64}, Nothing}
    program_to_outputs :: Union{Function, Nothing}

    function BottomUpIteratorConfig(;
        variant            :: Symbol = :cost,
        max_depth          :: Int = 5,
        max_size           :: Int = 20,
        max_cost           :: Float64 = Inf,
        current_costs      :: Union{Vector{Float64}, Nothing} = nothing,
        program_to_outputs :: Union{Function, Nothing} = nothing,
    )
        variant in (:size, :depth, :cost) ||
            error("variant must be :size, :depth, or :cost, got :$variant")
        max_depth >= 1 || error("max_depth must be >= 1, got $max_depth")
        max_size  >= 1 || error("max_size must be >= 1, got $max_size")
        new(variant, max_depth, max_size, max_cost, current_costs, program_to_outputs)
    end
end

"""
    create_iterator(config::BottomUpIteratorConfig, grammar, start_symbol)

Build the bottom-up iterator described by `config`. Any constraints already
attached to `grammar` (including those produced by `EGraphPruning`) are enforced
during enumeration.
"""
function create_iterator(config::BottomUpIteratorConfig,
                         grammar::AbstractGrammar,
                         start_symbol::Symbol)
    if config.variant === :cost
        costs = config.current_costs === nothing ?
            rule_costs_with_bias(grammar) : config.current_costs
        length(costs) == length(grammar.rules) ||
            error("current_costs has $(length(costs)) entries, grammar has $(length(grammar.rules)) rules")
        return CostBasedBottomUpIterator(
            grammar, start_symbol;
            max_depth = config.max_depth,
            max_size  = config.max_size,
            max_cost  = config.max_cost,
            current_costs = costs,
            program_to_outputs = config.program_to_outputs,
        )
    elseif config.variant === :size
        return SizeBasedBottomUpIterator(
            grammar, start_symbol;
            max_depth = config.max_depth,
            max_size  = config.max_size,
        )
    else # :depth
        return DepthBasedBottomUpIterator(
            grammar, start_symbol;
            max_depth = config.max_depth,
            max_size  = config.max_size,
        )
    end
end
