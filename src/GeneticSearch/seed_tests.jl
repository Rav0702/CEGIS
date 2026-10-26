"""
    seed_tests.jl

Seeded starting tests (spec_knowledge/EXPERIMENTS.md, E3). CDGP normally starts with no tests and discovers the
spec's case regions one counterexample at a time. `run_cdgp(...; seed_tests = :regions)` hands it one test per
region the specification itself names before generation 0: one point per satisfiable premise `P` of the spec's
implications `P ⇒ …` (premises that mention the synthesized function are skipped), each turned into a test by
the same complete/incomplete policy as a counterexample. `seed_tests = :random` is the control: the same number
of uniformly random inputs, so "where the tests come from" is separated from "how many there are".
`seed_tests = :regions_inner` (E3b) keeps one point per region but draws it uniformly from inside the region instead
of taking z3's model, which sits on the region's boundary (0/1 corners, where wrong programs such as `x+y+z+w` fit).

Specs without implication premises (bound specs such as above_n, max_n) get no region points.
"""

"""
    spec_region_points(spec) -> Vector{Dict{String,Any}}

One satisfying point (free-variable name → value) per distinct premise of the spec's implications, in constraint
order. Nested implications contribute the conjunction of their premises. Unsatisfiable premises are skipped.
"""
spec_region_points(spec)::Vector{Dict{String,Any}} = [pt for (_, pt) in _region_premise_points(spec)]

"""(premise, z3 point) for each distinct, satisfiable, f-free premise of the spec's implications, in constraint order."""
function _region_premise_points(spec)::Vector{Tuple{String,Dict{String,Any}}}
    fname = spec.synth_funs[1].name
    vars = String[fv.name for fv in spec.free_vars]
    sorts = Dict(fv.name => fv.sort for fv in spec.free_vars)
    premises = String[]
    for c in spec.constraints
        s = CEXGeneration.read_sexprs(c)[1]
        prem = Any[]
        body = s
        while body isa Vector && body[1] == "=>" && length(body) >= 2
            append!(prem, body[2:end-1])
            body = body[end]
        end
        isempty(prem) && continue
        P = length(prem) == 1 ? prem[1] : Any["and"; prem]
        _sx_has(P, fname) && continue
        str = CEXGeneration.sexp_to_str(P)
        str in premises || push!(premises, str)
    end
    out = Tuple{String,Dict{String,Any}}[]
    for P in premises
        q = "(set-logic $(spec.logic))
" * join(("(declare-const $v $(sorts[v]))" for v in vars), "
") *
            "
(assert $P)
(check-sat)
(get-value ($(join(vars, ' '))))
"
        r = try
            CEXGeneration.verify_query(q)
        catch
            nothing
        end
        (r === nothing || r.status !== :sat) && continue
        all(v -> haskey(r.model, v), vars) || continue
        push!(out, (P, Dict{String,Any}(v => r.model[v] for v in vars)))
    end
    return out
end

"""
    spec_region_inner_points(spec, rng; lo=-10, hi=10, tries=200_000) -> (points, fallbacks)

E3b: one point per satisfiable premise, as `spec_region_points`, but drawn uniformly from the premise's points in
`lo:hi` (rejection sampling from the caller's `rng`, the premise evaluated pointwise) instead of z3's boundary
model. A premise with no hit in `tries` draws keeps its z3 point and is counted in `fallbacks`.
"""
function spec_region_inner_points(spec, rng::AbstractRNG; lo::Integer = -10, hi::Integer = 10,
                                  tries::Integer = 200_000)
    fname = spec.synth_funs[1].name
    nofun = _ -> throw(CEXGeneration.PointwiseError("premise applies the synthesized function"))
    pts, fallbacks = Dict{String,Any}[], 0
    for (P, zpt) in _region_premise_points(spec)
        sx = CEXGeneration.read_sexprs(P)[1]
        hit = nothing
        for _ in 1:tries
            x = Dict{String,Any}(fv.name => (fv.sort == "Bool" ? rand(rng, Bool) : rand(rng, lo:hi)) for fv in spec.free_vars)
            if CEXGeneration.eval_constraint_pointwise(sx, fname, x, nofun)
                hit = x
                break
            end
        end
        hit === nothing && (fallbacks += 1)
        push!(pts, something(hit, zpt))
    end
    return (points = pts, fallbacks = fallbacks)
end

"""
    random_points(spec, k, rng; lo=-10, hi=10) -> Vector{Dict{String,Any}}

`k` uniformly random inputs (integers in `lo:hi`, Booleans uniform) from the caller's `rng`, so the GA's own
random stream is untouched.
"""
random_points(spec, k::Integer, rng::AbstractRNG; lo::Integer = -10, hi::Integer = 10) =
    [Dict{String,Any}(fv.name => (fv.sort == "Bool" ? rand(rng, Bool) : rand(rng, lo:hi)) for fv in spec.free_vars)
     for _ in 1:k]
