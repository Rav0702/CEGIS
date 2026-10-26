"""
    seed_programs.jl

E4 (spec_knowledge/EXPERIMENTS.md): the spec's knowledge as seeds of the first population, the Init injection
point. The knowledge items are the recipes `(G, t)` (`spec_answer_recipes`) and the region guards `G`
(`spec_region_guards`), already in the grammar's own operators. A seed is a chain over items in a random order,

    ite(G₁, l₁, ite(G₂, l₂, … ite(Gₙ, lₙ, tail)))

a program of the ORIGINAL grammar; nothing is added to the grammar. `mode` decides what goes in:

    :guard    every item; every leaf random                                   where, not what
    :partial  a random ⌈k/2⌉ of the items; a recipe's leaf is its answer       where and what, for half the regions
    :full     every item; a recipe's leaf is its answer                       all of it (complete coverage: a solution)
    :inert    as :guard, each guard made unsatisfiable (`inert_guard`)        placebo: same shape, no content

A region guard's leaf and the tail are always random trees from Herb's sampler, at most `leaf_depth` (leaves) or
`tail_depth` (tail) deep and inside `depth_cap`. `run_cdgp(...; seed_programs)` puts the seeds in the first slots
of the first population (`_INIT_SEEDS`, state_and_init.jl); the rest is sampled exactly as in an unseeded run.
"""

"""Knowledge items `(guard, answer)`: one per guarded recipe (answer = its term) and one per region guard (answer
`nothing`). An unguarded recipe (a term that solves the spec by itself) has no region and is left out."""
function seed_items(spec, grammar::AbstractGrammar)
    recipes = something(spec_answer_recipes(spec, grammar), AnswerRecipe[])
    items = Tuple{RuleNode,Union{RuleNode,Nothing}}[(r.guard, r.term) for r in recipes if r.guard !== nothing]
    append!(items, Tuple{RuleNode,Union{RuleNode,Nothing}}[(r.guard, nothing) for r in spec_region_guards(spec, grammar)])
    return items
end

_cmp_rules(R::_Rules) = [R.ops[k] for k in (:ge, :le, :gt, :lt, :eq) if R.ops[k] != 0]

"""The comparison atoms of a guard that is a conjunction of atoms, in pre-order; `nothing` otherwise."""
function _conj_atoms(G::RuleNode, R::_Rules)
    G.ind in _cmp_rules(R) && return RuleNode[G]
    (R.ops[:and] != 0 && G.ind == R.ops[:and]) || return nothing
    out = RuleNode[]
    for c in G.children
        a = _conj_atoms(c, R)
        a === nothing && return nothing
        append!(out, a)
    end
    return out
end

"""¬(a ≥ b) as `a ≤ b − 1` and ¬(a ≤ b) as `a ≥ b + 1`, cancelling a ±1 already there (¬(a ≥ b + 1) = a ≤ b), as
the E5a inert grammars do (`scripts/gen_enriched_grammars.jl`). `nothing` for other atoms."""
function _negate_atom(a::RuleNode, R::_Rules)
    o = R.ops
    (R.one == 0 || o[:plus] == 0 || o[:minus] == 0) && return nothing
    l, r = a.children
    pm1(x, op) = x.ind == o[op] && length(x.children) == 2 && x.children[2] == RuleNode(R.one)
    if a.ind == o[:ge] && o[:le] != 0
        rhs = pm1(r, :plus) ? deepcopy(r.children[1]) : RuleNode(o[:minus], [deepcopy(r), RuleNode(R.one)])
        return RuleNode(o[:le], [deepcopy(l), rhs])
    elseif a.ind == o[:le] && o[:ge] != 0
        rhs = pm1(r, :minus) ? deepcopy(r.children[1]) : RuleNode(o[:plus], [deepcopy(r), RuleNode(R.one)])
        return RuleNode(o[:ge], [deepcopy(l), rhs])
    end
    return nothing
end

"""`G` with its `j`-th atom (pre-order) replaced by `new`."""
function _replace_nth_atom(G::RuleNode, j::Int, new::RuleNode, R::_Rules)
    cmp = _cmp_rules(R)
    k = Ref(0)
    walk(n) = n.ind in cmp ? ((k[] += 1) == j ? new : deepcopy(n)) : RuleNode(n.ind, [walk(c) for c in n.children])
    return walk(G)
end

"""The first comparison atom of `G` in pre-order, at any depth (under `or` or `not` too); `nothing` if none."""
function _first_atom(G::RuleNode, R::_Rules)
    G.ind in _cmp_rules(R) && return G
    for c in G.children
        a = _first_atom(c, R)
        a === nothing || return a
    end
    return nothing
end

"""E5's always-false atom from a comparison's two sides: `d ≥ d + 1` with `d = l − r` (as `atomsinert` in
`scripts/gen_enriched_grammars.jl`). `nothing` when the grammar lacks the operators."""
function _always_false_atom(a::RuleNode, R::_Rules)
    o = R.ops
    (R.one == 0 || o[:plus] == 0 || o[:minus] == 0 || o[:ge] == 0) && return nothing
    l, r = a.children
    d() = RuleNode(o[:minus], [deepcopy(l), deepcopy(r)])
    return RuleNode(o[:ge], [d(), RuleNode(o[:plus], [d(), RuleNode(R.one)])])
