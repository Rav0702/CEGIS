"""
Tests for the input sample behind the observational equivalence signature
(`CEGIS.PartialSat.observational_samples`).

The sample decides what the bottom-up bank can tell apart. It used to be 32 uniform
draws from a hardcoded `-9:9`, which made every guard that is true across that window
— `x < 10`, `x < 20`, and the constant comparison `2 < 8` alike — collapse into one
bank cell, and left `piecewise_N` unsolvable at N = 2. These tests pin both halves of
the fix: literals are found without being confused with digits inside identifiers, and
a spec with no literals keeps the original draws exactly.
"""

using Random

const PST = CEGIS.PartialSat
const CXGS = CEGIS.CEXGeneration

function _spec_with_constraints(constraints::Vector{String}, vars::Vector{String})
    spec = CXGS.Spec()
    spec.logic = "LIA"
    spec.synth_funs = [CXGS.SynthFun("f", [(v, "Int") for v in vars], "Int")]
    spec.free_vars = [CXGS.FreeVar(v, "Int") for v in vars]
    spec.constraints = constraints
    return spec
end

@testset "Observational samples" begin

    @testset "literals are extracted, identifier digits are not" begin
        # `max3` and `x1` must not contribute 3 and 1.
        spec = _spec_with_constraints(["(>= (max3 x1 x2 x3) x1)"], ["x1", "x2", "x3"])
        @test PST.spec_integer_literals(spec) == Int[]

        spec = _spec_with_constraints(["(=> (< x10 20) (= (f x10) 7))"], ["x10"])
        @test PST.spec_integer_literals(spec) == [7, 20]

        # SMT-LIB writes a negative as (- 1); the token split yields "-" and "1".
        spec = _spec_with_constraints(["(= (f x) (- 1))"], ["x"])
        @test PST.spec_integer_literals(spec) == [1]
    end

    @testset "a spec without literals keeps the original draws exactly" begin
        spec = _spec_with_constraints(["(>= (max2 x1 x2) x1)", "(>= (max2 x1 x2) x2)"],
                                      ["x1", "x2"])
        got = PST.observational_samples(spec; n_samples = 32, rng = MersenneTwister(1234))

        rng = MersenneTwister(1234)
        vars = [:x1, :x2]
        want = [Dict{Symbol,Any}(v => rand(rng, -9:9) for v in vars) for _ in 1:32]
        @test got == want
        @test all(all(-9 <= v <= 9 for v in values(d)) for d in got)
    end

    @testset "the sample reaches a threshold outside -9:9" begin
        # piecewise_3: brackets split at 10 and 20, outputs 8, 2, 9.
        spec = _spec_with_constraints([
            "(=> (< x 10) (= (f x) 8))",
            "(=> (and (>= x 10) (< x 20)) (= (f x) 2))",
            "(=> (>= x 20) (= (f x) 9))"], ["x"])
        samples = PST.observational_samples(spec; n_samples = 32, rng = MersenneTwister(1234))
        values_seen = Set(v for d in samples for v in values(d))

        # Both thresholds and the point below each are present, so `x < 10`, `x < 20`
        # and `2 < 8` all take different signatures.
        for v in (9, 10, 19, 20)
            @test v in values_seen
        end
        @test maximum(values_seen) >= 20
    end

    @testset "guards separated by a threshold get different signatures" begin
        spec = _spec_with_constraints([
            "(=> (< x 10) (= (f x) 8))",
            "(=> (>= x 10) (= (f x) 2))"], ["x"])
        samples = PST.observational_samples(spec; n_samples = 32, rng = MersenneTwister(1234))
        sig(f) = [f(d[:x]) for d in samples]
        @test sig(x -> x < 10) != sig(x -> x < 20)      # was equal under -9:9
        @test sig(x -> x < 10) != sig(x -> 2 < 8)       # the constant-comparison guard
        @test sig(x -> x < 10) != sig(x -> x <= 10)
    end

    @testset "sample count is honoured and every variable is bound" begin
        spec = _spec_with_constraints(["(=> (< x 40) (= (f x y) 3))"], ["x", "y"])
        for n in (8, 16, 32)
            samples = PST.observational_samples(spec; n_samples = n, rng = MersenneTwister(7))
            @test length(samples) == n
            @test all(d -> sort(collect(keys(d))) == [:x, :y], samples)
        end
    end
end
