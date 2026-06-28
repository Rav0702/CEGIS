"""
    cdgp_evaluator.jl

`CDGPEvaluator` — the classic CDGP fitness (Błądek & Krawiec, *Counterexample-
Driven Genetic Programming*). The complement of `Z3GradedEvaluator`:

  - Fitness = number of **failed test cases**, cheap interpretation only.
  - The test set starts empty and grows from Z3 counterexamples: a candidate
    that passes *all* current tests is formally verified with a single full
    counterexample query (`generate_cex_query`):
      - `:unsat`   ⇒ formally correct — recorded in `solved`, search can stop.
      - `:sat`     ⇒ the model yields a new `(input, expected_output)` test
                     (free vars → input, fresh constant `out_<f>` → a spec-valid
                     output the candidate provably disagrees with).
      - `:unknown` ⇒ ill-typed/unsupported candidate — fitness `Inf`.

So Z3 is only consulted for test-perfect candidates, instead of on every
fitness evaluation as in the graded approach.

Deliberately bypasses `Z3Oracle.extract_counterexample`, which collapses
`:unsat` and `:unknown` into `nothing`: with an initially empty test set every
genome is "test-perfect", and an ill-typed one returning `:unknown` would be
declared solved.

The `cache` (keyed by serialized program) is only valid for the current test
set and is cleared whenever a counterexample grows it. Note the evaluator
mutates shared state (`test_cases`, `cache`, counters), so the GA must run
with `parallel=false`.
"""

"""
    CDGPEvaluator(spec, grammar, start_symbol, max_depth; mod=Main)

Construct from a parsed `CEXGeneration.Spec` and the grammar candidates are
drawn from. Assumes a single synthesis function (the common SyGuS case).
`grammar`/`start_symbol`/`max_depth` are also read by Arborist's
`_initialize_population` for `RuleNodeGenome`.
"""
mutable struct CDGPEvaluator <: Arborist.AbstractEvaluator
    spec::Any                # CEXGeneration.Spec
    grammar::AbstractGrammar
    start_symbol::Symbol
    max_depth::Int
    func_name::String
    symboltable::Any
    test_cases::Vector{IOExample}
    counterexamples::Vector{Counterexample}
    cache::Dict{String,Float64}
    solved::Union{RuleNodeGenome,Nothing}
    verifications::Int       # number of Z3 counterexample queries issued
end

function CDGPEvaluator(spec, grammar::AbstractGrammar, start_symbol::Symbol,
                       max_depth::Int; mod::Module=Main)
    isempty(spec.synth_funs) && error("CDGPEvaluator: spec has no synth-fun")
    return CDGPEvaluator(
        spec, grammar, start_symbol, max_depth,
        spec.synth_funs[1].name, grammar2symboltable(grammar, mod),
        IOExample[], Counterexample[],
        Dict{String,Float64}(), nothing, 0,
    )
end

function Arborist.input_signature(e::CDGPEvaluator)::Dict{Symbol,DataType}
    sf = e.spec.synth_funs[1]
    return Dict{Symbol,DataType}(Symbol(p) => _sort_to_type(s) for (p, s) in sf.params)
end

function Arborist.output_signature(e::CDGPEvaluator)::Dict{Symbol,DataType}
    sf = e.spec.synth_funs[1]
    return Dict{Symbol,DataType}(:out => _sort_to_type(sf.sort))
end

"""
    _cdgp_verify!(e, g) -> (status::Symbol, Union{Counterexample,Nothing})

Formally verify a test-perfect genome with one full counterexample query.
On `:sat` the returned `Counterexample` carries the model's free-var values as
input and the fresh constant `out_<f>` (a spec-valid output at that input) as
expected output.
"""
function _cdgp_verify!(e::CDGPEvaluator, g::RuleNodeGenome)
    smt = try
        CEXGeneration.rulenode_to_smt2(g.tree, e.grammar)
    catch
        return (:unknown, nothing)
    end

    e.verifications += 1
    query = CEXGeneration.generate_cex_query(e.spec, Dict(e.func_name => smt))
    r = try
        CEXGeneration.verify_query(query)
    catch
        CEXGeneration.Z3Result(:unknown, Dict{String,Any}(), String[])
    end

    r.status == :unsat && return (:unsat, nothing)
    r.status == :sat || return (:unknown, nothing)

    input = _model_to_input(e.spec, r.model)
    expected = get(r.model, "out_$(e.func_name)", 0)
    return (:sat, Counterexample(input, expected, nothing))
end

"""
    evaluate_genome(g::RuleNodeGenome, e::CDGPEvaluator) -> Float64

Fitness = failed tests on the accumulated counterexample set (lower better,
`0` ⇒ passes everything *and* — once verified — is formally correct). Genomes
that crash the interpreter or Z3 conversion get `Inf`.
"""
function Arborist.evaluate_genome(g::RuleNodeGenome, e::CDGPEvaluator)::Float64
    key = Arborist.serialize(g)
    haskey(e.cache, key) && return e.cache[key]

    expr = rulenode2expr(g.tree, e.grammar)
    failed = 0
    for io in e.test_cases
        out = try
            execute_on_input(e.symboltable, expr, io.in)
        catch
            return (e.cache[key] = Inf)
        end
        out == io.out || (failed += 1)
    end

    if failed == 0 && e.solved === nothing
        status, cx = _cdgp_verify!(e, g)
        if status == :unsat
            e.solved = g
        elseif status == :sat
            push!(e.counterexamples, cx)
            push!(e.test_cases, IOExample(cx.input, cx.expected_output))
            # All cached fitnesses are stale on the grown test set.
            empty!(e.cache)
            # The new test was derived from this genome's own violation, so it
            # fails it by construction.
            failed = 1
        else
            return (e.cache[key] = Inf)
        end
    end

    return (e.cache[key] = Float64(failed))
end

"""
    evaluate_cases(g::RuleNodeGenome, e::CDGPEvaluator) -> Vector{Float64}

Per-test loss vector against the current test set, for lexicase selection
(`Arborist.LexicaseSelection`). One entry per accumulated test, in order:
`0.0` pass, `1.0` fail, `Inf` if the interpreter throws on that input.

Side-effect-free by contract: unlike [`evaluate_genome`](@ref) it never issues a
Z3 query, grows the test set, or sets `solved`. The solve loop materializes this
matrix (`_compute_case_fitnesses`) independently of the scalar pass that drives
verification, so growing the set here would make the per-individual matrix
ragged. Empty test set ⇒ empty vector (lexicase then selects at random).
"""
function Arborist.evaluate_cases(g::RuleNodeGenome, e::CDGPEvaluator)::Vector{Float64}
    expr = rulenode2expr(g.tree, e.grammar)
    losses = Vector{Float64}(undef, length(e.test_cases))
    for (i, io) in enumerate(e.test_cases)
        losses[i] = try
            execute_on_input(e.symboltable, expr, io.in) == io.out ? 0.0 : 1.0
        catch
            Inf
        end
    end
    return losses
end
