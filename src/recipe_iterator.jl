"""
    recipe_iterator.jl

A non-GP reference synthesizer: CEGIS over the spec's own answer recipes.

`RecipeIterator` is a HerbSearch `ProgramIterator` that proposes programs built only from the
answer recipes of `GeneticSearch.spec_answer_recipes` (see `constraint_patches.jl`): it starts from
one recipe's answer term and, after every counterexample, puts the recipe whose guard holds at
that counterexample in front of the current program, `ite(G_t, t, program)`. There is no search:
each counterexample decides the next case. It stops when a counterexample has no firing recipe
(the spec's answers do not cover that input) or when it has no new counterexample to act on.

This is a syntactic, incremental version of the single-invocation solution construction of
Reynolds et al. (CAV 2015, Proposition 1): the terms come from the spec's text rather than from
the solver's quantifier instantiations. It is the non-GP reference for the guided operator v3
(RQ1_RQ2_PLAN.md §7.12): whatever v3 solves that this does not, the GA contributed.

Two ways to run it:
- `run_synthesis(problem::CEGISProblem, RecipeIterator(spec, grammar))` — through the classic
  CEGIS loop (`synth_with_oracle`), which feeds counterexamples back through
  `notify_counterexample!`. That loop filters candidates by complete IO examples, so it is only
  correct on single-answer specs.
- `run_recipe_cegis(spec_path; regions = true)` — decomposed mode for partial knowledge: counterexamples in a
  region the spec names without an answer (`GeneticSearch.spec_region_guards`) are solved per region by a small
  BFS over the grammar (spec_knowledge/PARTIAL_KNOWLEDGE.md). Off by default: the plain arm is unchanged.
- `run_recipe_cegis(spec_path; …)` — verifies each candidate directly with Z3 (in-process
  `CexSolver`, subprocess fallback), so it is also correct on multi-answer specs, and returns a
  `GeneticSearch.CDGPResult` plus trace so the benchmark harness can run it as an arm
  (`engine = :recipes`). No depth cap applies: this arm is not a GA.
"""

"""
    notify_counterexample!(iterator, cx::Counterexample)

Called by the CEGIS loop after each counterexample. A no-op for ordinary iterators; iterators
that construct programs from counterexamples (`RecipeIterator`) override it.
"""
notify_counterexample!(::Any, ::Counterexample) = nothing

mutable struct RecipeIterator <: HerbSearch.ProgramIterator
    solver::HerbConstraints.Solver         # for get_grammar / get_starting_symbol only
    fname::String
    recipes::Vector{GeneticSearch.AnswerRecipe}
    ite_rule::Int
    program::RuleNode
    pending::Vector{Dict{Symbol,Any}}      # counterexample inputs not yet acted on
    cases::Int                             # cases added so far
    stuck::Bool                            # a counterexample had no firing recipe
    # Decomposed mode (`regions = true`; spec_knowledge/PARTIAL_KNOWLEDGE.md). Empty `regions` = the
    # original behaviour above, unchanged.
    pending_out::Vector{Any}               # expected outputs, parallel to `pending`
    regions::Vector{GeneticSearch.RegionGuard}
    region_examples::Vector{Vector{IOExample}}
    region_leaf::Vector{Union{RuleNode,Nothing}}
    chain::Vector{Int}                     # recipes applied, oldest first
    base::RuleNode                         # the innermost program (the first proposal)
    start_symbol::Symbol
    leaf_depth::Int
    leaf_max_enum::Int
    deadline::Float64                      # wall-clock limit for leaf searches (run_recipe_cegis sets it)
    leaf_searches::Int
    leaf_enumerations::Int
    leaf_mode::Symbol                      # :bfs (BFS, output equality) | :oe (bottom-up + obs. equivalence, constraint check)
    constraints_sx::Vector{Any}            # parsed spec constraints (for :oe acceptance)
    relational::Bool                       # some constraint applies f off the declared variables
    witnesses::Vector{Dict{Symbol,Any}}    # every counterexample input (relational mode)
    params::Vector{Symbol}
