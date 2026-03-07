"""
╔══════════════════════════════════════════════════════════════════════════════╗
║              CEGIS Full Pipeline — Pseudocode / Demo Script                 ║
║                                                                              ║
║  This file is the single entry-point that wires all components together.    ║
║  It is written as *executable pseudocode*: every function call is real       ║
║  Julia code, but the functions themselves are stubs that throw "not yet     ║
║  implemented" errors (see the src/ files).                                  ║
║                                                                              ║
║  Goal: show the complete information-flow of CEGIS so that each stub can   ║
║  be filled in independently without losing sight of the big picture.        ║
╚══════════════════════════════════════════════════════════════════════════════╝

CEGIS (Counterexample-Guided Inductive Synthesis) — Algorithm Overview
=======================================================================

         ┌────────────────────────────────────────────────────────────┐
         │                   INPUTS                                   │
         │  • Grammar G  (search space of programs)                   │
         │  • Specification φ  (initial IO examples or SMT formula)   │
         │  • Oracle Ψ  (verifier / checker — the source of truth)    │
         └─────────────────────────┬──────────────────────────────────┘
                                   │
                    ╔══════════════▼══════════════╗
                    ║        SYNTHESIZER           ║  finds P ∈ G s.t. P ⊨ φ
                    ╚══════════════╤══════════════╝
                                   │ candidate P
                    ╔══════════════▼══════════════╗
                    ║         VERIFIER / ORACLE    ║  checks P ⊨ Ψ (all inputs)
                    ╚══════════════╤══════════════╝
                                   │
               ┌───────────────────┴────────────────────────────────┐
               │ verified?                                           │
           YES │                                                  NO │
               ▼                                                     ▼
           OUTPUT P                                         COUNTEREXAMPLE cx
                                                                     │
                                              ╔══════════════════════▼══════╗
                                              ║   COUNTEREXAMPLE MANAGER     ║
                                              ║   • minimize_counterexample  ║
                                              ║   • is_duplicate?            ║
                                              ╚══════════════════════╤══════╝
                                                                     │
                                              ╔══════════════════════▼══════╗
                                              ║         LEARNER              ║
                                              ║   • learn_constraint(cx)     ║
                                              ║   • add to grammar G         ║
                                              ╚══════════════════════╤══════╝
                                                                     │
                                              φ ← φ ∪ {IOExample(cx)}│
                                                                     │
                                              ─────────────────── loop ──
"""

# ─────────────────────────────────────────────────────────────────────────────
# 0.  Package loading
# ─────────────────────────────────────────────────────────────────────────────
#
# Herb packages provide all language infrastructure.
# CEGIS provides the synthesis loop and its typed components.

using HerbCore           # RuleNode, AbstractRuleNode, AbstractHole
using HerbGrammar        # @csgrammar, ContextSensitiveGrammar, rulenode2expr,
                         # grammar2symboltable, addconstraint!, clearconstraints!
using HerbConstraints    # AbstractGrammarConstraint, GenericSolver, UniformSolver
using HerbInterpret      # execute_on_input, interpret, SymbolTable
using HerbSearch         # ProgramIterator, synth, BFSIterator, evaluate,
                         # SynthResult (optimal_program / suboptimal_program)
using HerbSpecification  # Problem, IOExample, SMTSpecification

using CEGIS              # CEGISProblem, CEGISResult, run_cegis, and all stubs

# ─────────────────────────────────────────────────────────────────────────────
# 1.  Define the grammar  (HerbGrammar)
# ─────────────────────────────────────────────────────────────────────────────
#
# We define a small arithmetic grammar over integers.
# This grammar is the *search space* the synthesizer explores.
#
# HerbGrammar.@csgrammar builds a ContextSensitiveGrammar (context-sensitive =
# constraints can be attached later by the Learner without rewriting the grammar).

grammar = @csgrammar begin
    # An Expr evaluates to an Int
    Expr = x                    # variable (must be in the symbol table)
    Expr = y
    Expr = 0
    Expr = 1
    Expr = Expr + Expr
    Expr = Expr - Expr
    Expr = Expr * Expr
    Expr = ifelse(Cond, Expr, Expr)   # conditional evaluation

    # A Cond evaluates to Bool
    Cond = Expr < Expr
    Cond = Expr == Expr
    Cond = !Cond
end

start_symbol = :Expr   # the synthesizer will look for programs that return Expr

# ─────────────────────────────────────────────────────────────────────────────
# 2.  Define the initial specification  (HerbSpecification)
# ─────────────────────────────────────────────────────────────────────────────
#
# The specification is a set of input/output examples.
# HerbSpecification.IOExample holds one (input-dict, expected-output) pair.
# HerbSpecification.Problem wraps a collection of IOExamples.
#
# These are the *training examples* — the synthesizer must satisfy all of them.
# The verifier checks correctness on all inputs (not just these).

