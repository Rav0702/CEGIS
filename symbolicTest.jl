using Symbolics, SymbolicSMT, Z3

# Helper function to print model variables
function print_model_variables(m::Z3.Model)
    println(m)
end

# Create symbolic variables with Symbolics.jl
@variables x::Real y::Real z::Real a::Real

println("\n--- Extracting Variable Assignments from Model ---")

# Create constraints with specific solution
constraintList = Constraints([x > 0, y > 0, x = y + y])
# constraintList = Constraints([x > y, y > z, z > a, a > 0])

# Check satisfiability with model extraction
Z3.push(constraintList.solver)
Z3.add(constraintList.solver, SymbolicSMT.to_z3(true, constraintList.context))
res = Z3.check(constraintList.solver)

if string(res) == "sat"
    println("Constraints are satisfiable!")
    
    # Get the model from the solver
    m = Z3.model(constraintList.solver)
    
    # Print the model with all variable assignments
    println("\nModel:")
    print_model_variables(m)
else
    println("Constraints are not satisfiable")
end

Z3.pop(constraintList.solver, 1)