end

"""
    RecipeIterator(spec, grammar; start_symbol=:Expr)

`spec` is a parsed `CEXGeneration.Spec`. The first program is the first recipe's answer term (or
the grammar's first terminal of `start_symbol` when the spec yields no recipes).
"""
function RecipeIterator(spec, grammar::AbstractGrammar; start_symbol::Symbol = :Expr, max_depth::Int = 64,
                        regions::Bool = false, leaf_depth::Int = 5, leaf_max_enum::Int = 5_000_000,
                        leaf_search::Symbol = :bfs)
    recipes = something(GeneticSearch.spec_answer_recipes(spec, grammar), GeneticSearch.AnswerRecipe[])
    initial = if isempty(recipes)
        i = findfirst(j -> grammar.types[j] == start_symbol && isempty(grammar.childtypes[j]), eachindex(grammar.rules))
        i === nothing && throw(ArgumentError("RecipeIterator: no terminal of type $start_symbol"))
        RuleNode(i)
    else
        deepcopy(recipes[1].term)
    end
    rg = regions ? GeneticSearch.spec_region_guards(spec, grammar) : GeneticSearch.RegionGuard[]
    RecipeIterator(GenericSolver(grammar, start_symbol; max_depth = max_depth), spec.synth_funs[1].name,
                   recipes, GeneticSearch.PatchKit(grammar).ite, initial, Dict{Symbol,Any}[], 0, false,
                   Any[], rg, [IOExample[] for _ in rg], Union{RuleNode,Nothing}[nothing for _ in rg], Int[],
                   deepcopy(initial), start_symbol, leaf_depth, leaf_max_enum, Inf, 0, 0,
                   leaf_search, Any[CEXGeneration.read_sexprs(c)[1] for c in spec.constraints],
                   any(c -> occursin("($(spec.synth_funs[1].name)", c) &&
                            !CEXGeneration._canonical_calls_only(c, spec.synth_funs[1].name,
                                                                 [fv.name for fv in spec.free_vars],
                                                                 length(spec.synth_funs[1].params)),
                       spec.constraints),
                   Dict{Symbol,Any}[], Symbol[Symbol(p) for (p, _) in spec.synth_funs[1].params])
end

Base.iterate(it::RecipeIterator) = (it.program, nothing)

function Base.iterate(it::RecipeIterator, ::Nothing)
    isempty(it.pending) && return nothing            # nothing new to act on
    x = popfirst!(it.pending)
    y = isempty(it.pending_out) ? nothing : popfirst!(it.pending_out)
    i = findfirst(r -> GeneticSearch.recipe_fires(r, it.fname, x), it.recipes)
    isempty(it.regions) || return _iterate_regions(it, x, y, i)
    if i === nothing
        it.stuck = true
        return nothing
    end
    next = GeneticSearch.answer_patch(it.program, it.recipes[i], it.ite_rule)
    if next === nothing                              # the grammar has no ite rule
        it.stuck = true
        return nothing
    end
    it.program = next
    it.cases += 1
    return (it.program, nothing)
end

notify_counterexample!(it::RecipeIterator, cx::Counterexample) =
    (push!(it.pending, cx.input); push!(it.pending_out, cx.expected_output); nothing)

