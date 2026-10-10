#!/usr/bin/env julia
#
# Iterative seeded synthesis via partial specification satisfaction.
# ==================================================================
# Finds the highest max_N solvable by repeated rounds of:
#   1. enumerate candidates bottom-up (cost-ordered), scoring each by how many
#      spec constraints it satisfies universally (in-process Z3, one
#      check-sat-assuming per constraint),
#   2. bank the smallest program per satisfied-constraint-subset,
#   3. seed the next round's bottom-up iterator with the best composite
#      building blocks (as cost-1 atoms), so `combine` grows programs on top
#      of them instead of rebuilding from scratch.
# A candidate satisfying every constraint universally IS a verified solution;
# it is additionally re-checked through the standard counterexample query.
#
# Usage: julia --project scripts/iterative_seeded_max.jl [N ...]   (default: 5)

CEGIS_ROOT = dirname(@__DIR__)
push!(LOAD_PATH, joinpath(CEGIS_ROOT, "src"))

using HerbCore, HerbGrammar, HerbSearch, HerbInterpret
using Random
include(joinpath(CEGIS_ROOT, "src", "CEGIS.jl"))

const PS = CEGIS.PartialSat
const CEX = CEGIS.CEXGeneration

# Observational-equivalence signature: evaluate a candidate on a fixed sample of
# inputs and return the output vector. The bottom-up iterator hashes this and
# keeps only ONE program per distinct behavior — collapsing the bank so `combine`
# doesn't blow up into a cartesian product of behaviorally-identical programs.
# This is what makes higher cost bounds tractable.

"""
    spec_integer_literals(spec) :: Vector{Int}

The integer literals appearing in the spec's constraints. Splitting is on the SMT-LIB
delimiters only, so an identifier stays one token and the digits inside it (`max3`,
`x10`) are never mistaken for literals.
"""
function spec_integer_literals(spec)::Vector{Int}
    out = Int[]
    for c in spec.constraints
        for tok in split(c, r"[\s()]+")
            occursin(r"^-?[0-9]+$", tok) || continue
            v = tryparse(Int, tok)
            v === nothing || push!(out, v)
        end
    end
    return sort!(unique!(out))
end

"""
    observational_samples(spec; n_samples, rng) :: Vector{Dict{Symbol,Any}}

The fixed input points behind the observational signature.

A sample drawn only from `-9:9` cannot separate programs whose behaviour differs
outside that window: on `piecewise_N`, whose thresholds are 10, 20, …, every guard that
is true across the whole sample (`x < 10`, `x < 20`, and the constant comparison
`2 < 8`) hashes to one bank cell, so the guard a solution needs is dropped in favour of
whichever arrived first — and the family becomes unsolvable for a reason that has
nothing to do with the search. The pool therefore carries the spec's own literals and
their neighbours, and spans a range wide enough to reach them, with the first points
pinned to the literals so coverage does not depend on the draw.

A spec with no integer literals (every `max_N` spec) keeps exactly the original
behaviour — 32 uniform draws from `-9:9` off the same seed — so earlier numbers stay
comparable.
"""
function observational_samples(spec; n_samples::Int, rng)::Vector{Dict{Symbol,Any}}
    vars = [Symbol(fv.name) for fv in spec.free_vars]
    consts = spec_integer_literals(spec)
    samples = Vector{Dict{Symbol,Any}}(undef, n_samples)

    if isempty(consts)
        # Mix of ties, zeros, negatives and spread values so distinct max-behaviours separate.
        for k in 1:n_samples
            samples[k] = Dict{Symbol,Any}(v => rand(rng, -9:9) for v in vars)
        end
        return samples
    end

    lo = min(-9, minimum(consts)) - 2
    hi = max(9, maximum(consts)) + 2
    # Each literal and the point just below it: that pair is what separates `x < c`
    # from `x < c+1`, and a threshold from its own boundary.
    pinned = sort!(unique!(reduce(vcat, [[c - 1, c] for c in consts])))
    pool = sort!(unique!(vcat(collect(-9:9), pinned,
                              round.(Int, range(lo, hi; length = 16)))))

    n_pinned = min(length(pinned), n_samples ÷ 2)
    for k in 1:n_pinned
        # All variables at the same literal: a diagonal point, which also exercises ties.
        samples[k] = Dict{Symbol,Any}(v => pinned[k] for v in vars)
    end
    for k in (n_pinned + 1):n_samples
        samples[k] = Dict{Symbol,Any}(v => rand(rng, pool) for v in vars)
    end
    return samples