initial_examples = [
    IOExample(Dict(:x => 1, :y => 2), 3),    # 1 + 2 = 3  → target: x + y
    IOExample(Dict(:x => 0, :y => 5), 5),    # 0 + 5 = 5
    IOExample(Dict(:x => 3, :y => 3), 6),    # 3 + 3 = 6
]

spec = Problem("add_xy", initial_examples)

# ─────────────────────────────────────────────────────────────────────────────
# 3.  Define the oracle  (CEGIS.Verifier)
# ─────────────────────────────────────────────────────────────────────────────
#
# The oracle is the source of truth.  It checks whether a candidate program
# is correct on ALL inputs, not just the training set.
#
# Here we build a test-based oracle from a held-out set of examples.
# In a real deployment this could be an SMT solver (oracle_from_smt).
#
# oracle_from_examples returns a Function with signature:
#     (candidate::RuleNode, grammar::AbstractGrammar) -> VerificationResult

held_out_examples = [
    IOExample(Dict(:x => 10, :y => -3), 7),
    IOExample(Dict(:x => 0,  :y => 0),  0),
    IOExample(Dict(:x => 7,  :y => 7),  14),
    IOExample(Dict(:x => -1, :y => 1),  0),
    IOExample(Dict(:x => 100,:y => 1),  101),
]

my_oracle = oracle_from_examples(held_out_examples)
#
# ── Alternative: SMT-based oracle ─────────────────────────────────────────
# Uncomment for formal verification via Z3 / CVC5:
#
#   formula = SMTSpecification(:(∀ x y. program(x, y) == x + y))
#   my_oracle = oracle_from_smt(formula)

# ─────────────────────────────────────────────────────────────────────────────
# 4.  Assemble the CEGISProblem  (CEGIS.Types)
# ─────────────────────────────────────────────────────────────────────────────
#
# CEGISProblem is the single object threaded through the entire loop.
# It is mutable: the spec grows (counterexamples added) and the grammar grows
# (constraints added) over time.

problem = CEGISProblem(
    grammar,        # ContextSensitiveGrammar — will be mutated by Learner
    start_symbol,   # :Expr
    initial_examples,  # initial spec (grows with counterexamples)
    my_oracle,      # oracle function — immutable
    50,             # max_iterations
    120.0,          # max_time (seconds)
)

# ─────────────────────────────────────────────────────────────────────────────
# 5.  Run the CEGIS loop  (CEGIS.run_cegis)
# ─────────────────────────────────────────────────────────────────────────────
#
# run_cegis orchestrates all sub-components:
#
#   round 1:
#     synthesize(spec₀, grammar)      → candidate₁
#     verify(candidate₁, oracle)      → counterexample cx₁
#     minimize_counterexample(cx₁)    → cx₁' (smaller witness)
#     learn_constraint(cx₁', cand₁)  → constraint₁
#     add_constraint_to_grammar!(grammar, constraint₁)
#     update_problem_with_counterexample!(problem, cx₁')
#                                     → spec₁ = spec₀ ∪ {IOExample(cx₁')}
#   round 2:
#     synthesize(spec₁, grammar)      → candidate₂   (can't repeat candidate₁)
#     verify(candidate₂, oracle)      → verified ✓
#     return CEGISResult(cegis_success, candidate₂, 2, [cx₁'])

result = run_cegis(
    problem;
    verbose  = true,   # print per-round progress to stdout
    minimize = true,   # shrink counterexamples before adding them
    learn    = true,   # learn grammar constraints from counterexamples
)

# ─────────────────────────────────────────────────────────────────────────────
# 6.  Inspect the result  (CEGIS.CEGISResult)
# ─────────────────────────────────────────────────────────────────────────────

if result.status == cegis_success
    # Convert the winning RuleNode back to a Julia Expr for human inspection.
    # HerbGrammar.rulenode2expr handles this translation.
    solution_expr = rulenode2expr(result.program, grammar)
    println("✓ Synthesis succeeded in $(result.iterations) iteration(s).")
    println("  Synthesized program : $solution_expr")

    # Optionally pretty-print the program tree.
    # HerbCore.print_tree traverses the RuleNode with indentation.
    # print_tree(result.program, grammar)

elseif result.status == cegis_timeout
    println("⏱  CEGIS timed out after $(result.iterations) iteration(s).")
    if result.program !== nothing
        println("  Best candidate : $(rulenode2expr(result.program, grammar))")
    end

else  # cegis_failure
    println("✗ CEGIS failed: no correct program found in $(result.iterations) iteration(s).")
end

