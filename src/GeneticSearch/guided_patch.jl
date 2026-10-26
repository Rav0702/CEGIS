"""
    guided_patch.jl

`GuidedPatchMutation` — the stage 2 guarded patch (RQ1_RQ2_PLAN.md §7.3a–§7.5) as a
mutation operator for the test-based CDGP evaluator (`run_cdgp(...; guided=:patch)`).

For a parent that fails some accumulated tests and passes at least `min_pass` of them:
localize with the SMT single-node correction check (`repairable_paths`; candidates are the
nodes executed on a failing test; sites are the minimal repairable nodes plus the root),
draw a site, build its partial guarded repairs (`site_patches`), and write one,
`n := ite(g, e, n)`. By construction the child passes every test the parent passed and at
least one it failed. Every other case falls back to ordinary subtree mutation, so the
operator is a drop-in replacement for `GrammarSubtreeMutation`. It is the single mutation
operator the engine sees, because Arborist samples its operators uniformly.

Cost is rationed deterministically (no clocks, so a seed replays):
- a mutation attempts the guided path with probability `rate`;
- each generation has `budget` tokens: one is spent per localization and one per site
  build (`guided_new_generation!` refills them from the run's per-generation callback);
- analyses are cached per program. Lexicase picks the same few specialists many times, so
  most attempts are cache hits.

The evidence is the evaluator's accumulated tests only: complete tests (`ok` = expected
output) and, when the spec is pointwise-evaluable, incomplete tests (`ok` = every
constraint holds at that input). Nothing here calls the evaluator's own Z3 solvers; the
localization runs in a Z3 context of its own.

`placebo=true` does the same work (same eligibility, sites, tokens and patch builds) and
writes a random subtree at the drawn site instead of the patch. That is the control that
separates "more effort spent on failing parents" from "the right content".

**v2 options** (RQ1_RQ2_PLAN.md §7.10; the defaults reproduce v1 exactly):
- `sites=:l3_sampled` — localize over the root plus `candidates - 1` active nodes drawn at
  random, instead of every active node (`:l3`);
- `extra` — term-pool depth for `site_patches` (v1: 3);
- `max_pass` — build localizations and patches on the failing tests plus the `max_pass`
  most recent passing tests; the drawn patch is then **validated on every passing test**
  before it is written (up to 3 draws), which keeps the never-break guarantee;
- `keep_cache=true` — when the test set grows, keep a program's sites and patch lists and
  re-split its evidence (cheap); drawn patches are validated against the current tests.
Per-phase timers (`t_evidence`, `t_localize`, `t_build`, `t_validate`) are always recorded.

**v3 option** `shapes=:spec` (RQ1_RQ2_PLAN.md §7.10b): spec-derived answer patches
(`constraint_patches.jl`). A recipe `ite(G_t, t, ·)` whose guard fires at one of the parent's failing
tests is written at the root (validated on every passing test) in preference to a localized site
patch; the localization is skipped for such parents. Recipes are sound and general by
construction, so they do not memorize tests. Ignored for the placebo.

**Ablation options** (RQ1_RQ2_PLAN.md §7.12): `sites=:none` skips localization and site patches
entirely; `fallback=:keep` returns the parent unchanged wherever subtree mutation would otherwise
be used. With `shapes=:spec`, `rate=1.0` and crossover off, answer recipes are then the GA's only
source of variation (arm `lex-recipes-only`).
"""

const _GUIDED_COUNTS = (:attempts, :applied, :analyses, :site_builds, :cache_hits, :ineligible,
                        :no_site, :no_patch, :budget_skip, :depth_reject, :validate_reject,
                        :shape_applied, :shape_reject)
const _GUIDED_TIMES = (:time_s, :t_evidence, :t_localize, :t_build, :t_validate)
const _GUIDED_STATS = (_GUIDED_COUNTS..., _GUIDED_TIMES...)

"""One piece of evidence: program input, verdict on an output, and its localization form."""
struct _GuidedItem
    input::Dict{Symbol,Any}
    ok::Function
    complete::Union{Tuple{Dict{Symbol,Any},Any},Nothing}   # (input, expected) for a complete test
    binding::Union{Dict{String,Any},Nothing}               # free-var binding for an incomplete test