end

function make_program_to_outputs(spec, grammar; n_samples::Int=32, seed::Int=1234)
    rng = MersenneTwister(seed)
    samples = observational_samples(spec; n_samples, rng)
    return function (prog::RuleNode)
        out = Vector{Any}(undef, n_samples)
        for (k, inp) in enumerate(samples)
            out[k] = try
                execute_on_input(grammar, prog, inp)
            catch
                nothing   # erroring programs collapse together (pruned to one)
            end
        end
        out
    end
end

# Bias costs so conditionals/comparisons surface early in the cost ordering.
function rule_costs_with_bias(grammar)
    costs = fill(1.0, length(grammar.rules))
    for (i, rule) in enumerate(grammar.rules)
        (rule isa Expr && rule.head === :call) || continue
        op = rule.args[1]
        op === :ifelse && (costs[i] = 0.2)
        op in (:<, :>, :<=, :>=, :(==)) && (costs[i] = 0.5)
    end
    costs
end

"""
Best composite building blocks to seed the next round: top `top_k` bank entries
by (constraints satisfied, then smaller), plus the greedy complementary cover.
"""
function select_seeds(bank::PS.PartialSolutionBank; top_k::Int=20)::Vector{RuleNode}
    blocks = [e for e in PS.building_blocks(bank) if e.size > 1 && e.program isa RuleNode]
    seeds = RuleNode[]
    for e in blocks[1:min(top_k, length(blocks))]
        push!(seeds, e.program)
    end
    cover = PS.complementary_cover(bank)
    if cover !== nothing
        for e in cover
            e.size > 1 && e.program isa RuleNode && !(e.program in seeds) && push!(seeds, e.program)
        end
    end
    seeds
end


"""Print the best program found at the end of each round of one problem."""

# ---------------------------------------------------------------------------
# Equivalence signatures for the bottom-up bank.
#
# The iterator dedups bank insertions by hashing whatever `program_to_outputs`
# returns, per return type. That hook is agnostic about what the vector means, so
# it can carry either notion of equivalence:
#
#   :observational — the program's outputs on a fixed sample of inputs (behaviour).
#   :constraint    — WHICH spec constraints the program satisfies universally,
#                    proved per constraint by Z3. This is predicate abstraction
#                    over the specification used as the equivalence relation.
#   :both          — the pair, i.e. the constraint subset refined by behaviour.
#
# Counters below make the drops measurable, which the observational path never was.
const SIG_CALLS = Ref(0)      # candidates that reached the equivalence gate
const SIG_DUPES = Ref(0)      # of those, ones whose signature was already seen
const SIG_TIME  = Ref(0.0)    # time spent computing signatures
const SIG_ERRORS = Ref(0)     # candidates whose signature could not be computed

function reset_sig_counters!()
    SIG_CALLS[] = 0; SIG_DUPES[] = 0; SIG_TIME[] = 0.0; SIG_ERRORS[] = 0
end

