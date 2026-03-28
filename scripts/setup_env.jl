using Pkg

println("Current working directory: $(pwd())")
println("Activating .script_env_z3 environment...")
Pkg.activate(joinpath(@__DIR__, ".script_env_z3"))

println("Resolving dependencies...")
Pkg.resolve()

println("Instantiating environment...")
Pkg.instantiate()

println("Environment setup complete!")