end

"""
    inert_guard(G, R) -> RuleNode

The E5a inert placebo of a guard: atom j replaced by the negation of atom i, for the first pair in the order (1, 2),
(1, 3), …, (2, 1), … whose atom i can be negated, so the conjunction holds nowhere and keeps the guard's atom count.
A one-atom guard `a` becomes `a ∧ ¬a`. Where neither applies (a guard that is not a conjunction of atoms, or whose
atoms cannot be negated, such as an equality; none in the E4 specs, found in the confirmatory pool), the guard
becomes `G ∧ F` with `F` the always-false atom of its first comparison, which holds nowhere whatever `G`'s structure,
like the one-atom form.
"""
function inert_guard(G::RuleNode, R::_Rules)
    atoms = _conj_atoms(G, R)
    if atoms !== nothing && length(atoms) == 1
        n = _negate_atom(atoms[1], R)
        n !== nothing && R.ops[:and] != 0 && return RuleNode(R.ops[:and], [deepcopy(G), n])
    elseif atoms !== nothing
        for i in eachindex(atoms), j in eachindex(atoms)
            i == j && continue
            n = _negate_atom(atoms[i], R)
            n === nothing || return _replace_nth_atom(G, j, n, R)
        end
    end
    a = _first_atom(G, R)
    F = a === nothing ? nothing : _always_false_atom(a, R)
    (F === nothing || R.ops[:and] == 0) && throw(ArgumentError("inert_guard: no inert form for the guard"))
    return RuleNode(R.ops[:and], [deepcopy(G), F])
end

"""One seed of `mode` (see the file header), drawn from the global RNG."""
function seed_program(items, mode::Symbol, R::_Rules, start_symbol::Symbol;
                      leaf_depth::Int, tail_depth::Int, depth_cap::Int)
    idx = randperm(length(items))
    mode === :partial && (idx = idx[1:cld(length(idx), 2)])
    n = length(idx)
    t = rand(RuleNode, R.g, start_symbol, min(tail_depth, depth_cap - n))      # the tail sits at depth n + 1
    for pos in n:-1:1                                                       # the pos-th ite sits at depth pos
        G, ans = items[idx[pos]]
        guard = mode === :inert ? inert_guard(G, R) : deepcopy(G)
        leaf = mode in (:partial, :full) && ans !== nothing ? deepcopy(ans) :
               rand(RuleNode, R.g, start_symbol, min(leaf_depth, depth_cap - pos))
        t = RuleNode(R.ops[:ite], [guard, leaf, t])
    end
    return t
end

"""
    spec_seed_programs(spec, grammar, start_symbol, mode, n; depth_cap, rng_seed, leaf_depth = 3, tail_depth = 6)
        -> Vector{RuleNode}

`n` seeds of `mode` (`:guard`, `:partial`, `:full`, `:inert`). They are drawn after `Random.seed!(rng_seed)` and
the global RNG is restored afterwards, so the caller's random stream is untouched. A seed deeper than `depth_cap`
is redrawn: the operators reject offspring beyond the cap, so it could not breed. Throws when the spec yields no
knowledge items or no seed fits.
"""
function spec_seed_programs(spec, grammar::AbstractGrammar, start_symbol::Symbol, mode::Symbol, n::Int;
                            depth_cap::Int, rng_seed::Integer, leaf_depth::Int = 3, tail_depth::Int = 6)
    mode in (:guard, :partial, :full, :inert) ||
        throw(ArgumentError("spec_seed_programs: mode must be :guard, :partial, :full or :inert, got :$mode"))
    items = seed_items(spec, grammar)
    isempty(items) && throw(ArgumentError("spec_seed_programs: the spec yields no recipes or region guards"))
    R = _Rules(grammar)
    R.ops[:ite] == 0 && throw(ArgumentError("spec_seed_programs: the grammar has no ite"))
    m = mode === :partial ? cld(length(items), 2) : length(items)
    m < depth_cap || throw(ArgumentError("spec_seed_programs: a chain of $m items cannot fit depth cap $depth_cap"))
    function fit()
        for _ in 1:100
            s = seed_program(items, mode, R, start_symbol; leaf_depth, tail_depth, depth_cap)
            depth(s) <= depth_cap && return s
        end
        throw(ArgumentError("spec_seed_programs: no :$mode seed within depth cap $depth_cap in 100 draws"))
    end
    saved = copy(Random.default_rng())
    try
        Random.seed!(rng_seed)
        return RuleNode[fit() for _ in 1:n]
    finally
        copy!(Random.default_rng(), saved)
    end
end

"""How many of the knowledge guards, in `mode`'s form (inert for `:inert`), occur verbatim in `tree`: whether the
seeded structure survived into a program."""
function seed_guards_kept(tree::RuleNode, spec, grammar::AbstractGrammar, mode::Symbol)
    R = _Rules(grammar)
    forms = [mode === :inert ? inert_guard(G, R) : G for (G, _) in seed_items(spec, grammar)]
    subs = Set{RuleNode}()
    walk(n) = (push!(subs, n); foreach(walk, n.children))
    walk(tree)
    return count(in(subs), unique(forms))
end