end

"""Per-program analysis: evidence split by the parent's verdicts, and its sites."""
mutable struct _GuidedEntry
    eligible::Bool
    version::Int                      # evidence size the split was computed on
    fail::Vector{Any}                 # (input, ok) pairs the parent fails
    pass::Vector{Any}                 # (input, ok) pairs the parent passes
    sites::Vector{NodePath}
    patches::Dict{NodePath,Vector{Tuple{RuleNode,RuleNode,Int}}}
    recipes::Vector{Int}              # v3: answer recipes firing at a failing test
end

_GuidedEntry(eligible::Bool, version::Int = -1) =
    _GuidedEntry(eligible, version, Any[], Any[], NodePath[],
                 Dict{NodePath,Vector{Tuple{RuleNode,RuleNode,Int}}}(), Int[])

"""
    GuidedPatchMutation(grammar, subtree_depth, depth_cap, evaluator;
                        rate=0.3, budget=2, min_pass=8, placebo=false, normalize=false,
                        timeout_ms=500, sites=:l3, candidates=6, extra=3,
                        max_pass=typemax(Int), keep_cache=false, shapes=:none)

See the file header. `min_pass=8`: the stage 2 patches only beat random content when the
parent passed more than ~8 tests (fewer leave the guard under-constrained). `timeout_ms`
bounds each localization check.
"""
mutable struct GuidedPatchMutation <: Arborist.AbstractMutationOperator
    fallback::GrammarSubtreeMutation
    evaluator::CDGPEvaluator
    kit::PatchKit
    rate::Float64
    budget::Int
    min_pass::Int
    placebo::Bool
    timeout_ms::Int
    sites::Symbol
    candidates::Int
    extra::Int
    max_pass::Int
    keep_cache::Bool
    shapes::Symbol
    fallback_mode::Symbol            # :subtree (subtree mutation) | :keep (return the parent unchanged)
    recipes::Vector{AnswerRecipe}
    ite_rule::Int
    fname::String
    tokens::Int
    version::Int                     # evidence size the cache was built on (v1 clearing)
    cache::Dict{String,_GuidedEntry}
    stats::Dict{Symbol,Float64}
end

function GuidedPatchMutation(grammar::AbstractGrammar, subtree_depth::Int, depth_cap::Int,
                             evaluator::CDGPEvaluator; rate::Float64 = 0.3, budget::Int = 2,
                             min_pass::Int = 8, placebo::Bool = false, normalize::Bool = false,
                             timeout_ms::Int = 500, sites::Symbol = :l3, candidates::Int = 6,
                             extra::Int = 3, max_pass::Int = typemax(Int), keep_cache::Bool = false,
                             shapes::Symbol = :none, fallback::Symbol = :subtree)
    0.0 <= rate <= 1.0 || throw(ArgumentError("guided rate must be in [0, 1], got $rate"))
    budget >= 0 || throw(ArgumentError("guided budget must be ≥ 0, got $budget"))
    sites in (:l3, :l3_sampled, :none) ||
        throw(ArgumentError("guided sites must be :l3, :l3_sampled or :none, got :$sites"))
    fallback in (:subtree, :keep) || throw(ArgumentError("guided fallback must be :subtree or :keep, got :$fallback"))
    candidates >= 1 && extra >= 0 && max_pass >= 1 ||
        throw(ArgumentError("guided candidates ≥ 1, extra ≥ 0, max_pass ≥ 1 required"))
    shapes in (:none, :spec) || throw(ArgumentError("guided shapes must be :none or :spec, got :$shapes"))
    kit = PatchKit(grammar)
    recipes = shapes === :spec && !placebo ?
        something(spec_answer_recipes(evaluator.spec, grammar), AnswerRecipe[]) : AnswerRecipe[]
    GuidedPatchMutation(GrammarSubtreeMutation(grammar, subtree_depth, depth_cap; normalize = normalize),
                        evaluator, kit, rate, budget, min_pass, placebo, timeout_ms,
                        sites, candidates, extra, max_pass, keep_cache, shapes, fallback, recipes, kit.ite,
                        evaluator.spec.synth_funs[1].name,
                        budget, -1, Dict{String,_GuidedEntry}(),
                        Dict{Symbol,Float64}(k => 0.0 for k in _GUIDED_STATS))