"""
Decomposed mode: a counterexample where a recipe fires adds that recipe; one inside a guard-only region R
becomes an example of R, and R's leaf is re-found as the first program (BFS over the grammar, depth
`leaf_depth`) consistent with all of R's examples. The proposal is re-assembled each round:
`ite(G_t, t, … ite(G_R, leaf_R, … base))`, recipes outermost. Stuck when the input is in no recipe's and
no region's guard, or a leaf search finds nothing in its budget.
"""
function _iterate_regions(it::RecipeIterator, x, y, i)
    (it.relational && it.leaf_mode === :oe) && return _iterate_relational(it, x, i)
    if i !== nothing
        push!(it.chain, i)
        it.cases += 1
    else
        k = findfirst(r -> GeneticSearch.region_fires(r, it.fname, x), it.regions)
        if k === nothing || y === nothing
            it.stuck = true
            return nothing
        end
        push!(it.region_examples[k], IOExample(x, y))
        leaf = _leaf_search(it, k)
        if leaf === nothing
            it.stuck = true
            return nothing
        end
        it.region_leaf[k] = leaf
    end
    inner = deepcopy(it.base)
    for k in reverse(eachindex(it.regions))
        it.region_leaf[k] === nothing && continue
        inner = RuleNode(it.ite_rule, [deepcopy(it.regions[k].guard), deepcopy(it.region_leaf[k]), inner])
    end
    for j in it.chain
        inner = GeneticSearch.answer_patch(inner, it.recipes[j], it.ite_rule)
    end
    it.program = inner
    return (it.program, nothing)
end

"""First program in BFS order (depth ≤ `leaf_depth`) that matches every example of region `k`."""
function _leaf_search(it::RecipeIterator, k::Int)
    it.leaf_mode === :oe && return _leaf_search_oe(it, k)
    it.leaf_mode === :unif && return _leaf_search_unif(it, k)
    g = HerbConstraints.get_grammar(it.solver)
    st = grammar2symboltable(g)
    ex = it.region_examples[k]
    it.leaf_searches += 1
    for (n, p) in enumerate(BFSIterator(g, it.start_symbol; max_depth = it.leaf_depth))
        it.leaf_enumerations += 1
        (n > it.leaf_max_enum || time() > it.deadline) && return nothing
        e = rulenode2expr(p, g)
        ok = all(ex) do io
            try
                HerbInterpret.execute_on_input(st, e, io.in) == io.out
            catch
                false
            end
        end
        ok && return freeze_state(p)
    end
    return nothing
end

"""
Relational specs (`leaf_search = :oe`, some constraint applies f at shifted arguments, e.g. f(x+1, y, z)).
Every counterexample is banked. A new recipe is applied when one fires there; otherwise every guard-only
region's leaf is re-solved so that ALL constraints hold at ALL banked counterexamples, evaluated on the whole
assembled program (applications at shifted arguments read the program there). A counterexample is not owned by
one region: a recurrence links points across the recipe chain and the leaves.
"""
function _iterate_relational(it::RecipeIterator, x, i)
    x in it.witnesses || push!(it.witnesses, x)
    if i !== nothing && !(i in it.chain)
        push!(it.chain, i)
        it.cases += 1
    else
        for k in eachindex(it.regions)
            leaf = _leaf_search_rel(it, k)
            if leaf === nothing
                it.stuck = true
                return nothing
            end
            it.region_leaf[k] = leaf
        end
    end
    inner = deepcopy(it.base)
    for k in reverse(eachindex(it.regions))
        it.region_leaf[k] === nothing && continue
        inner = RuleNode(it.ite_rule, [deepcopy(it.regions[k].guard), deepcopy(it.region_leaf[k]), inner])
    end
    for j in it.chain
        inner = GeneticSearch.answer_patch(inner, it.recipes[j], it.ite_rule)
    end
    it.program = inner
    return (it.program, nothing)
end

"""Which part of the assembled program answers at `p`: (:recipe, j) | (:region, k) | (:base, 0)."""
function _owner(it::RecipeIterator, p::Dict{Symbol,Any}, solving::Int)
    for j in reverse(it.chain)
        GeneticSearch.recipe_fires(it.recipes[j], it.fname, p) && return (:recipe, j)
    end
    for k in eachindex(it.regions)
        (it.region_leaf[k] !== nothing || k == solving) || continue
        GeneticSearch.region_fires(it.regions[k], it.fname, p) && return (:region, k)
    end
    return (:base, 0)
end

