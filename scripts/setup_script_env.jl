#!/usr/bin/env julia

using Pkg

script_dir = @__DIR__
project_dir = dirname(script_dir)
script_env = joinpath(script_dir, ".script_env_z3")

println("Setting up script environment at: $script_env")
Pkg.activate(script_env)

# First, add the packages if they're not already there
dev_dir = joinpath(homedir(), ".julia", "dev")
cegis_path = joinpath(dev_dir, "CEGIS")

if isdir(cegis_path)
    println("Developing CEGIS from: $cegis_path")
    Pkg.develop(PackageSpec(path=cegis_path))
end

# Resolve and instantiate
println("Resolving dependencies...")
Pkg.resolve()

println("Instantiating environment...")
Pkg.instantiate()

println("✓ Environment setup complete!")
println("Now run: julia scripts/z3_smt_cegis.jl <spec_file> ...")
