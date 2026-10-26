"""
    incomplete_tests.jl

Complete and incomplete tests — how a counterexample becomes evidence.

A counterexample query returns an input *and* an output the spec accepts there.
Demanding that output of every later candidate (a **complete** test,
`IOExample(input, output)`) is sound only when it is the *only* output the spec
accepts at that input. When the spec admits several — "any upper bound", "a
value different from x and y", a don't-care region — Z3's pick is arbitrary,
and a complete test built from it fails correct programs. The search is steered
toward one arbitrary answer, and `CDGPEvaluator`, which accepts a verified
program only if it also passes every test, can reject a correct program.

The reference CDGP (`CDGPState.createTestFromCounterex`) answers with an
**incomplete test**: the input alone, passed when the candidate's behaviour
there satisfies the specification. The reference asks its solver, per candidate
per test. Here the verdict is computed pointwise: once the input and the
candidate are fixed the constraints are ground, so `eval_constraint_pointwise`
returns exactly the solver's answer without a Z3 call.

Policy (`TestCompletion`), per counterexample:

  1. spec proven single-answer at construction (`spec_single_answer`, one Z3
     query per run) ⇒ complete test, no further query. Single-answer benchmarks
     (max*, countpos*, …) therefore run exactly as before;
  2. otherwise one `output_is_unique` query: unique ⇒ complete test; another
     valid output exists, or Z3 cannot tell ⇒ incomplete test;
  3. no in-process solver, or constraints the interpreter cannot evaluate ⇒ the
     legacy complete test, counted as `unchecked` so reports can flag it.

  Before all of these: a **relational** spec (some constraint applies the synth-fun to anything but the
  declared variables, e.g. `f(x+1, y) = f(x, y) + 2`) whose constraints the interpreter can evaluate ⇒ always
  an incomplete test. The solver's output there is not a property of the input (the counterexample query's
  premise leaves it unconstrained wherever only relational constraints apply), so a complete test would demand
  an arbitrary value (2026-10-03, spec_files/partial_knowledge/recur3.sl).

`enabled=false` (`run_cdgp(...; incomplete_tests=false)`) restores the legacy
behaviour — every counterexample a complete test with the solver's output —
for ablation. Its tests are all counted `unchecked`.
"""

"""
Can every constraint be evaluated pointwise at all? Probed at more than one
binding because a failure can be value-dependent (`div` by a variable that
happens to be 0) rather than syntactic. If not, neither witness batteries nor
incomplete tests can be judged by the interpreter.
"""
function _pointwise_ok(sexprs, fname::AbstractString, spec)::Bool
    isempty(spec.free_vars) && return false
    out = spec.synth_funs[1].sort == "Bool" ? false : 1
    apply = _ -> out
    for probe in (1, 2, -1)
        vars = Dict{String,Any}(
            fv.name => (fv.sort == "Bool" ? probe > 0 : probe) for fv in spec.free_vars)
        if all(s -> (try
                        CEXGeneration.eval_constraint_pointwise(s, fname, vars, apply)
                        true
                     catch
                        false
                     end), sexprs)
            return true
        end
    end
    return false
end

"""
Free-var binding (name → value) of a Z3 model, typed for the pointwise
evaluator: models carry Booleans as `1`/`0`, the interpreter wants `Bool`.
"""
function _cex_binding(spec, model::AbstractDict)::Dict{String,Any}
    b = Dict{String,Any}()
    for fv in spec.free_vars
        v = get(model, fv.name, 0)
        b[fv.name] = fv.sort == "Bool" ? (v == 1 || v === true) : v
    end
    return b
end