"""
Leaf of region `k` for a relational spec: bottom-up terms with observational equivalence over the points region
`k` answers (banked counterexamples and every shifted point their constraints read), accepted when every
constraint holds at every banked counterexample with the rest of the program fixed.
"""
function _leaf_search_rel(it::RecipeIterator, k::Int)
    g = HerbConstraints.get_grammar(it.solver)
    st = grammar2symboltable(g)
    R = GeneticSearch._Rules(g)
    plus, minus = get(R.ops, :plus, 0), get(R.ops, :minus, 0)
    evalt(t, p) = HerbInterpret.execute_on_input(st, rulenode2expr(t, g), p)
    topoint(args) = Dict{Symbol,Any}(it.params[i] => args[i] for i in eachindex(it.params))
    ownerof = Dict{Dict{Symbol,Any},Tuple{Symbol,Int}}()
    own(p) = get!(() -> _owner(it, p, k), ownerof, p)
    restcache = Dict{Dict{Symbol,Any},Any}()
    function rest(p)                                     # value of the program at p, outside region k
        get!(restcache, p) do
            o = own(p)
            o[1] === :recipe ? evalt(it.recipes[o[2]].term, p) :
            o[1] === :region ? evalt(it.region_leaf[o[2]], p) : evalt(it.base, p)
        end
    end
    # points region k answers: banked counterexamples and every argument tuple their constraints read
    pts = Dict{Symbol,Any}[]
    for w in it.witnesses, c in it.constraints_sx
        b = Dict{String,Any}(String(a) => v for (a, v) in w)
        try
            CEXGeneration.eval_constraint_pointwise(c, it.fname, b, function (args)
                q = topoint(args)
                own(q) == (:region, k) && !(q in pts) && push!(pts, q)
                own(q) == (:region, k) ? (it.region_leaf[k] === nothing ? 0 : evalt(it.region_leaf[k], q)) : rest(q)
            end)
        catch
        end
    end
    idx = Dict(q => i for (i, q) in enumerate(pts))
    accept(vals) = all(it.witnesses) do w
        b = Dict{String,Any}(String(a) => v for (a, v) in w)
        all(it.constraints_sx) do c
            try
                CEXGeneration.eval_constraint_pointwise(c, it.fname, b, function (args)
                    q = topoint(args)
                    haskey(idx, q) ? vals[idx[q]] : rest(q)
                end)
            catch
                false
            end
        end
    end
    it.leaf_searches += 1
    isempty(pts) && return it.region_leaf[k] === nothing ? RuleNode(R.zero) : it.region_leaf[k]
    seen = Set{Vector{Int}}()
    levels = Vector{Vector{Tuple{Vector{Int},RuleNode}}}()
    lvl = Tuple{Vector{Int},RuleNode}[]
    atoms = [([Int(q[Symbol(name)]) for q in pts], RuleNode(rule)) for (name, rule) in R.vars]
    push!(atoms, (zeros(Int, length(pts)), RuleNode(R.zero)), (ones(Int, length(pts)), RuleNode(R.one)))
    for (v, t) in atoms
        v in seen && continue
        push!(seen, v); push!(lvl, (v, t)); it.leaf_enumerations += 1
        accept(v) && return t
    end
    push!(levels, lvl)
    while length(seen) < it.leaf_max_enum && time() < it.deadline
        L = length(levels) + 1
        lvl = Tuple{Vector{Int},RuleNode}[]
        for a in 1:L-1, (va, ta) in levels[a], (vb, tb) in levels[L-a]
            for (op, f) in ((plus, +), (minus, -))
                op == 0 && continue
                v = f.(va, vb)
                v in seen && continue
                push!(seen, v); it.leaf_enumerations += 1
                t = RuleNode(op, [ta, tb])
                accept(v) && return t
                push!(lvl, (v, t))
                (length(seen) >= it.leaf_max_enum || time() > it.deadline) && return nothing
            end
        end
        isempty(lvl) && return nothing
        push!(levels, lvl)
    end
    return nothing
end

