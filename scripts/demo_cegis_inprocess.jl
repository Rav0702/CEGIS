"""
demo_cegis_inprocess.jl

Solves the max-of-two ("z2"/max2) synthesis problem with an in-process,
per-constraint verifier and prints **exactly which constraints each candidate
fails**.

This is CEGIS with a sound universal verifier: the inductive synthesizer enumerates
candidates from the grammar; each candidate is checked against every spec constraint
with the warm in-process `ConstraintSatSolver` (Method 2 — `check-sat-assuming` on a
persistent `Z3.Solver`). A constraint is "failing" iff some input violates it
(`:sat`); a candidate that satisfies **all** constraints universally has no
counterexample, so it is a formally verified solution and the loop stops.

Run:  julia --project=. scripts/demo_cegis_inprocess.jl
"""

const ROOT = dirname(@__DIR__)
push!(LOAD_PATH, joinpath(ROOT, "src"))
include(joinpath(ROOT, "src", "CEGIS.jl"))
using HerbCore, HerbGrammar
import HerbConstraints
using Printf
const CG = CEGIS.CEXGeneration

const MAX_ENUM = 5000
const MAX_DEPTH = 4

idxset(v) = isempty(v) ? "{}" : "{" * join(v, ",") * "}"

function find_spec(name)
    for p in (joinpath(ROOT, "spec_files", "phase3_benchmarks", "$name.sl"),
              joinpath(ROOT, "spec_files", "$name.sl"))
        isfile(p) && return p
    end
    error("spec $name not found under spec_files/")
end

function main()
    spec_path = find_spec("max2_simple")
    spec    = CG.parse_spec_from_file(spec_path)
    grammar = CEGIS.build_grammar_from_spec(spec_path)
    fn      = spec.synth_funs[1].name

    # Persistent in-process verifier: constraint AST built once, reused per candidate.
    css = CG.ConstraintSatSolver(spec)

    println("="^74)
    println("CEGIS (in-process per-constraint verifier) — synthesize $fn (max of two)")
    println("="^74)
    println("Spec constraints:")
    for (i, c) in enumerate(spec.constraints)
        println("  [$i] $c")
    end
    println("\nEnumerating candidates  (✓ = holds ∀ inputs,  ✗ = some input violates it)")
    println("-"^74)

    iterator = CEGIS.IteratorConfig.create_iterator(
        CEGIS.IteratorConfig.BFSIteratorConfig(max_depth=MAX_DEPTH), grammar, :Expr)

    n = 0
    for prog in iterator
        n += 1
        n > MAX_ENUM && (println("\nGave up after $MAX_ENUM candidates."); return)

        node = prog isa RuleNode ? prog : HerbConstraints.freeze_state(prog)
        smt = try
            CG.rulenode_to_smt2(node, grammar)
        catch
            continue            # skip candidates the converter can't handle
        end

        r = CG.check_constraint_satisfaction(css, fn, smt)
        expr = string(rulenode2expr(node, grammar))
        failing = CG.violated_indices(r)

        @printf("#%-5d %-30s  %d/%d ✓   failing=%s\n",
                n, first(expr, 30), CG.n_satisfied(r), length(r.satisfied), idxset(failing))

        if CG.all_satisfied(r)
            println("-"^74)
            println("✓ SOLVED after $n candidates — verified for all inputs (no counterexample):")
            println("    $expr")
            println("    SMT: $smt")
            return
        end
    end
    println("\nGrammar exhausted without a solution at depth ≤ $MAX_DEPTH.")
end

main()