println("\nCounterexamples encountered ($(length(result.counterexamples))):")
for (i, cx) in enumerate(result.counterexamples)
    println("  [$i] input=$(cx.input)  expected=$(cx.expected_output)  got=$(cx.actual_output)")
end

# ─────────────────────────────────────────────────────────────────────────────
# 7.  Advanced usage — manual loop  (for debugging / instrumentation)
# ─────────────────────────────────────────────────────────────────────────────
#
# If you need finer control than run_cegis provides, you can drive the loop
# manually by calling the individual component functions.  This mirrors exactly
# what run_cegis does internally.

function manual_cegis_loop(problem :: CEGISProblem; verbose = false)
    counterexamples = Counterexample[]

    for iteration in 1:problem.max_iterations

        # ── Step 1: Synthesis ────────────────────────────────────────────────
        # Build a HerbSpecification.Problem from current examples and ask
        # HerbSearch.synth (via our synthesize wrapper) for a candidate.
        current_spec    = Problem(problem.spec)
        candidate = synthesize(current_spec, problem.grammar, problem.start_symbol)

        if candidate === nothing
            verbose && println("[$iteration] Synthesis exhausted — no candidate.")
            return CEGISResult(cegis_failure, nothing, iteration, counterexamples)
        end

        if verbose
            expr = rulenode2expr(candidate, problem.grammar)
            println("[$iteration] Candidate: $expr")
        end

        # ── Step 2: Verification ─────────────────────────────────────────────
        # The oracle executes our candidate on hidden inputs.
        # Internally it uses HerbGrammar.rulenode2expr + HerbInterpret.execute_on_input.
        vresult = verify(candidate, problem.grammar, problem.oracle)

        if vresult.status == verified
            verbose && println("[$iteration] ✓ Verified!")
            return CEGISResult(cegis_success, candidate, iteration, counterexamples)
        end

        # ── Step 3: Counterexample management ────────────────────────────────
        cx = vresult.counterexample
        verbose && println("[$iteration] Counterexample: $(cx.input) → $(cx.actual_output) ≠ $(cx.expected_output)")

        # Minimize: try to reduce the input dictionary to only the keys that
        # actually matter for reproducing the failure.
        # Uses HerbInterpret.execute_on_input internally.
        cx = minimize_counterexample(cx, candidate, problem.grammar)

        # Safety valve: if we somehow loop, abort.
        if is_duplicate_counterexample(cx, counterexamples)
            verbose && println("[$iteration] Duplicate counterexample — aborting.")
            return CEGISResult(cegis_failure, candidate, iteration, counterexamples)
        end

        push!(counterexamples, cx)

        # ── Step 4: Learning ────────────────────────────────────────────────
        # learn_constraint calls generalize_counterexample which inspects the
        # RuleNode tree and builds a HerbConstraints.AbstractGrammarConstraint.
        # add_constraint_to_grammar! calls HerbGrammar.addconstraint!.
        constraint = learn_constraint(cx, candidate, problem.grammar)
        add_constraint_to_grammar!(problem.grammar, constraint)

        # ── Step 5: Grow the spec ────────────────────────────────────────────
        # Converts cx → IOExample and appends it to problem.spec so the
        # synthesizer cannot reproduce the same mistake next round.
        update_problem_with_counterexample!(problem, cx)
        verbose && println("[$iteration] Spec now has $(length(problem.spec)) examples.")
    end

    return CEGISResult(cegis_timeout, nothing, problem.max_iterations, counterexamples)
end

# ─────────────────────────────────────────────────────────────────────────────
# (End of pipeline.jl)
# ─────────────────────────────────────────────────────────────────────────────
#
# Implementation checklist — fill in stubs in order:
#
#   [src/synthesizer.jl]
#     □  build_iterator(grammar, start_symbol; max_depth, max_size)
#     □  synthesize(problem, grammar, start_symbol; ...)
#     □  update_problem_with_counterexample!(problem, cx)
#
#   [src/verifier.jl]
#     □  oracle_from_examples(held_out_examples)
#     □  oracle_from_smt(formula)
#     □  verify(candidate, grammar, oracle)
#
#   [src/counterexample.jl]
#     □  counterexample_to_ioexample(cx)
#     □  is_duplicate_counterexample(cx, seen)
#     □  minimize_counterexample(cx, candidate, grammar)
#     □  generalize_counterexample(cx, candidate, grammar)
#
#   [src/learner.jl]
#     □  learn_constraint(cx, candidate, grammar)
#     □  add_constraint_to_grammar!(grammar, constraint)
#     □  reset_learned_constraints!(grammar, original_constraints)
#
#   [src/cegis_loop.jl]
#     □  run_cegis(problem; verbose, minimize, learn)