"""
EUSolver's method for one guard-only region (`leaf_search = :unif`; Alur, Radhakrishna, Udupa, TACAS 2017),
for single-invocation regions whose answer may need its own case split (spec_files/partial_knowledge/hidden3.sl):

1. **term solver**: linear terms over the parameters, 0 and 1, bottom-up by size with observational equivalence
   on the region's example points, until every point is *covered* by some term (the region's constraint holds
   there with that term as the answer);
2. **predicates**: atoms `a ⋈ b` (⋈ among the grammar's >=, <=, =; `a` a parameter, `b` a term of at most three
   nodes), deduplicated by their truth vector on the points;
3. **unifier**: a decision tree split on the predicate of highest information gain over the points' covering
   terms (EUSolver's ID3), until one term covers each leaf's points.

A single term covering every point is tried first (up to `single_levels` size levels or `single_budget` distinct
terms), as EUSolver prefers terms to unification; unifying as soon as small terms happen to cover the points
overfits. If the tree cannot be built, more terms are enumerated (one size level at a time) and it is retried.
Returns a leaf (a term or an `ite` tree) or `nothing` when the budget or the deadline runs out.
"""
function _leaf_search_unif(it::RecipeIterator, k::Int; max_depth::Int = 5, single_levels::Int = 7,
                           single_budget::Int = 200_000)
    g = HerbConstraints.get_grammar(it.solver)
    R = GeneticSearch._Rules(g)
    plus, minus = get(R.ops, :plus, 0), get(R.ops, :minus, 0)
    pts = [io.in for io in it.region_examples[k]]
    n = length(pts)
    c = it.constraints_sx[it.regions[k].constraint]
    binds = [Dict{String,Any}(String(a) => v for (a, v) in x) for x in pts]
    holds(i, val) = try
        CEXGeneration.eval_constraint_pointwise(c, it.fname, binds[i], _ -> val)
    catch
        false
    end
    it.leaf_searches += 1
    n == 0 && return RuleNode(R.zero)
    # ── term solver ──
    terms = Tuple{Vector{Int},RuleNode,BitVector,Int}[]          # (values, term, cover, size)
    seen = Set{Vector{Int}}()
    levels = Vector{Vector{Tuple{Vector{Int},RuleNode}}}()
    covered = falses(n)
    function add!(v, t, sz)
        v in seen && return false
        push!(seen, v); it.leaf_enumerations += 1
        cov = BitVector([holds(i, v[i]) for i in 1:n])
        any(cov) && push!(terms, (v, t, cov, sz))
        covered .|= cov
        return true
    end
    lvl = Tuple{Vector{Int},RuleNode}[]
    for (name, rule) in R.vars
        v = [Int(x[Symbol(name)]) for x in pts]
        add!(v, RuleNode(rule), 1) && push!(lvl, (v, RuleNode(rule)))
    end
    for (v, t) in ((zeros(Int, n), RuleNode(R.zero)), (ones(Int, n), RuleNode(R.one)))
        add!(v, t, 1) && push!(lvl, (v, t))
    end
    push!(levels, lvl)
    function grow!()                                             # one more size level (2L - 1 nodes)
        L = length(levels) + 1
        lvl = Tuple{Vector{Int},RuleNode}[]
        for a in 1:L-1, (va, ta) in levels[a], (vb, tb) in levels[L-a], (op, f) in ((plus, +), (minus, -))
            op == 0 && continue
            v = f.(va, vb)
            t = RuleNode(op, [ta, tb])
            add!(v, t, 2L - 1) && push!(lvl, (v, t))
            (length(seen) >= it.leaf_max_enum || time() > it.deadline) && break
        end
        push!(levels, lvl)
        return !isempty(lvl)
    end
    # A single term covering every point is preferred (EUSolver tries terms before unification): search for one
    # up to `single_levels` (2L - 1 = 13 nodes) or `single_budget` distinct terms.
    single() = (best = nothing;
                for (v, t, cov, sz) in terms
                    all(cov) && (best === nothing || sz < best[2]) && (best = (t, sz))
                end; best === nothing ? nothing : best[1])
    while true
        t1 = single()
        t1 === nothing || return t1
        (length(levels) >= single_levels || length(seen) >= single_budget) && all(covered) && break
        (length(seen) >= it.leaf_max_enum || time() > it.deadline) && return nothing
        grow!() || (all(covered) ? break : return nothing)
    end
    # ── predicates: a ⋈ b, a a parameter, b a term of at most 3 nodes; one per truth vector ──
    small = Tuple{Vector{Int},RuleNode}[]
    for (v, t) in levels[1]; push!(small, (v, t)); end
    length(levels) >= 2 && for (v, t) in levels[2]; push!(small, (v, t)); end
    preds = Tuple{BitVector,RuleNode}[]
    pseen = Set{BitVector}()
    for (name, rule) in R.vars, (vb, tb) in small, (opk, f) in ((:ge, >=), (:le, <=), (:eq, ==))
        op = get(R.ops, opk, 0)
        op == 0 && continue
        va = [Int(x[Symbol(name)]) for x in pts]
        va == vb && continue
        sig = BitVector(f.(va, vb))
        (all(sig) || !any(sig) || sig in pseen) && continue
        push!(pseen, sig)
        push!(preds, (sig, RuleNode(op, [RuleNode(rule), tb])))
    end
    # ── unifier (EUSolver's ID3 over covering terms) ──
    function entropy(S)
        w = Dict{Int,Float64}()
        for i in S
            js = [j for j in eachindex(terms) if terms[j][3][i]]
            for j in js; w[j] = get(w, j, 0.0) + 1 / length(js); end
        end
        return -sum((q = x / length(S); q * log(q)) for x in values(w); init = 0.0)
    end
    function build(S, depth)
        best = nothing
        for (v, t, cov, sz) in terms
            all(cov[i] for i in S) && (best === nothing || sz < best[2]) && (best = (t, sz))
        end
        best !== nothing && return best[1]
        depth == 0 && return nothing
        h = entropy(S)
        choice = nothing
        for (sig, p) in preds
            S1 = [i for i in S if sig[i]]
            S0 = [i for i in S if !sig[i]]
            (isempty(S1) || isempty(S0)) && continue
            gain = h - (length(S1) * entropy(S1) + length(S0) * entropy(S0)) / length(S)
            (choice === nothing || gain > choice[1] + 1e-12) && (choice = (gain, p, S1, S0))
        end
        choice === nothing && return nothing
        t1 = build(choice[3], depth - 1); t1 === nothing && return nothing
        t0 = build(choice[4], depth - 1); t0 === nothing && return nothing
        return RuleNode(it.ite_rule, [deepcopy(choice[2]), t1, t0])
    end
    for _ in 1:4                                                  # retry with more terms if unification fails
        tree = build(collect(1:n), max_depth)
        tree === nothing || return tree
        (length(seen) >= it.leaf_max_enum || time() > it.deadline) && return nothing
        grow!() || return nothing
    end
    return nothing