"""
Per-evaluator completion policy and its counters. The counters are the
evidence that the incomplete path is reached at all: on a single-answer spec
`incomplete` stays `0` and `unique_checks` stays `0`.
"""
mutable struct TestCompletion
    enabled::Bool
    single_answer::Union{Bool,Nothing}  # spec-level verdict; `nothing` ⇒ not established
    relational::Bool                    # some constraint applies the synth-fun off the declared variables
    pointwise::Bool                     # constraints evaluable by the interpreter
    sexprs::Vector{Any}                 # every constraint, parsed
    fname::String
    param_names::Vector{Symbol}
    complete::Int                       # complete tests created (incl. unchecked)
    incomplete::Int                     # incomplete tests created
    unique_checks::Int                  # per-counterexample `output_is_unique` queries
    unchecked::Int                      # complete tests with no uniqueness guarantee
    seeded::Int                         # starting tests added before generation 0 (run_cdgp seed_tests)
end

function TestCompletion(spec, cex::Union{CEXGeneration.CexSolver,Nothing}; enabled::Bool=true)
    sf = spec.synth_funs[1]
    sexprs = Any[CEXGeneration.read_sexprs(c)[1] for c in spec.constraints]
    pointwise = _pointwise_ok(sexprs, sf.name, spec)
    fvs = String[fv.name for fv in spec.free_vars]
    relational = any(c -> occursin("($(sf.name)", c) &&
                          !CEXGeneration._canonical_calls_only(c, sf.name, fvs, length(sf.params)), spec.constraints)
    single = (enabled && pointwise && cex !== nothing) ?
             CEXGeneration.spec_single_answer(spec) : nothing
    return TestCompletion(enabled, single, relational, pointwise, sexprs, sf.name,
                          Symbol[Symbol(p) for (p, _) in sf.params], 0, 0, 0, 0, 0)
end

"""
    _completion_kind!(tc, cex, binding, value) -> :complete | :incomplete

Decide what a counterexample at `binding` with solver-proposed output `value`
becomes (policy in the file header), and count the decision.
"""
function _completion_kind!(tc::TestCompletion, cex, binding::Dict{String,Any}, value)::Symbol
    if tc.enabled && tc.relational && tc.pointwise
        tc.incomplete += 1
        return :incomplete
    end
    if tc.enabled && tc.single_answer === true
        tc.complete += 1
        return :complete
    end
    if !tc.enabled || cex === nothing || !tc.pointwise
        tc.complete += 1
        tc.unchecked += 1
        return :complete
    end
    tc.unique_checks += 1
    if CEXGeneration.output_is_unique(cex, binding, value) === true
        tc.complete += 1
        return :complete
    end
    tc.incomplete += 1
    return :incomplete
end

"""
    _incomplete_loss(tc, symboltable, expr, binding) -> Float64

Judge the candidate `expr` on one incomplete test: `0.0` if its behaviour at
`binding` satisfies every constraint, `1.0` if it violates one, `Inf` if the
interpreter throws (the same convention as a complete test). Synth-fun
applications at equal arguments share one program execution, so a
single-invocation spec costs one run of the program per incomplete test.
"""
function _incomplete_loss(tc::TestCompletion, symboltable, expr, binding::Dict{String,Any})::Float64
    pnames = tc.param_names
    memo = Dict{Vector{Any},Any}()
    apply = function (argvals::Vector{Any})
        get!(memo, argvals) do
            length(argvals) == length(pnames) ||
                throw(CEXGeneration.PointwiseError("synth-fun applied at wrong arity"))
            execute_on_input(symboltable, expr,
                             Dict{Symbol,Any}(pnames[i] => argvals[i] for i in eachindex(pnames)))
        end
    end
    try
        for sx in tc.sexprs
            CEXGeneration.eval_constraint_pointwise(sx, tc.fname, binding, apply) || return 1.0
        end
        return 0.0
    catch
        return Inf
    end
end

"""Snapshot of the counters, for results and traces."""
completion_stats(tc::TestCompletion) =
    (enabled = tc.enabled, single_answer = tc.single_answer, pointwise = tc.pointwise, relational = tc.relational,
     complete = tc.complete, incomplete = tc.incomplete,
     unique_checks = tc.unique_checks, unchecked = tc.unchecked, seeded = tc.seeded)
