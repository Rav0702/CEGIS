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
function make_program_to_outputs(spec, grammar; n_samples::Int=32, seed::Int=1234)
    rng = MersenneTwister(seed)
    vars = [Symbol(fv.name) for fv in spec.free_vars]
    # Mix of ties, zeros, negatives, and spread values so distinct max-behaviors separate.
    samples = Vector{Dict{Symbol,Any}}(undef, n_samples)
    for k in 1:n_samples
        samples[k] = Dict{Symbol,Any}(v => rand(rng, -9:9) for v in vars)
    end
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

function solve_spec(path::String; rounds::Int, round_enum::Int, round_time::Float64,
                    max_depth::Int, max_size::Int, max_cost::Float64, top_k::Int=20,
                    max_total_time::Float64=Inf)
    spec = CEX.parse_spec_from_file(path)
    grammar = CEGIS.build_grammar_from_spec(path)
    # E-graph-derived constraint generation: prune redundant candidates during
    # enumeration by adding Forbidden/Ordered constraints to the grammar BEFORE
    # the benchmark search runs. Toggle off with USE_EGRAPH=0.
    if get(ENV, "USE_EGRAPH", "1") != "0"
        derived = CEGIS.EGraphPruning.add_derived_constraints!(grammar;
            max_depth = _envi("EGRAPH_DEPTH", 2), verbose = true)
        println("   egraph: derived $(length(derived)) constraint(s) at depth $(_envi("EGRAPH_DEPTH", 2))")
        flush(stdout)
    end
    css = CEX.ConstraintSatSolver(spec)
    bank = PS.PartialSolutionBank(length(spec.constraints))
    seen = Set{String}()
    costs = rule_costs_with_bias(grammar)
    prog_outputs = make_program_to_outputs(spec, grammar)   # observational-equivalence dedup
    t0 = time()

    for r in 1:rounds
        remaining = max_total_time - (time() - t0)
        if remaining <= 0
            println("\n-- per-problem time budget ($(round(max_total_time, digits=1))s) exhausted before round $r --")
            break
        end
        this_round_time = min(round_time, remaining)
        seeds = r == 1 ? RuleNode[] : select_seeds(bank; top_k)
        println("\n-- round $r ", "-"^40)
        println("   bounds: depth=$max_depth size=$max_size cost=$max_cost  |  bank subsets=$(length(bank.by_subset))  seeds=$(length(seeds))")
        for s in seeds[1:min(8, length(seeds))]
            println("     seed: $(rulenode2expr(s, grammar))")
        end
        length(seeds) > 8 && println("     … and $(length(seeds) - 8) more")
        flush(stdout)
        iterator = PS.SeededCostBUIterator(grammar, :Expr;
            max_depth, max_size, max_cost, current_costs = costs,
            program_to_outputs = prog_outputs,
            seed_programs = seeds, seed_cost = 1.0)

        res = PS.guided_partial_search(spec, grammar, iterator;
            max_enumerations = round_enum, max_time = this_round_time,
            csat_solver = css, bank, seen, verbose = true,
            log_every = parse(Int, get(ENV, "LOG_EVERY", "1000")))

        best = bank.best
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
            return (; solved = v.status == :unsat, program = res.full.expr,
                      round = r, time = time() - t0)
        end
    end
    return (; solved = false,
              program = bank.best === nothing ? nothing : bank.best.expr,
              round = rounds, time = time() - t0)
end

# Bounds sized to the nested-ifelse max_N solution: depth 2N-1, size s_N where
# s_2 = 6 and s_{k+1} = 2 s_k + 4 — plus headroom for one extra wrap.
solution_size(n) = n <= 2 ? 6 : 2 * solution_size(n - 1) + 4

_envi(k, d) = parse(Int, get(ENV, k, string(d)))
_envf(k, d) = parse(Float64, get(ENV, k, string(d)))

function run_max(n::Int; rounds = _envi("ROUNDS", 2n),
                 round_enum = _envi("ROUND_ENUM", 200_000),
                 round_time = _envf("ROUND_TIME", 180.0))
    path = joinpath(CEGIS_ROOT, "benchmarks", "max_n", "max$n.sl")
    println("\n" * "="^72)
    println("max$n  ($(n + 1) constraints)")
    println("="^72)
    flush(stdout)
    r = solve_spec(path; rounds, round_enum, round_time,
        max_depth = _envi("MAX_DEPTH", 2n + 3),
        max_size = _envi("MAX_SIZE", round(Int, 1.5 * solution_size(n))),
        max_cost = _envf("MAX_COST", 8.0))
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
    for n in ns
        results[n] = run_max(n)
        results[n].solved || break   # stop climbing once an N fails
    end

    println("\n" * "="^72)
    println("SUMMARY")
    for n in sort(collect(keys(results)))
        r = results[n]
        println("  max$n: $(r.solved ? "SOLVED (round $(r.round), $(round(r.time, digits=1))s)" : "unsolved") $(r.program === nothing ? "" : "— $(r.program)")")
    end
end