end

"""
The fair enumerative rival (`leaf_search = :oe`): EUSolver's term solver for region `k`. Linear terms over the
parameters, 0 and 1 are built bottom-up by size with `+` / `-`, keeping one term per distinct vector of outputs on
the region's example inputs (observational equivalence). A term is accepted when the region's own constraint
holds at every example (pointwise, interpreter), so a multi-answer region is judged by the spec, not by the
solver's arbitrary pick. Budget: `leaf_max_enum` distinct terms, and the run's deadline.
"""
function _leaf_search_oe(it::RecipeIterator, k::Int)
    g = HerbConstraints.get_grammar(it.solver)
    R = GeneticSearch._Rules(g)
    plus, minus = get(R.ops, :plus, 0), get(R.ops, :minus, 0)
    xs = [io.in for io in it.region_examples[k]]
    c = it.constraints_sx[it.regions[k].constraint]
    accept(vals) = all(eachindex(xs)) do i
        try
            CEXGeneration.eval_constraint_pointwise(c, it.fname,
                Dict{String,Any}(String(a) => v for (a, v) in xs[i]), _ -> vals[i])
        catch
            false
        end
    end
    it.leaf_searches += 1
    seen = Set{Vector{Int}}()
    levels = Vector{Vector{Tuple{Vector{Int},RuleNode}}}()
    atoms = Tuple{Vector{Int},RuleNode}[]
    for (name, rule) in R.vars
        push!(atoms, ([Int(x[Symbol(name)]) for x in xs], RuleNode(rule)))
    end
    push!(atoms, (zeros(Int, length(xs)), RuleNode(R.zero)), (ones(Int, length(xs)), RuleNode(R.one)))
    lvl = Tuple{Vector{Int},RuleNode}[]
    for (v, t) in atoms
        v in seen && continue
        push!(seen, v); push!(lvl, (v, t)); it.leaf_enumerations += 1
        accept(v) && return t
    end
    push!(levels, lvl)                                   # levels[s] holds terms of size 2s - 1
    while length(seen) < it.leaf_max_enum && time() < it.deadline
        L = length(levels) + 1                           # new size 2L - 1 = (2a - 1) + (2b - 1) + 1, a + b = L
        lvl = Tuple{Vector{Int},RuleNode}[]
        for a in 1:L-1, (va, ta) in levels[a], (vb, tb) in levels[L-a]
            for (op, f) in ((plus, +), (minus, -))
                op == 0 && continue
                v = f.(va, vb)
                v in seen && continue
                push!(seen, v); it.leaf_enumerations += 1
                t = RuleNode(op, [ta, tb])
                accept(v) && return t
                push!(lvl, (v, t))
                (length(seen) >= it.leaf_max_enum || time() > it.deadline) && return nothing
            end
        end
        isempty(lvl) && return nothing
        push!(levels, lvl)
    end
    return nothing