end

Arborist.operator_name(::GuidedPatchMutation) = :GuidedPatchMutation

"""Start of a generation: refill the analysis budget."""
guided_new_generation!(op::GuidedPatchMutation) = (op.tokens = op.budget; nothing)

"""
Counters of what the guided path did (`time_s` and `t_*` are seconds, the rest counts):
`attempts` guided draws; `applied` children written by the guided path; `analyses`
localizations run; `site_builds` patch lists built; `cache_hits` attempts served from the
cache; `ineligible` attempts on test-perfect parents or parents passing < `min_pass` tests;
`no_site` no repairable node; `no_patch` no patch at the drawn site; `budget_skip` out of
tokens; `depth_reject` child over the depth cap; `validate_reject` drawn patches that broke a
passing test (v2 validation); `shape_applied` / `shape_reject` v3 answer patches written /
rejected (broke a passing test or over the depth cap); `time_s` time in guided attempts, split into `t_evidence`
(test verdicts), `t_localize` (active nodes + SMT), `t_build` (`site_patches`) and
`t_validate`. Every attempt that is not `applied` fell back to subtree mutation.
"""
guided_stats(op::GuidedPatchMutation) =
    (; mode = op.placebo ? :placebo : :patch,
     (k => (k in _GUIDED_TIMES ? round(op.stats[k]; digits = 4) : Int(op.stats[k])) for k in _GUIDED_STATS)...)
guided_stats(::Nothing) =
    (; mode = :none, (k => (k in _GUIDED_TIMES ? 0.0 : 0) for k in _GUIDED_STATS)...)

"""The evaluator's tests split into those `g` fails and passes, as `_GuidedItem`s (or `nothing`)."""
function _guided_evidence(e::CDGPEvaluator, g::RuleNodeGenome)
    expr = rulenode2expr(g.tree, e.grammar)
    fail, pass = _GuidedItem[], _GuidedItem[]
    for io in e.test_cases
        out = try
            execute_on_input(e.symboltable, expr, io.in)
        catch
            return nothing
        end
        y = io.out
        push!(out == y ? pass : fail, _GuidedItem(io.in, o -> o == y, (io.in, io.out), nothing))
    end
    tc = e.completion
    if tc.pointwise
        for b in e.incomplete
            loss = _incomplete_loss(tc, e.symboltable, expr, b)
            isfinite(loss) || return nothing
            ok = o -> all(sx -> (try
                CEXGeneration.eval_constraint_pointwise(sx, tc.fname, b, _ -> o)
            catch
                false
            end), tc.sexprs)
            push!(loss == 0 ? pass : fail, _GuidedItem(_model_to_input(e.spec, b), ok, nothing, b))
        end
    end
    return fail, pass
end

_pairs(items) = Any[(it.input, it.ok) for it in items]
"""The passing tests a v2 build uses: the `max_pass` most recent (all when uncapped)."""
_recent(items, m) = length(items) > m ? items[end-m+1:end] : items

