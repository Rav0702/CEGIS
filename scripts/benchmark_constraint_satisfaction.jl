"""
benchmark_constraint_satisfaction.jl

Compares the two Method 2 (per-constraint satisfaction) backends on the max family:

  • subprocess  — `check_constraint_satisfaction(spec, …)`: one `z3` process per
    candidate (temp file + re-parse), all constraints via check-sat-assuming.
  • in-process  — `ConstraintSatSolver` reused across candidates: constraint AST +
    `(=> pᵢ (not Cᵢ))` built once on a persistent `Z3.Solver`; per candidate only
    `out == candidate` + one check-sat-assuming per constraint.

For a batch of random candidate bodies it (1) checks both report the **same**
satisfied bits, then (2) times each. Specs are built inline (no file dependency).

Run:  julia --project=. scripts/benchmark_constraint_satisfaction.jl
"""

const ROOT = dirname(@__DIR__)
push!(LOAD_PATH, joinpath(ROOT, "src"))
include(joinpath(ROOT, "src", "CEGIS.jl"))
using Random, Printf
const CG = CEGIS.CEXGeneration

function max_spec(k::Int)
    s = CG.Spec(); s.logic = "LIA"
    fn = "max$k"
    vars = ["x$i" for i in 0:k-1]
    s.synth_funs = [CG.SynthFun(fn, [(v, "Int") for v in vars], "Int")]
    s.free_vars = [CG.FreeVar(v, "Int") for v in vars]
    ap = "($fn $(join(vars, " ")))"
    bounds = ["(>= $ap $v)" for v in vars]
    isone = foldr((v, acc) -> "(or (= $v $ap) $acc)", vars[1:end-1]; init="(= $(vars[end]) $ap)")
    s.constraints = vcat(bounds, [isone])
    return s, fn, vars
end

"""Random Int-valued candidate body over `vars`."""
function rand_body(vars, depth, rng)
    if depth <= 0 || rand(rng) < 0.4
        return rand(rng) < 0.7 ? rand(rng, vars) : string(rand(rng, -3:3))
    end
    op = rand(rng, ["+", "-", "*", "ite"])
    if op == "ite"
        cmp = rand(rng, ["<", "<=", ">", ">=", "="])
        a = rand_body(vars, depth-1, rng); b = rand_body(vars, depth-1, rng)
        t = rand_body(vars, depth-1, rng); e = rand_body(vars, depth-1, rng)
        return "(ite ($cmp $a $b) $t $e)"
    end
    "($op $(rand_body(vars, depth-1, rng)) $(rand_body(vars, depth-1, rng)))"
end

function benchmark(k::Int; n::Int=120, depth::Int=4, seed::Int=1)
    spec, fn, vars = max_spec(k)
    css = CG.ConstraintSatSolver(spec)
    rng = MersenneTwister(seed)
    cands = [rand_body(vars, depth, rng) for _ in 1:n]

    println("\n", "="^72)
    println("max$k  —  $n candidates, $(length(spec.constraints)) constraints")

    sub(c) = CG.check_constraint_satisfaction(spec, fn, c).satisfied
    ip(c)  = CG.check_constraint_satisfaction(css, fn, c).satisfied

    mism = count(c -> sub(c) != ip(c), cands)
    println("parity: $(n - mism)/$n candidates agree" * (mism == 0 ? "  OK" : "  NO ($mism)"))

    sub(cands[1]); ip(cands[1])    # warm up (JIT)
    tip  = @elapsed for c in cands; ip(c);  end
    tsub = @elapsed for c in cands; sub(c); end
    @printf "subprocess : %7.3fs   (%6.2f ms/candidate)\n" tsub 1000tsub/n
    @printf "in-process : %7.3fs   (%6.2f ms/candidate)\n" tip 1000tip/n
    @printf "speedup    : %.2fx\n" tsub / tip
end

function main()
    benchmark(4; n=10, depth=4)
   # benchmark(5; n=120, depth=4)
    println("\n", "="^72)
end

main()