end

"""Record one proposed program as one trace "generation" (the harness reads the trace)."""
function _trace_push_candidate!(tr::GeneticSearch.CDGPTrace, i::Int, genome, ntests::Int, solved::Bool)
    push!(tr.gen, i)
    push!(tr.round, 0)
    push!(tr.elapsed_s, time() - tr.t0)
    push!(tr.best_fitness, 0.0)          # a proposed program passes every earlier counterexample
    push!(tr.mean_fitness, NaN)
    push!(tr.best_size, length(genome.tree))
    key = Arborist.serialize(genome)
    push!(tr.best_key, key)
    haskey(tr.genomes, key) || (tr.genomes[key] = deepcopy(genome))
    push!(tr.tests, ntests)
    push!(tr.incomplete_tests, 0)
    push!(tr.witnesses, 0)
    push!(tr.solved, solved)
    if solved && tr.solve_gen == 0
        tr.solve_gen = i
        tr.solve_elapsed_s = tr.elapsed_s[end]
    end
    d = CEXGeneration.z3_stats_diff(CEXGeneration.z3_stats(), tr.z3_base)
    push!(tr.z3_constraint_checks, d.constraint_checks)
    push!(tr.z3_cex_queries, d.cex_queries)
    push!(tr.z3_complete_output, d.complete_output)
    push!(tr.z3_output_unique, d.output_unique)
    push!(tr.z3_subprocess, d.subprocess)
    push!(tr.z3_time_s, d.time_s)
    return nothing
end