"""
    make_program_to_signature(spec, grammar, css; mode)

Build the `program_to_outputs` function for the iterator. `mode` is one of
`:observational`, `:constraint`, `:both` (env var EQUIV).

Note on types: only programs of the start type carry a meaningful constraint
signature — a boolean guard is not a candidate for the synthesised function, so
scoring it is undefined. Guards therefore keep behavioural signatures in every
mode; otherwise every guard in the grammar would collapse into a single bank
entry and the search could not build conditions at all.
"""
function make_program_to_signature(spec, grammar, css; mode::Symbol=:observational,
                                   n_samples::Int=32, seed::Int=1234)
    obs = make_program_to_outputs(spec, grammar; n_samples, seed)
    seen = Dict{Symbol,Set{Vector{UInt64}}}()   # for counting only
    function count_and_return(sig, T)
        SIG_CALLS[] += 1
        key = UInt64[hash(x) for x in sig]
        s = get!(seen, T, Set{Vector{UInt64}}())
        key in s ? (SIG_DUPES[] += 1) : push!(s, key)
        return sig
    end

    mode === :observational && return function (prog::RuleNode)
        _t = time(); sig = obs(prog); SIG_TIME[] += time() - _t
        return count_and_return(sig, :obs)
    end

    return function (prog::RuleNode)
        _t = time()
        T = HerbGrammar.return_type(grammar, prog)
        sig = if T !== :Expr
            obs(prog)                       # guards: behaviour, as explained above
        else
            try
                exprs = PS.candidate_exprs_from_rulenode(spec, grammar, prog)
                r = PS.evaluate_partial_satisfaction(css, exprs)
                mode === :both ? Any[Any[r.satisfied...]..., obs(prog)...] :
                                 Any[r.satisfied...]
            catch
                SIG_ERRORS[] += 1
                Any[:unscorable]
            end
        end
        SIG_TIME[] += time() - _t
        return count_and_return(sig, T)
    end
end

"""Print the best program found at the end of each round of one problem."""
function print_history(name::AbstractString, history::Vector{NamedTuple})
    println("\n   $name — best program per round:")
    isempty(history) && (println("     (no round completed)"); return)
    for h in history
        println("     round $(h.round): $(h.score)/$(h.n_total) constraints  size=$(h.size)  " *
                "enum=$(h.enumerated)  t=$(round(h.elapsed, digits=1))s")
        println("        $(h.expr === nothing ? "-" : h.expr)")
    end
end

