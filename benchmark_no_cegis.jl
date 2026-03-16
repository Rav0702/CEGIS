"""
benchmark_no_cegis.jl

Run from CEGIS/ directory:

    julia benchmark_no_cegis.jl

This script loads a benchmark problem from HerbBenchmarks and runs direct
HerbSearch synthesis (`synth`) on the benchmark examples using several
different iterators:  BFS, DFS, RandomIterator, MHSearchIterator,
SASearchIterator.  Results and pass-counts are printed after each trial.
"""

import Pkg

const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
Pkg.activate(_SCRIPT_ENV)

const _HERB_PKGS = [
    "HerbCore", "HerbGrammar", "HerbConstraints",
    "HerbInterpret", "HerbSearch", "HerbSpecification",
    "CEGIS", "HerbBenchmarks",
]
let dev_dir = joinpath(homedir(), ".julia", "dev"),
    manifest = joinpath(_SCRIPT_ENV, "Manifest.toml")

    if !isfile(manifest) || filesize(manifest) < 200
        pkgs = [Pkg.PackageSpec(path=joinpath(dev_dir, p))
                for p in _HERB_PKGS if isdir(joinpath(dev_dir, p))]
        isempty(pkgs) || Pkg.develop(pkgs)
    end

    # Ensure benchmark package and its dependencies are available.
    benchmark_path = joinpath(@__DIR__, "..", "HerbBenchmarks.jl")
    if isdir(benchmark_path)
        Pkg.develop(Pkg.PackageSpec(path=benchmark_path))
    end
    Pkg.instantiate()
end

using HerbBenchmarks
using HerbConstraints
using HerbGrammar
using HerbInterpret
using HerbSearch

using HerbSpecification: IOExample

using Logging
disable_logging(LogLevel(1))

benchmark_module = HerbBenchmarks.PBE_BV_Track_2018

# Stochastic iterator internals build a Main-based symbol table.
# Import benchmark primitives into Main so both code paths can resolve symbols.
@eval Main using HerbBenchmarks.PBE_BV_Track_2018

identifiers = HerbBenchmarks.get_all_identifiers(benchmark_module)
identifier = sort(identifiers)[1]
pair = HerbBenchmarks.get_problem_grammar_pair(benchmark_module, identifier)
examples = pair.problem.spec   # Vector{IOExample}

println("Benchmark : $(pair.benchmark_name)")
println("Problem   : $(pair.identifier)")
println("Examples  : $(length(examples))")
println()

const MAX_DEPTH        = 8
const MAX_ENUMERATIONS = 2_000_000
const MAX_TIME_STOCH   = 60   # seconds for stochastic searchers

# Symbol table that includes benchmark-module functions (for evaluation)
const BM_SYMTABLE = grammar2symboltable(pair.grammar, benchmark_module)

"""Evaluate a candidate expression on all examples; return (passed, failed, errored, total)."""
function check_examples(expr, examples)
    passed = 0; failed = 0; errored = 0
    for ex in examples
        actual = try
            execute_on_input(BM_SYMTABLE, expr, ex.in)
        catch
            errored += 1
            continue
        end
        actual == ex.out ? (passed += 1) : (failed += 1)
    end
    return passed, failed, errored, length(examples)
end

"""Run synth, print result and pass counts.  `iter_name` is a label string."""
function run_trial(iter_name, iterator; kwargs...)
    println("=" ^ 60)
    println("Iterator: $iter_name")

    t_start = time()
    result = synth(pair.problem, iterator; kwargs..., mod = benchmark_module)
    elapsed = round(time() - t_start; digits = 2)

    if result === nothing || result[1] === nothing
        println("Status: no_program")
    else
        program, flag = result
        expr = rulenode2expr(program, pair.grammar)
        passed, failed, errored, total = check_examples(expr, examples)
        println("Status  : $flag")
        println("Time    : $(elapsed)s")
        println("Program : $expr")
        println("Passed  : $passed / $total")
        failed  > 0 && println("Failed  : $failed")
        errored > 0 && println("Errors  : $errored")
    end
    println()
end


stoch_eval(_, expr, input) = execute_on_input(BM_SYMTABLE, expr, input)

cost_fn = misclassification

# 1. BFS
solver_bfs = GenericSolver(pair.grammar, :Start; max_depth = MAX_DEPTH)
uniform_ref_bfs = Ref{Union{HerbConstraints.UniformSolver, Nothing}}(nothing)
run_trial("BFSIterator",
    BFSIterator(; solver = solver_bfs, uniform_solver_ref = uniform_ref_bfs);
    max_enumerations = MAX_ENUMERATIONS)

# 2. DFS
solver_dfs = GenericSolver(pair.grammar, :Start; max_depth = MAX_DEPTH)
uniform_ref_dfs = Ref{Union{HerbConstraints.UniformSolver, Nothing}}(nothing)
run_trial("DFSIterator",
    DFSIterator(; solver = solver_dfs, uniform_solver_ref = uniform_ref_dfs);
    max_enumerations = MAX_ENUMERATIONS)

# 4. Metropolis-Hastings
run_trial("MHSearchIterator",
    MHSearchIterator(pair.grammar, :Start, collect(examples), cost_fn;
        max_depth = MAX_DEPTH, evaluation_function = stoch_eval);
    max_time = MAX_TIME_STOCH)

# 5. Simulated Annealing
run_trial("SASearchIterator",
    SASearchIterator(pair.grammar, :Start, collect(examples), cost_fn;
        initial_temperature = 2.0, temperature_decreasing_factor = 0.99,
        max_depth = MAX_DEPTH, evaluation_function = stoch_eval);
    max_time = MAX_TIME_STOCH)
