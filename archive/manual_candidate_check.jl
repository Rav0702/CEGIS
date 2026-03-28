using Symbolics
using SymbolicUtils
include("parse_sygus.jl")

# Parse the spec file
spec_file = "findidx_2_declare_fun.sl"
spec = parse_sygus(spec_file)

println("=" ^ 80)
println("Manual Candidate Evaluation")
println("=" ^ 80)
println("\nSMTSpec:")
println("  Variables: ", spec.vars)
println("  Constraints ($(length(spec.constraints))):")
for (i, c) in enumerate(spec.constraints)
    println("    [$i] Julia: $c")
end
println("\n  Declared Functions:")
for (name, sig) in spec.declared_functions
    println("    $name: $(sig.param_types) -> $(sig.return_type)")
end

# Create symbolic variables
@variables x0 x1 k
sym_vars = Dict(:x0 => x0, :x1 => x1, :k => k)

# The candidate solution: (k >= x0) + (k >= x1)
candidate_expr = "(k >= x0) + (k >= x1)"
println("\n" ^ 2, "Candidate: $candidate_expr")

# Helper function to evaluate candidate
function evaluate_candidate(x0_val, x1_val, k_val)
    # Convert boolean to 1 (true) or 0 (false), then sum
    return Int(k_val >= x0_val) + Int(k_val >= x1_val)
end

# Test counterexamples from the CEGIS loop
test_cases = [
    (Dict(:x0 => -1, :k => -2, :x1 => 0), 0, "Oracle counterexample 1"),
    (Dict(:x0 => 1, :k => 2, :x1 => 2), 2, "Oracle counterexample 2"),
    (Dict(:x0 => -1, :k => -2, :x1 => 0), 1, "Oracle counterexample 3 (conflicting)"),
]

println("\n" ^ 2, "Testing counterexamples:")
println("-" ^ 80)

all_pass = true
for (input_dict, expected, description) in test_cases
    println("\n$(description)")
    println("  Input: x0=$(input_dict[:x0]), k=$(input_dict[:k]), x1=$(input_dict[:x1])")
    println("  Expected output: $expected")
    
    # Evaluate candidate with these values
    actual = evaluate_candidate(input_dict[:x0], input_dict[:x1], input_dict[:k])
    println("  Actual output: $actual")
    
    if actual == expected
        println("  ✓ PASS")
    else
        println("  ✗ FAIL - Expected $expected but got $actual")
        all_pass = false
    end
end

println("\n" ^ 2, "-" ^ 80)
if all_pass
    println("✓ All counterexamples passed!")
else
    println("✗ Some counterexamples failed!")
end

# Now let's also evaluate the candidate against the parsed constraints
println("\n" ^ 2, "=" ^ 80)
println("Constraint Satisfaction Check")
println("=" ^ 80)

# Test each constraint
constraint_tests = [
    # Constraint 1: (x0 < x1) & (k < x0) => findIdx(...) == 0
    (0, (Dict(:x0 => 0, :x1 => 1, :k => -1), "constraint 1 (k < x0)")),
    
    # Constraint 2: (x0 < x1) & (im(>= k x0)(< k x1)) => findIdx(...) == 1
    (1, (Dict(:x0 => 0, :x1 => 5, :k => 2), "constraint 2 (x0 <= k < x1)")),
    
    # Constraint 3: (x0 < x1) & (k >= x1) => findIdx(...) == 2
    (2, (Dict(:x0 => 0, :x1 => 5, :k => 10), "constraint 3 (k >= x1)")),
]

for (expected_output, (test_input, description)) in constraint_tests
    println("\nTesting $description")
    println("  Input: x0=$(test_input[:x0]), k=$(test_input[:k]), x1=$(test_input[:x1])")
    println("  Expected: $expected_output")
    
    actual = evaluate_candidate(test_input[:x0], test_input[:x1], test_input[:k])
    
    println("  Candidate output: $actual")
    
    if actual == expected_output
        println("  ✓ PASS")
    else
        println("  ✗ FAIL")
    end
end

println("\n" ^ 2, "=" ^ 80)

