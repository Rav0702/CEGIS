"""
Tests for per-constraint failure attribution on the SAT (counterexample) path of
the verification query (`generate_query` / `verify_query`).

On SAT, `Z3Result.violated_constraints` should list the 1-based indices (into
`spec.constraints`) of the constraints the candidate violates *at the returned
counterexample point*. On UNSAT it should be empty.
"""

@testset "Constraint failure attribution (SAT)" verbose = true begin
    CG = CEGIS.CEXGeneration

    @testset "max2: candidate `x0` violates exactly constraint 2" begin
        spec = CG.parse_spec_from_file(find_spec_file("max2_simple"))
        # max2 constraints: 1=(>= out x0), 2=(>= out x1), 3=(or (= x0 out) (= x1 out)).
        # Candidate `x0` returns x0 always ⇒ c1 and c3 hold identically, so the only
        # satisfiable counterexample must falsify c2 ⇒ attribution is deterministic.
        r = CG.verify_query(CG.generate_query(spec, Dict("max2" => "x0")))
        @test r.status == :sat
        @test r.violated_constraints == [2]
    end

    @testset "max2: correct candidate is UNSAT with no violations" begin
        spec = CG.parse_spec_from_file(find_spec_file("max2_simple"))
        r = CG.verify_query(CG.generate_query(spec, Dict("max2" => "(ite (>= x0 x1) x0 x1)")))
        @test r.status == :unsat
        @test isempty(r.violated_constraints)
    end

    @testset "max4: candidate `x0` violates a nonempty subset of {2,3,4}" begin
        spec = CG.parse_spec_from_file(find_spec_file("max4_simple"))
        # constraints 1 (>= out x0) and 5 (out is one of the inputs) hold for `x0`,
        # so any counterexample violates one or more of 2,3,4.
        r = CG.verify_query(CG.generate_query(spec, Dict("max4" => "x0")))
        @test r.status == :sat
        @test !isempty(r.violated_constraints)
        @test issubset(Set(r.violated_constraints), Set([2, 3, 4]))
    end

    @testset "model stays clean (no cand_c_* leakage)" begin
        spec = CG.parse_spec_from_file(find_spec_file("max2_simple"))
        r = CG.verify_query(CG.generate_query(spec, Dict("max2" => "x0")))
        @test r.status == :sat
        @test !any(k -> startswith(k, "cand_c_"), keys(r.model))
    end
end

@testset "Universal per-constraint check (one query)" verbose = true begin
    CG = CEGIS.CEXGeneration
    # Indices of constraints the candidate violates over ALL inputs.
    universal_violated(spec, cands) =
        [i for (i, r) in enumerate(CG.verify_graded_query(CG.generate_graded_query(spec, cands)))
         if r.status == :sat]

    @testset "result has one verdict per constraint" begin
        spec = CG.parse_spec_from_file(find_spec_file("max4_simple"))
        rs = CG.verify_graded_query(CG.generate_graded_query(spec, Dict("max4" => "x0")))
        @test length(rs) == length(spec.constraints)
    end

    @testset "max4 `x0`: stable universal {2,3,4} (vs noisy per-point)" begin
        spec = CG.parse_spec_from_file(find_spec_file("max4_simple"))
        @test universal_violated(spec, Dict("max4" => "x0")) == [2, 3, 4]
    end

    @testset "max4 `sum_all`: violates every constraint" begin
        spec = CG.parse_spec_from_file(find_spec_file("max4_simple"))
        @test universal_violated(spec, Dict("max4" => "(+ (+ x0 x1) (+ x2 x3))")) == [1, 2, 3, 4, 5]
    end

    @testset "max2 `x0`: only constraint 2" begin
        spec = CG.parse_spec_from_file(find_spec_file("max2_simple"))
        @test universal_violated(spec, Dict("max2" => "x0")) == [2]
    end

    @testset "correct candidate: nothing violated" begin
        spec = CG.parse_spec_from_file(find_spec_file("max2_simple"))
        @test universal_violated(spec, Dict("max2" => "(ite (>= x0 x1) x0 x1)")) == Int[]
    end

    @testset "sat verdicts carry a witness" begin
        spec = CG.parse_spec_from_file(find_spec_file("max2_simple"))
        rs = CG.verify_graded_query(CG.generate_graded_query(spec, Dict("max2" => "x0")))
        @test !isempty(rs[2].witness)            # constraint 2 is violated → has a witness
        @test isempty(rs[1].witness)             # constraint 1 holds → no witness
    end
end