function solve_spec(path::String; rounds::Int, round_enum::Int, round_time::Float64,
                    max_depth::Int, max_size::Int, max_cost::Float64, top_k::Int=20,
                    max_total_time::Float64=Inf, grammar=nothing,
                    initial_seeds::Vector{RuleNode}=RuleNode[])
    spec = CEX.parse_spec_from_file(path)
    grammar = grammar === nothing ? CEGIS.build_grammar_from_spec(path) : grammar

    varlist = join([fv.name for fv in spec.free_vars], ", ")
    println("   spec: $(length(spec.constraints)) constraint(s), free vars $varlist")
    for (i, c) in enumerate(spec.constraints)
        println("     C$i: $c")
    end
    println("   grammar: $(length(grammar.rules)) rule(s), $(count(grammar.isterminal)) terminal(s)")
    for (i, rule) in enumerate(grammar.rules)
        println("     [$(lpad(i, 2))] $(grammar.types[i]) = $rule")
    end
    flush(stdout)

    # E-graph-derived constraint generation: prune redundant candidates during
    # enumeration by adding Forbidden/Ordered constraints to the grammar BEFORE
    # the benchmark search runs. Toggle off with USE_EGRAPH=0.
    if get(ENV, "USE_EGRAPH", "1") != "0"
        egdepth = _envi("EGRAPH_DEPTH", 2)
        t_eg = @elapsed derived = CEGIS.EGraphPruning.add_derived_constraints!(grammar;
            max_depth = egdepth, verbose = true)
        println("   egraph: derived $(length(derived)) constraint(s) at pattern depth $egdepth in $(round(t_eg, digits=1))s")
        for (i, d) in enumerate(derived)
            println("     [$(lpad(i, 2))] ($(d.kind)) $(d.description)")
        end
        isempty(derived) && println("     (none — the grammar has no derivable redundancy at this depth)")
        flush(stdout)
    else
        println("   egraph: DISABLED (USE_EGRAPH=0)")
    end

    # In-process Z3: one persistent solver per spec, one check-sat-assuming per
    # constraint per candidate (vs. spawning a z3 process per candidate).
    t_css = @elapsed css = CEX.ConstraintSatSolver(spec)
    println("   scorer: in-process Z3 ConstraintSatSolver built in $(round(t_css, digits=2))s " *
            "($(length(spec.constraints)) assumption literals, push/pop per candidate)")
    println("   budget: $(rounds) round(s) max, $(round(round_time, digits=0))s + $(round_enum) enumerations per round, " *
            "$(max_total_time == Inf ? "no" : string(round(max_total_time, digits=0), "s")) per-problem cap")
    flush(stdout)
    bank = PS.PartialSolutionBank(length(spec.constraints))
    seen = Set{String}()
    costs = rule_costs_with_bias(grammar)
    equiv_mode = Symbol(get(ENV, "EQUIV", "observational"))
    equiv_mode in (:observational, :constraint, :both) ||
        error("EQUIV must be observational, constraint or both; got $equiv_mode")
    prog_outputs = make_program_to_signature(spec, grammar, css; mode = equiv_mode)
    println("   bank equivalence: $equiv_mode" *
            (equiv_mode === :observational ? " (32 sampled inputs)" :
             " (satisfied-constraint subset, Z3-proved; guards stay behavioural)"))
    history = NamedTuple[]      # per-round best, for the end-of-problem report
    t0 = time()

    for r in 1:rounds
        remaining = max_total_time - (time() - t0)
        if remaining <= 0
            println("\n-- per-problem time budget ($(round(max_total_time, digits=1))s) exhausted before round $r --")
            break
        end
        this_round_time = min(round_time, remaining)
        # Round 1 starts from whatever was carried in from the previous problem
        # (empty for the first problem in a climb); later rounds seed from the bank.
        seeds = r == 1 ? initial_seeds : select_seeds(bank; top_k)
        println("\n-- round $r/$rounds ", "-"^40)
        println("   budget: $(round(this_round_time, digits=1))s this round, $(round(remaining, digits=1))s left of the problem cap; " *
                "elapsed $(round(time() - t0, digits=1))s")
        println("   bounds: depth=$max_depth size=$max_size cost=$max_cost  |  bank subsets=$(length(bank.by_subset))  seeds=$(length(seeds))")
        println("   scored so far: $(length(seen)) distinct candidate(s); best $(bank.best === nothing ? "-" : "$(bank.best.result.n_satisfied)/$(bank.best.result.n_total)")")
        for s in seeds[1:min(8, length(seeds))]
            println("     seed: $(rulenode2expr(s, grammar))")
        end
        length(seeds) > 8 && println("     … and $(length(seeds) - 8) more")
        flush(stdout)
        iterator = PS.SeededCostBUIterator(grammar, :Expr;
            max_depth, max_size, max_cost, current_costs = costs,
            program_to_outputs = prog_outputs,
            seed_programs = seeds, seed_cost = 1.0)

        reset_sig_counters!()
        res = PS.guided_partial_search(spec, grammar, iterator;
            max_enumerations = round_enum, max_time = this_round_time,
            csat_solver = css, bank, seen, verbose = true,
            log_every = parse(Int, get(ENV, "LOG_EVERY", "1000")))

        kept = SIG_CALLS[] - SIG_DUPES[]
        pct = SIG_CALLS[] == 0 ? "n/a" : string(round(100 * SIG_DUPES[] / SIG_CALLS[], digits=1), "%")
        println("   equivalence gate ($equiv_mode): reached=$(SIG_CALLS[]) " *
                "dropped-as-equivalent=$(SIG_DUPES[]) ($pct) kept=$kept " *
                "signature-time=$(round(SIG_TIME[], digits=1))s" *
                (SIG_ERRORS[] == 0 ? "" : " unscorable=$(SIG_ERRORS[])"))
        best = bank.best
        push!(history, (; round = r, enumerated = res.enumerated, scored = res.scored,
                          reached = SIG_CALLS[], dropped = SIG_DUPES[], kept = kept,
                          sigtime = SIG_TIME[], subsets = length(bank.by_subset),
                          score = best === nothing ? 0 : best.result.n_satisfied,
                          n_total = best === nothing ? length(spec.constraints) : best.result.n_total,
                          size = best === nothing ? 0 : best.size,
                          expr = best === nothing ? nothing : best.expr,
                          elapsed = time() - t0))
        println("   round $r: enumerated=$(res.enumerated) scored=$(res.scored) " *
                "best=$(best === nothing ? "-" : "$(best.result.n_satisfied)/$(best.result.n_total)  $(best.expr)") " *
                " subsets=$(length(bank.by_subset))  elapsed=$(round(time() - t0, digits=1))s")
        # Building-block bank snapshot — what future rounds can seed from.
        blocks = PS.building_blocks(bank)
        println("   bank (top building blocks, best first):")
        for e in blocks[1:min(12, length(blocks))]
            println("     $(e.result.n_satisfied)/$(e.result.n_total)  constraints=$(findall(e.result.satisfied))  size=$(e.size)  $(e.expr)")
        end
        length(blocks) > 12 && println("     … and $(length(blocks) - 12) more subsets")
        cover = PS.complementary_cover(bank)
        if cover === nothing
            println("   complementary cover: banked blocks do NOT yet jointly cover all constraints")
        else
            println("   complementary cover ($(length(cover)) blocks span all $(bank.n_total) constraints):")
            for e in cover
                println("     covers $(findall(e.result.satisfied))  =>  $(e.expr)")
            end
        end
        flush(stdout)

        if res.full !== nothing
            exprs = PS.candidate_exprs_from_rulenode(spec, grammar, res.full.program)
            v = CEX.verify_query(CEX.generate_query(spec, exprs))
            println("   independent full-spec verification: $(v.status == :unsat ? "PASS" : "FAIL ($(v.status))")")
            print_history(basename(path), history)
            return (; solved = v.status == :unsat, program = res.full.expr,
                      node = res.full.program, bank, grammar, history,
                      round = r, time = time() - t0)
        end
    end
    print_history(basename(path), history)
    return (; solved = false,
              program = bank.best === nothing ? nothing : bank.best.expr,
              node = bank.best === nothing ? nothing : bank.best.program,
              bank, grammar, history,
              round = rounds, time = time() - t0)
