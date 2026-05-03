"""
Helper utilities for CEGIS e2e tests.
"""

# Get CEGIS root directory - works whether tests are run with --project or not
const CEGIS_ROOT = if isfile(joinpath(@__DIR__, "..", "Project.toml"))
    dirname(@__DIR__)
else
    # Fallback: assume CEGIS is in ~/.julia/dev
    joinpath(expanduser("~"), ".julia", "dev", "CEGIS")
end

"""
    find_spec_file(name::String)

Locate a spec file by name in the CEGIS spec_files directories,
checking both simple and phase3_benchmarks locations.
"""
function find_spec_file(name::String)
    # Try phase3_benchmarks first
    phase3_path = joinpath(CEGIS_ROOT, "spec_files", "phase3_benchmarks", "$name.sl")
    if isfile(phase3_path)
        return phase3_path
    end
    
    # Try main spec_files directory
    spec_path = joinpath(CEGIS_ROOT, "spec_files", "$name.sl")
    if isfile(spec_path)
        return spec_path
    end
    
    error("Spec file not found for: $name (searched in $CEGIS_ROOT/spec_files/)")
end

"""
    solution_matches(actual::String, expected::String)::Bool

Compare solution strings with normalization for whitespace and common formatting variations.
"""
function solution_matches(actual::String, expected::String)::Bool
    # Normalize spaces
    actual_norm = strip(replace(actual, r"\s+" => " "))
    expected_norm = strip(replace(expected, r"\s+" => " "))
    
    # Direct comparison
    actual_norm == expected_norm
end

"""
    run_spec_synthesis(spec_path::String; desired_solution=nothing, 
                       max_depth=5, max_enumerations=100_000)

Convenience wrapper to run synthesis on a spec file with standard configuration.

Returns `CEGISResult` with status, program, iterations, and counterexamples.
"""
function run_spec_synthesis(
    spec_path::String;
    desired_solution=nothing,
    max_depth=5,
    max_enumerations=100_000
)
    # Build problem and grammar from spec
    problem = CEGIS.CEGISProblem(spec_path; desired_solution=desired_solution)
    grammar = CEGIS.build_grammar_from_spec(spec_path)
    
    # Create BFS iterator with configured depth
    iterator = CEGIS.IteratorConfig.create_iterator(
        CEGIS.IteratorConfig.BFSIteratorConfig(max_depth=max_depth),
        grammar,
        :Expr
    )
    
    # Run synthesis
    result = CEGIS.run_synthesis(
        problem,
        iterator;
        max_enumerations=max_enumerations,
    )
    
    result
end

"""
    solution_to_string(program, grammar)::String

Convert a RuleNode program to its string expression.
"""
function solution_to_string(program, grammar)::String
    if program === nothing
        return "nothing"
    end
    expr = HerbGrammar.rulenode2expr(program, grammar)
    string(expr)
end