function _guided_analyze(op::GuidedPatchMutation, g::RuleNodeGenome, rng::AbstractRNG)::_GuidedEntry
    e = op.evaluator
    v = length(e.test_cases) + length(e.incomplete)
    t0 = time()
    ev = _guided_evidence(e, g)
    op.stats[:t_evidence] += time() - t0
    ev === nothing && return _GuidedEntry(false, v)
    fail, pass = ev
    (isempty(fail) || length(pass) < op.min_pass) && return _GuidedEntry(false, v)
    if !isempty(op.recipes)
        fires = _firing(op, g.tree, [it.input for it in fail])
        if !isempty(fires)                       # v3: a spec answer covers a failing test
            entry = _GuidedEntry(true, v)
            entry.fail, entry.pass, entry.recipes = _pairs(fail), _pairs(pass), fires
            return entry
        end
    end
    if op.sites === :none                        # ablation: no localization, no site patches
        entry = _GuidedEntry(true, v)
        entry.fail, entry.pass = _pairs(fail), _pairs(pass)
        return entry
    end
    t1 = time()
    act = Set{NodePath}()
    for it in fail
        try
            union!(act, active_paths(g.tree, e.grammar, e.symboltable, it.input))
        catch
        end
    end
    cands = sort!(collect(act))
    if op.sites === :l3_sampled && length(cands) > op.candidates
        rest = filter(!isempty, cands)
        pick = rest[randperm(rng, length(rest))[1:min(op.candidates - 1, length(rest))]]
        cands = sort!(unique([NodePath[Int[]]; pick]))
    end
    locev = if op.max_pass == typemax(Int)      # v1: every test, in the evaluator's order
        LocEvidence(Tuple{Dict{Symbol,Any},Any}[(io.in, io.out) for io in e.test_cases],
                    e.completion.pointwise ? copy(e.incomplete) : Dict{String,Any}[])
    else                                        # v2: failing + the most recent passing tests
        items = vcat(fail, _recent(pass, op.max_pass))
        LocEvidence(Tuple{Dict{Symbol,Any},Any}[it.complete for it in items if it.complete !== nothing],
                    Dict{String,Any}[it.binding for it in items if it.binding !== nothing])
    end
    rep, minimal, _ = try
        repairable_paths(g.tree, e.grammar, e.spec, locev;
                         timeout_ms = op.timeout_ms, candidates = cands)
    catch
        (Dict{NodePath,Vector}(), NodePath[], nothing)
    end
    op.stats[:t_localize] += time() - t1
    sites = haskey(rep, Int[]) ? unique([sort(minimal); [Int[]]]) : sort(minimal)
    entry = _GuidedEntry(true, v)
    entry.fail, entry.pass, entry.sites = _pairs(fail), _pairs(pass), sites
    return entry
end

"""
Indices of the answer recipes whose guard holds at one of `inputs` and whose patch of `tree` still
fits under the depth cap. A spec whose case list is deeper than the cap (countpos4.split: 16 regions,
cap 12) then falls back to the v2 localized patches instead of retrying rejected recipes.
"""
function _firing(op::GuidedPatchMutation, tree::RuleNode, inputs)
    d = depth(tree)
    fits(r) = r.guard === nothing ? depth(r.term) <= op.fallback.depth_cap :
        1 + max(d, depth(r.guard), depth(r.term)) <= op.fallback.depth_cap
    return [i for i in eachindex(op.recipes)
            if fits(op.recipes[i]) && any(x -> recipe_fires(op.recipes[i], op.fname, x), inputs)]
end

"""Re-split a kept entry's evidence after the test set grew (v2 `keep_cache`)."""
function _guided_refresh!(op::GuidedPatchMutation, entry::_GuidedEntry, g::RuleNodeGenome, v::Int)
    t0 = time()
    ev = _guided_evidence(op.evaluator, g)
    op.stats[:t_evidence] += time() - t0
    if ev === nothing || isempty(ev[1]) || length(ev[2]) < op.min_pass
        entry.eligible = false
    else
        entry.fail, entry.pass = _pairs(ev[1]), _pairs(ev[2])
        isempty(op.recipes) || (entry.recipes = _firing(op, g.tree, [it.input for it in ev[1]]))
    end
    entry.version = v
    return entry
end

"""Does `tree` pass every one of the `(input, ok)` pairs?"""
function _passes_all(op::GuidedPatchMutation, tree::RuleNode, items)
    e = op.evaluator
    expr = rulenode2expr(tree, e.grammar)
    for (inp, ok) in items
        out = try
            execute_on_input(e.symboltable, expr, inp)
        catch
            return false
        end
        ok(out isa Bool ? Int(out) : out) || return false
    end
    return true
end