end

# Bounds sized to the nested-ifelse max_N solution: depth 2N-1, size s_N where
# s_2 = 6 and s_{k+1} = 2 s_k + 4 — plus headroom for one extra wrap.
solution_size(n) = n <= 2 ? 6 : 2 * solution_size(n - 1) + 4

_envi(k, d) = parse(Int, get(ENV, k, string(d)))
_envf(k, d) = parse(Float64, get(ENV, k, string(d)))

"""
Spec-specialised grammar for the max_N family: the input variables, `ifelse`, and
the two strict comparisons — nothing else. A nested-ifelse maximum needs no
arithmetic, no constants and no Bool-to-Int coercion, so including them only
inflates the space the iterator has to walk. Disable with MINIMAL_GRAMMAR=0 to
fall back on the generic LIA grammar.
"""
function max_n_grammar(n::Int)
    vars = join(["x$i" for i in 1:n], " | ")
    src = """
    @csgrammar begin
        Expr = $vars
        Expr = ifelse(BoolExpr, Expr, Expr)
        BoolExpr = (Expr > Expr)
        BoolExpr = (Expr < Expr)
    end
    """
    return eval(Meta.parse(src))
end


"""
Remap a `RuleNode` built over `max_n_grammar(n_old)` into the rule indices of
`max_n_grammar(n_new)`. The two grammars share a layout — rules `1..n` are the
variables `x1..xn`, followed by `ifelse`, `>`, `<` — so a variable index is
unchanged and every operator index shifts by `n_new - n_old`. This is what lets
a solved max_N program be handed to the max_{N+1} search as a building block.
"""
function remap_rulenode(node::RuleNode, n_old::Int, n_new::Int)::RuleNode
    shift = n_new - n_old
    idx = node.ind <= n_old ? node.ind : node.ind + shift
    isempty(node.children) && return RuleNode(idx)
    return RuleNode(idx, RuleNode[remap_rulenode(c, n_old, n_new) for c in node.children])
