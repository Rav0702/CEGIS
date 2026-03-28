# smt_model_extraction_demo.jl
# Single SMT call verification for CEGIS.
# Run from CEGIS/ directory:
#     julia smt_model_extraction_demo.jl

import Pkg
const _SCRIPT_ENV = joinpath(@__DIR__, ".script_env")
Pkg.activate(_SCRIPT_ENV)
const _HERB_PKGS = ["SymbolicSMT"]
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

# ──────────────────────────────────────────────────────────────────────────────
# CEX query: sorted ∧ ( violation_0 ∨ violation_1 ∨ ... ∨ violation_5 )
# where violation_i = (interval_i holds) ∧ (candidate ≠ i)
# ──────────────────────────────────────────────────────────────────────────────
function build_cex_query(candidate)
    violation_0 = (k < x0)                 & (candidate != 0)
    violation_1 = (k > x0) & (k < x1)     & (candidate != 1)
    violation_2 = (k > x1) & (k < x2)     & (candidate != 2)
    violation_3 = (k > x2) & (k < x3)     & (candidate != 3)
    violation_4 = (k > x3) & (k < x4)     & (candidate != 4)
    violation_5 = (k > x4)                 & (candidate != 5)

    sorted = (x0 < x1) & (x1 < x2) & (x2 < x3) & (x3 < x4) & (x0 > 0)

    return sorted & (violation_0 | violation_1 | violation_2 | violation_3 | violation_4 | violation_5)
end

# ──────────────────────────────────────────────────────────────────────────────
# Verify: ONE solver call per candidate
# Returns: nothing if correct, assignment dict if CEX found
# ──────────────────────────────────────────────────────────────────────────────
function verify(candidate)
    cex_query = build_cex_query(candidate)

    is_violated = issatisfiable(cex_query, Constraints([]))

    if !is_violated
        println("✓ Candidate is correct for ALL constraints!")
        return nothing
    end

    println("✗ Counterexample found!")
    assignment = get_model_assignment(
        cex_query,
        Constraints([]),
        [:x0, :x1, :x2, :x3, :x4, :k]
    )
    if assignment !== nothing
        for (var, val) in assignment
            println("  $var = $val")
        end
    else
        println("  (Could not extract assignment)")
    end
    return assignment
end

# ──────────────────────────────────────────────────────────────────────────────
# Test candidates
# ──────────────────────────────────────────────────────────────────────────────
println("=== Candidate 1: always 0 ===")
verify(0 * x0)
println()

println("=== Candidate 2: always 3 ===")
verify(3 + 0 * x0)
println()