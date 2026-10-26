"""
Tests for witness-battery management in `HybridCDGPEvaluator`: admission limits
(global cap, cross-constraint dedupe) and round-boundary eviction policies
(`:none`, `:fifo`, `:info`, `:ratio`). See `CDGP_WITNESS_PLAN.md`.
"""

@testset "Witness battery management" verbose = true begin
    CG = CEGIS.CEXGeneration
    GS = CEGIS.GeneticSearch
    spec_path = find_spec_file("max4_simple")
    spec = CG.parse_spec_from_file(spec_path)
    grammar = CEGIS.build_grammar_from_spec(spec_path)
    mk(; policy=:none, kw...) =
        GS.HybridCDGPEvaluator(spec, grammar, :Expr, 6; witness_policy=policy, kw...)

    @testset "policy validation" begin
        @test_throws ArgumentError mk(policy=:bogus)
        for p in (:none, :fifo, :info, :ratio); @test mk(policy=p).witness_policy === p; end
    end

    @testset "global cap bounds the pool" begin
        e = mk(policy=:none, max_witnesses_total=3, max_witnesses=99)
        st = fill(:sat, e.n_constraints)
        ws = [Dict{String,Any}("x0"=>i, "x1"=>0, "x2"=>0, "x3"=>0) for i in 1:e.n_constraints]
        GS._hybrid_record_witnesses!(e, st, ws)
        @test length(e.witness_bank) <= 3
    end

    @testset "cross-constraint input dedupe" begin
        w = Dict{String,Any}("x0"=>7, "x1"=>1, "x2"=>2, "x3"=>3)
        st = fill(:sat, 3)
        off = mk(policy=:none, witness_dedupe_inputs=false)
        GS._hybrid_record_witnesses!(off, st, [copy(w) for _ in 1:3])
        on = mk(policy=:none, witness_dedupe_inputs=true)
        GS._hybrid_record_witnesses!(on, st, [copy(w) for _ in 1:3])
        @test length(off.witness_bank) == 3      # one input, banked three times
        @test length(on.witness_bank) == 1       # ... collapsed to one case
    end

    @testset ":none never evicts" begin
        e = mk(policy=:none)
        GS._hybrid_record_witnesses!(e, fill(:sat, e.n_constraints),
            [Dict{String,Any}("x0"=>i,"x1"=>0,"x2"=>0,"x3"=>0) for i in 1:e.n_constraints])
        n = length(e.witness_bank)
        @test GS.hybrid_evict_witnesses!(e, 1) == 0
        @test length(e.witness_bank) == n
    end

    @testset ":info drops constant columns, keeps discriminating ones" begin
        e = mk(policy=:info, max_witnesses=99)
        # Three witnesses on constraint 1: two we will make constant, one split.
        for i in 1:3
            push!(e.witness_bank, (1, Dict{String,Any}("x0"=>i,"x1"=>0,"x2"=>0,"x3"=>0)))
        end
        e.witness_counts[1] = 3
        # Rows: witness 1 all-pass, witness 2 all-fail, witness 3 discriminates.
        e.witness_cache["gA"] = [0.0, 1.0, 0.0]
        e.witness_cache["gB"] = [0.0, 1.0, 1.0]
        e.witness_cache["gC"] = [0.0, 1.0, 0.0]
        union!(e.witness_touched, ["gA", "gB", "gC"])
        nev = GS.hybrid_evict_witnesses!(e, 1)
        @test nev == 2
        @test length(e.witness_bank) == 1
        @test e.witness_bank[1][2]["x0"] == 3          # the discriminating one survived
        @test e.witness_counts[1] == 1                  # counts recomputed
        @test isempty(e.witness_cache)                  # stale prefixes invalidated
        @test isempty(e.witness_touched)
        lg = GS.hybrid_witness_log(e)[end]
        @test lg.allpass == 1 && lg.allfail == 1 && lg.evicted == 2
    end

    @testset ":info keeps >=1 witness per constraint when all columns constant" begin
        e = mk(policy=:info, max_witnesses=99)
        for i in 1:2
            push!(e.witness_bank, (1, Dict{String,Any}("x0"=>i,"x1"=>0,"x2"=>0,"x3"=>0)))
        end
        e.witness_counts[1] = 2
        e.witness_cache["gA"] = [0.0, 0.0]
        e.witness_cache["gB"] = [0.0, 0.0]
        union!(e.witness_touched, ["gA", "gB"])
        GS.hybrid_evict_witnesses!(e, 1)
        @test length(e.witness_bank) == 1               # not zero
        @test e.witness_counts[1] == 1
    end

    @testset ":info abstains on too little evidence" begin
        e = mk(policy=:info, max_witnesses=99)
        push!(e.witness_bank, (1, Dict{String,Any}("x0"=>1,"x1"=>0,"x2"=>0,"x3"=>0)))
        e.witness_counts[1] = 1
        e.witness_cache["gA"] = [0.0]
        push!(e.witness_touched, "gA")
        @test GS.hybrid_evict_witnesses!(e, 1) == 0     # 1 row is not a column
        @test length(e.witness_bank) == 1
    end

    @testset ":fifo retires the oldest of a saturated constraint" begin
        e = mk(policy=:fifo, max_witnesses=2)
        for i in 1:2
            push!(e.witness_bank, (1, Dict{String,Any}("x0"=>i,"x1"=>0,"x2"=>0,"x3"=>0)))
        end
        e.witness_counts[1] = 2                         # constraint 1 is at cap
        push!(e.witness_bank, (2, Dict{String,Any}("x0"=>9,"x1"=>0,"x2"=>0,"x3"=>0)))
        e.witness_counts[2] = 1                         # constraint 2 is not
        @test GS.hybrid_evict_witnesses!(e, 1) == 1
        @test length(e.witness_bank) == 2
        @test e.witness_bank[1][2]["x0"] == 2           # oldest of c1 gone
        @test e.witness_counts == [1, 1, 0, 0, 0]
    end

    @testset "evicted witness is not immediately re-banked" begin
        e = mk(policy=:fifo, max_witnesses=1)
        w = Dict{String,Any}("x0"=>5, "x1"=>0, "x2"=>0, "x3"=>0)
        st = [:sat, :unsat, :unsat, :unsat, :unsat]
        GS._hybrid_record_witnesses!(e, st, [copy(w), nothing, nothing, nothing, nothing])
        @test length(e.witness_bank) == 1
        push!(e.witness_bank, (1, Dict{String,Any}("x0"=>6,"x1"=>0,"x2"=>0,"x3"=>0)))
        e.witness_counts[1] = 2
        GS.hybrid_evict_witnesses!(e, 1)                # retires x0=5
        GS._hybrid_record_witnesses!(e, st, [copy(w), nothing, nothing, nothing, nothing])
        @test !any(b -> b[2]["x0"] == 5, e.witness_bank)  # witness_seen still blocks it
    end

    @testset ":ratio bounds the pool against the test set" begin
        e = GS.HybridCDGPEvaluator(spec, grammar, :Expr, 6;
                                   witness_policy=:ratio, witness_test_ratio=1.0,
                                   max_witnesses=99)
        for i in 1:20
            push!(e.witness_bank, (1 + (i % e.n_constraints),
                                   Dict{String,Any}("x0"=>i,"x1"=>0,"x2"=>0,"x3"=>0)))
        end
        fill!(e.witness_counts, 0)
        for (ci, _) in e.witness_bank; e.witness_counts[ci] += 1; end
        # No tests yet ⇒ budget floors at one per constraint.
        GS.hybrid_evict_witnesses!(e, 1)
        @test length(e.witness_bank) == e.n_constraints
        @test all(>=(1), e.witness_counts)
        @test isempty(e.witness_cache)
        # With 10 tests and ratio 1.0 the pool may grow back to 10.
        append!(e.test_cases, [IOExample(Dict(:x0=>i,:x1=>0,:x2=>0,:x3=>0), i) for i in 1:10])
        for i in 21:40
            push!(e.witness_bank, (1 + (i % e.n_constraints),
                                   Dict{String,Any}("x0"=>i,"x1"=>0,"x2"=>0,"x3"=>0)))
        end
        GS.hybrid_evict_witnesses!(e, 2)
        @test length(e.witness_bank) == 10
        @test e.witness_bank[end][2]["x0"] == 40      # newest retained, oldest retired
    end
end
