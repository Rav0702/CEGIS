"""
    ObservationalSamples.jl

The fixed input points behind the *observational* equivalence signature used to collapse
the bottom-up bank: two programs that agree on every sampled input are treated as the
same program and only one is kept, which is what keeps `combine` from blowing up into a
cartesian product of behaviourally identical candidates.

The sample therefore decides what the search can tell apart. Drawing it from a fixed
window loses any distinction that only shows outside that window — see
`observational_samples` for the concrete failure this caused.
"""

"""
    spec_integer_literals(spec) :: Vector{Int}

The integer literals appearing in the spec's constraints. Splitting is on the SMT-LIB
delimiters only, so an identifier stays one token and the digits inside it (`max3`,
`x10`) are never mistaken for literals.
"""
function spec_integer_literals(spec)::Vector{Int}
    out = Int[]
    for c in spec.constraints
        for tok in split(c, r"[\s()]+")
            occursin(r"^-?[0-9]+$", tok) || continue
            v = tryparse(Int, tok)
            v === nothing || push!(out, v)
        end
    end
    return sort!(unique!(out))
end

"""
    observational_samples(spec; n_samples=32, rng, mode=:literals) :: Vector{Dict{Symbol,Any}}

Input points at which to evaluate a candidate for its behavioural signature.

A sample drawn only from `-9:9` cannot separate programs whose behaviour differs outside
that window. On `piecewise_N`, whose thresholds are 10, 20, …, every guard true across
the whole sample (`x < 10`, `x < 20`, and even the constant comparison `2 < 8`) hashes to
one bank cell, so the guard a solution needs is dropped in favour of whichever arrived
first and the bank fills with constants — the family was unsolvable at N = 2 for that
reason alone, with nothing wrong with the search.

The pool therefore carries the spec's own literals and their lower neighbours (the pair
that separates `x < c` from `x < c+1`, and a threshold from its boundary) and spans a
range wide enough to reach them. The first points are pinned to the literals so coverage
does not depend on the draw.

A spec with no integer literals — every `max_N` spec — keeps the original behaviour bit
for bit: `n_samples` uniform draws from `-9:9` off the same seed, so earlier numbers stay
comparable.

`mode` selects between the two, and the choice is a real trade-off rather than a bug fix
with a free lunch:

- `:literals` (default) — the pool described above. Required wherever the interesting
  behaviour lives outside `-9:9`.
- `:uniform` — `n_samples` uniform draws from `-9:9` regardless of the spec, i.e. the
  original behaviour for every family.

A finer sample distinguishes more programs, which means the bank collapses *less* and
the iterator's `combine` has more to chew through. On `array_search_N`, where all the
action already happens inside `-9:9`, the extra resolution is pure cost: the family
reached N=11 under `:uniform` and N=7 at the same 300 s budget under `:literals`. On
`piecewise_N` the coarse sample is not merely slower but wrong — it cannot represent the
guard a solution needs. Pick per family and report which was used.

`rng` is passed in rather than constructed here: `Random` is a stdlib the package does
not declare as a dependency, and the caller already owns the seed.
"""
function observational_samples(spec; n_samples::Int = 32, rng,
                               mode::Symbol = :literals)::Vector{Dict{Symbol,Any}}
    mode in (:literals, :uniform) ||
        error("observational_samples: mode must be :literals or :uniform, got $mode")
    vars = [Symbol(fv.name) for fv in spec.free_vars]
    consts = mode === :uniform ? Int[] : spec_integer_literals(spec)
    samples = Vector{Dict{Symbol,Any}}(undef, n_samples)

    if isempty(consts)
        # Mix of ties, zeros, negatives and spread values so distinct max-behaviours separate.
        for k in 1:n_samples
            samples[k] = Dict{Symbol,Any}(v => rand(rng, -9:9) for v in vars)
        end
        return samples
    end

    lo = min(-9, minimum(consts)) - 2
    hi = max(9, maximum(consts)) + 2
    pinned = sort!(unique!(reduce(vcat, [[c - 1, c] for c in consts])))
    pool = sort!(unique!(vcat(collect(-9:9), pinned,
                              round.(Int, range(lo, hi; length = 16)))))

    n_pinned = min(length(pinned), n_samples ÷ 2)
    for k in 1:n_pinned
        # All variables at the same literal: a diagonal point, which also exercises ties.
        samples[k] = Dict{Symbol,Any}(v => pinned[k] for v in vars)
    end
    for k in (n_pinned + 1):n_samples
        samples[k] = Dict{Symbol,Any}(v => rand(rng, pool) for v in vars)
    end
    return samples
end