"""
    run_recipe_cegis(spec_path; grammar=nothing, start_symbol=:Expr, max_time=Inf,
                     max_iterations=10_000, z3_timeout_ms=5_000, verbose=false, trace=nothing,
                     kwargs...) -> GeneticSearch.CDGPResult

CEGIS with `RecipeIterator`, verifying each proposed program directly with Z3. Extra keyword
arguments (the GA settings the harness passes to every arm) are ignored. `generations` in the
result counts proposed programs; `rounds` is 0.
"""
function run_recipe_cegis(spec_path::String; grammar::Union{AbstractGrammar,Nothing} = nothing,
                          start_symbol::Symbol = :Expr, max_time::Float64 = Inf,
                          max_iterations::Int = 10_000, z3_timeout_ms::Integer = 5_000,
                          verbose::Bool = false, trace = nothing, regions::Bool = false,
                          leaf_depth::Int = 5, leaf_search::Symbol = :bfs, kwargs...)
    GS = GeneticSearch
    spec = CEXGeneration.parse_spec_from_file(spec_path)
    grammar = grammar === nothing ? build_grammar_from_spec(spec_path; start_symbol = start_symbol) : grammar
    fname = spec.synth_funs[1].name
    cs = try
        CEXGeneration.CexSolver(spec; timeout_ms = z3_timeout_ms, nl_arith = false)
    catch
        nothing                                          # outside the in-process scope: subprocess
    end
    it = RecipeIterator(spec, grammar; start_symbol = start_symbol, regions = regions, leaf_depth = leaf_depth,
                        leaf_search = leaf_search)
    t0 = time()
    it.deadline = t0 + max_time
    trace === nothing || GS._trace_begin!(trace, t0)
    tests = IOExample[]
    cxs = Counterexample[]
    verifications = 0
    solved = nothing
    last = nothing
    n = 0
    for cand in it
        (n >= max_iterations || time() - t0 > max_time) && break
        n += 1
        last = cand
        genome = GS.RuleNodeGenome(cand, grammar, start_symbol)
        smt = try
            CEXGeneration.rulenode_to_smt2(cand, grammar; context_type = GS._synth_context_type(spec))
        catch
            nothing
        end
        r = if smt === nothing
            CEXGeneration.Z3Result(:unknown, Dict{String,Any}(), String[])
        else
            verifications += 1
            try
                cs !== nothing ? CEXGeneration.find_counterexample(cs, Dict(fname => smt)) :
                    CEXGeneration.verify_query(CEXGeneration.generate_cex_query(spec, Dict(fname => smt)))
            catch
                CEXGeneration.Z3Result(:unknown, Dict{String,Any}(), String[])
            end
        end
        if r.status == :unsat
            solved = genome
            trace === nothing || _trace_push_candidate!(trace, n, genome, length(tests), true)
            break
        end
        trace === nothing || _trace_push_candidate!(trace, n, genome, length(tests), false)
        r.status == :sat || break                        # :unknown — cannot continue
        input = GS._model_to_input(spec, r.model)
        y = get(r.model, "out_$fname", nothing)
        cx = Counterexample(input, y, nothing)
        push!(cxs, cx)
        y === nothing || push!(tests, IOExample(input, y))
        notify_counterexample!(it, cx)
        verbose && println("  [recipe-cegis] case $(it.cases): counterexample $(input)")
    end
    verbose && println("  [recipe-cegis] ", solved !== nothing ? "VERIFIED after $n programs" :
                       it.stuck ? "stuck: no recipe fires at the last counterexample" : "stopped")
    best = solved !== nothing ? solved : last === nothing ? nothing : GS.RuleNodeGenome(last, grammar, start_symbol)
    ncx = length(cxs)
    completion = (enabled = false, single_answer = nothing, pointwise = false,
                  complete = length(tests), incomplete = 0, unique_checks = 0, unchecked = length(tests))
    harvest = (requested = :recipes, mode = :recipes, fallback = false, events = ncx, witnesses = ncx,
               added = length(tests), dup = 0, no_output = ncx - length(tests), capped = 0,
               multi_events = 0, max_per_event = ncx > 0 ? 1 : 0)
    guided = merge(GS.guided_stats(nothing), (mode = regions ? :recipes_regions : :recipes, applied = it.cases,
                                              shape_applied = it.cases, no_patch = it.stuck ? 1 : 0),
                   regions ? (regions = length(it.regions), leaf_searches = it.leaf_searches,
                              leaf_enumerations = it.leaf_enumerations,
                              region_examples = sum(length, it.region_examples; init = 0)) : NamedTuple())
    return GS.CDGPResult(solved !== nothing, best,
                         best === nothing ? "" : string(rulenode2expr(best.tree, grammar)),
                         solved !== nothing ? 0.0 : 1.0, n, 0, tests, cxs, verifications, 0,
                         Dict{String,Any}[], completion, harvest, guided)
end