"""The guided child, or `nothing` to fall back to subtree mutation."""
function _guided_child(op::GuidedPatchMutation, g::RuleNodeGenome, rng::AbstractRNG)
    e = op.evaluator
    v = length(e.test_cases) + length(e.incomplete)
    if !op.keep_cache && v != op.version     # v1: the test set grew, every analysis is stale
        empty!(op.cache)
        op.version = v
    end
    key = Arborist.serialize(g)
    entry = get(op.cache, key, nothing)
    if entry === nothing
        op.tokens > 0 || (op.stats[:budget_skip] += 1; return nothing)
        op.tokens -= 1
        op.stats[:analyses] += 1
        entry = op.cache[key] = _guided_analyze(op, g, rng)
    else
        op.stats[:cache_hits] += 1
        op.keep_cache && entry.eligible && entry.version != v && _guided_refresh!(op, entry, g, v)
    end
    entry.eligible || (op.stats[:ineligible] += 1; return nothing)
    if !isempty(entry.recipes)                   # v3: spec answer patch at the root
        for _ in 1:3
            c = answer_patch(g.tree, op.recipes[rand(rng, entry.recipes)], op.ite_rule)
            t0 = time()
            ok = c !== nothing && depth(c) <= op.fallback.depth_cap && _passes_all(op, c, entry.pass)
            op.stats[:t_validate] += time() - t0
            if ok
                op.stats[:shape_applied] += 1
                op.stats[:applied] += 1
                return RuleNodeGenome(c, g.grammar, g.start_symbol)
            end
            op.stats[:shape_reject] += 1
        end
        return nothing
    end
    isempty(entry.sites) && (op.stats[:no_site] += 1; return nothing)
    p = rand(rng, entry.sites)
    pats = get(entry.patches, p, nothing)
    if pats === nothing
        op.tokens > 0 || (op.stats[:budget_skip] += 1; return nothing)
        op.tokens -= 1
        op.stats[:site_builds] += 1
        t0 = time()
        pats = entry.patches[p] = site_patches(op.kit, g.tree, p, entry.fail,
                                               _recent(entry.pass, op.max_pass); extra = op.extra)
        op.stats[:t_build] += time() - t0
    end
    isempty(pats) && (op.stats[:no_patch] += 1; return nothing)
    # v2 builds on a subset of the passing tests (or on stale evidence): validate on all of them.
    validate = op.max_pass < length(entry.pass) || op.keep_cache
    t = nothing
    rejected = false
    for _ in 1:(validate ? 3 : 1)
        c = if op.placebo
            tt = deepcopy(g.tree)
            sym = return_type(e.grammar, node_at(tt, p))
            insert!(tt, nodeloc_at(tt, p), rand(RuleNode, e.grammar, sym, op.fallback.subtree_depth))
            tt
        else
            gd, ex, _ = rand(rng, pats)
            guarded_patch(g.tree, p, op.kit, gd, ex)
        end
        if c !== nothing && validate && !op.placebo
            t0 = time()
            okc = _passes_all(op, c, entry.pass)
            op.stats[:t_validate] += time() - t0
            okc || (op.stats[:validate_reject] += 1; rejected = true; continue)
        end
        t = c
        rejected = false
        break
    end
    rejected && return nothing                       # every drawn patch broke a passing test
    (t === nothing || depth(t) > op.fallback.depth_cap) && (op.stats[:depth_reject] += 1; return nothing)
    op.stats[:applied] += 1
    return RuleNodeGenome(t, g.grammar, g.start_symbol)
end

function Arborist.mutate(op::GuidedPatchMutation, g::RuleNodeGenome, rng::AbstractRNG)
    rand(rng) < op.rate || return _fallback(op, g, rng)
    op.stats[:attempts] += 1
    t0 = time()
    child = _guided_child(op, g, rng)
    op.stats[:time_s] += time() - t0
    return child === nothing ? _fallback(op, g, rng) : child
end

"""Whatever the guided path could not do: subtree mutation, or (ablation `fallback=:keep`) the parent itself."""
_fallback(op::GuidedPatchMutation, g::RuleNodeGenome, rng::AbstractRNG) =
    op.fallback_mode === :keep ? g : Arborist.mutate(op.fallback, g, rng)
