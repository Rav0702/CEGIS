"""
smt_model_extraction_demo.jl

Demonstrates extracting variable assignments from Z3 models when SAT is found.

Run from CEGIS/ directory:
    julia smt_model_extraction_demo.jl
"""

import Pkg

const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
Pkg.activate(_SCRIPT_ENV)

const _HERB_PKGS = [
    "SymbolicSMT",
]
let dev_dir = joinpath(homedir(), ".julia", "dev"),
    manifest = joinpath(_SCRIPT_ENV, "Manifest.toml")
    if !isfile(manifest) || filesize(manifest) < 200
        pkgs = [Pkg.PackageSpec(path=joinpath(dev_dir, p))
                for p in _HERB_PKGS if isdir(joinpath(dev_dir, p))]
        isempty(pkgs) || Pkg.develop(pkgs)
    end
end

using SymbolicSMT
using SymbolicUtils

@syms x0::Real x1::Real x2::Real x3::Real x4::Real k::Real

# Sortedness: x0 < x1 < x2 < x3 < x4
sorted_cond = [x0 < x1, x1 < x2, x2 < x3, x3 < x4]

# Build specification constraints: one constraint for each expected output
# Each constraint: (sorted ∧ interval_condition) ⟹ (candidate = expected_idx)

constraints_list = [
    (sorted_cond, [k < x0], 0),                # Constraint 0: if sorted and k < x0, then result = 0
    (sorted_cond, [k > x0, k < x1], 1),        # Constraint 1: if sorted and x0 < k < x1, then result = 1
    (sorted_cond, [k > x1, k < x2], 2),        # Constraint 2: if sorted and x1 < k < x2, then result = 2
    (sorted_cond, [k > x2, k < x3], 3),        # Constraint 3: if sorted and x2 < k < x3, then result = 3
    (sorted_cond, [k > x3, k < x4], 4),        # Constraint 4: if sorted and x3 < k < x4, then result = 4
    (sorted_cond, [k > x4], 5),                # Constraint 5: if sorted and k > x4, then result = 5
]

# ──────────────────────────────────────────────────────────────────────────────
# Single Verification Call
# ──────────────────────────────────────────────────────────────────────────────

candidate = 0 * x0  # Always returns 0

println("Testing candidate: always 0")
println()

# Build all constraints explicitly
println("Specification constraints:")
all_constraint_exprs = []

for (i, (sorted, interval, expected_idx)) in enumerate(constraints_list)
    #println("  Constraint $i: (sorted ∧ interval_$i) ⟹ (candidate = $expected_idx)")
    push!(all_constraint_exprs, [sorted..., interval..., candidate != expected_idx])
end
println()

println("COnstraints");
println(all_constraint_exprs);
check_constraints = Constraints(all_constraint_exprs)

result = issatisfiable(check_constraints)

if result
    println("Counterexample found:")
    try
        assignment = get_model_assignment(
            0, check_constraints,
            [:x0, :x1, :x2, :x3, :x4, :k]
        )
        if assignment !== nothing
            for (var, val) in assignment
                println("  $var = $val")
            end
        else
            println("  (Could not extract assignment)")
        end
    catch e
        println("  Error extracting assignment: $e")
    end
else
    println("No counterexample — candidate is correct for this constraint!")
end