end

"""
Seeds to carry from a solved (or partially solved) max_`n_old` into max_`n_new`:
the solution itself plus the best composite building blocks from its bank, all
remapped into the new grammar. A max_4 solution seeds max_5 directly, since
max_5 = ifelse(max_4(x1..x4) > x5, max_4(x1..x4), x5).
"""
function carry_over_seeds(prev, n_old::Int, n_new::Int; top_k::Int=12)::Vector{RuleNode}
    prev === nothing && return RuleNode[]
    out = RuleNode[]
    if prev.node !== nothing && prev.node isa RuleNode
        push!(out, remap_rulenode(prev.node, n_old, n_new))
    end
    for e in PS.building_blocks(prev.bank)
        length(out) >= top_k + 1 && break
        e.size > 1 && e.program isa RuleNode || continue
        node = remap_rulenode(e.program, n_old, n_new)
        node in out || push!(out, node)
    end
    return out
end

function run_max(n::Int; rounds = _envi("ROUNDS", 2n),
                 round_enum = _envi("ROUND_ENUM", 200_000),
                 round_time = _envf("ROUND_TIME", 180.0),
                 problem_time = _envf("PROBLEM_TIME", 300.0),
                 initial_seeds::Vector{RuleNode} = RuleNode[])
    path = joinpath(CEGIS_ROOT, "benchmarks", "max_n", "max$n.sl")
    println("\n" * "="^72)
    println("max$n  ($(n + 1) constraints)  —  spec $path")
    println("="^72)
    flush(stdout)
    grammar = get(ENV, "MINIMAL_GRAMMAR", "1") == "0" ? nothing : max_n_grammar(n)
    grammar === nothing && println("   grammar: generic LIA (MINIMAL_GRAMMAR=0)")
    if !isempty(initial_seeds)
        println("   carried over $(length(initial_seeds)) seed(s) from max$(n - 1) (remapped into this grammar)")
    end
    r = solve_spec(path; rounds, round_enum, round_time, grammar, initial_seeds,
        max_total_time = problem_time,
        max_depth = _envi("MAX_DEPTH", 2n + 3),
        max_size = _envi("MAX_SIZE", round(Int, 1.5 * solution_size(n))),
        max_cost = _envf("MAX_COST", 6.0))
    if r.solved
        println(">>> max$n SOLVED in round $(r.round), $(round(r.time, digits=1))s: $(r.program)")
    else
        println(">>> max$n NOT solved after $(r.round) rounds, $(round(r.time, digits=1))s. Best: $(r.program)")
    end
    r
end

# CLI entry — only when run directly (so other scripts can `include` this file
# and reuse solve_spec / helpers without triggering the maxN climb).
if abspath(PROGRAM_FILE) == @__FILE__
    ns = isempty(ARGS) ? [5] : parse.(Int, ARGS)
    results = Dict{Int,Any}()
    prev, prev_n = nothing, 0
    for n in ns
        global prev, prev_n
        seeds = prev === nothing ? RuleNode[] : carry_over_seeds(prev, prev_n, n)
        results[n] = run_max(n; initial_seeds = seeds)
        # Carry forward from the last problem that produced anything, solved or
        # not — a strong partial program is still a useful building block.
        if results[n].node !== nothing
            prev, prev_n = results[n], n
        end
    end

    println("\n" * "="^72)
    println("SUMMARY")
    for n in sort(collect(keys(results)))
        r = results[n]
        println("  max$n: $(r.solved ? "SOLVED (round $(r.round), $(round(r.time, digits=1))s)" : "unsolved ($(round(r.time, digits=1))s)") $(r.program === nothing ? "" : "— $(r.program)")")
    end
end
