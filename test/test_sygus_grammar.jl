"""
Tests for per-problem grammars declared in a `synth-fun` body
(`CEGIS.GrammarBuilding.sygus_grammar_to_csgrammar` and friends), the generalised
nonterminal handling in `rulenode_to_smt2`, and cross-grammar program transfer
(`remap_rulenode_by_expression`).

The parser used to read only a `synth-fun`'s name, parameters and return sort and drop
the grammar body silently, so these tests pin the behaviour that replaced that: a spec
declaring a grammar gets that grammar, and a spec without one still falls back to the
logic-wide operation sets.
"""

const GBT = CEGIS.GrammarBuilding
const CXGT = CEGIS.CEXGeneration

const _SYGUS_V2_SPEC = """
(set-logic LIA)
(synth-fun findIdx ((x0 Int) (x1 Int) (k Int)) Int
  ((Start Int) (CondExpr Bool))
  ((Start Int (x0 x1 k 0 1 2 (ite CondExpr Start Start)))
   (CondExpr Bool ((< Start Start) (> Start Start)))))
(declare-var x0 Int)
(declare-var x1 Int)
(declare-var k Int)
(constraint (=> (and (< x0 x1) (< k x0)) (= (findIdx x0 x1 k) 0)))
(constraint (=> (and (< x0 x1) (> k x0) (< k x1)) (= (findIdx x0 x1 k) 1)))
(constraint (=> (and (< x0 x1) (> k x1)) (= (findIdx x0 x1 k) 2)))
(check-synth)
"""

const _SYGUS_V1_SPEC = """
(set-logic LIA)
(synth-fun f ((x Int)) Int
  ((Start Int (x 0 1 (+ Start Start) (ite CondExpr Start Start)))
   (CondExpr Bool ((<= Start Start)))))
(declare-var x Int)
(constraint (>= (f x) x))
(check-synth)
"""

"""Write `text` to a temporary `.sl` file and hand the path to `f`."""
function with_spec_file(f::Function, text::String)
    path = tempname() * ".sl"
    write(path, text)
    try
        f(path)
    finally
        rm(path; force = true)
    end
end

@testset "SyGuS synth-fun grammars" begin

    @testset "grammar body is parsed, not dropped" begin
        with_spec_file(_SYGUS_V2_SPEC) do path
            spec = CXGT.parse_spec_from_file(path)
            sf = spec.synth_funs[1]
            @test sf.name == "findIdx"
            @test length(sf.params) == 3
            @test GBT.has_sygus_grammar(sf)

            decls, groups = GBT.sygus_grammar_parts(sf)
            @test decls == [("Start", "Int"), ("CondExpr", "Bool")]
            @test length(groups) == 2
        end
    end

    @testset "a grammar-free synth-fun still falls back to the logic's operations" begin
        with_spec_file("""
        (set-logic LIA)
        (synth-fun max2 ((x Int) (y Int)) Int)
        (declare-var x Int)
        (declare-var y Int)
        (constraint (>= (max2 x y) x))
        (check-synth)
        """) do path
            spec = CXGT.parse_spec_from_file(path)
            @test !GBT.has_sygus_grammar(spec.synth_funs[1])
            g = CEGIS.build_grammar_from_spec(path)       # must not throw
            @test length(g.rules) > 0
        end
    end

    @testset "nonterminals are renamed to Expr / BoolExpr" begin
        with_spec_file(_SYGUS_V2_SPEC) do path
            spec = CXGT.parse_spec_from_file(path)
            src, names = GBT.sygus_grammar_to_csgrammar(spec.synth_funs[1])
            @test names["Start"] == "Expr"          # start symbol the search expects
            @test names["CondExpr"] == "BoolExpr"
            @test occursin("ifelse(BoolExpr, Expr, Expr)", src)
            @test occursin("(Expr < Expr)", src)
        end
    end

    @testset "productions become exactly the declared rules, in order" begin
        with_spec_file(_SYGUS_V2_SPEC) do path
            spec = CXGT.parse_spec_from_file(path)
            g = GBT.build_grammar_from_synth_fun(spec.synth_funs[1])
            # 3 variables + 3 literals + ite, then 2 comparisons.
            @test length(g.rules) == 9
            @test g.rules[1:3] == [:x0, :x1, :k]
            @test g.rules[4:6] == [0, 1, 2]
            @test count(t -> t === :BoolExpr, g.types) == 2
            # Nothing the family does not need leaked in from a logic-wide default.
            @test !any(r -> r isa Expr && r.head === :call && r.args[1] === :*, g.rules)
        end
    end

    @testset "the declared grammar beats the logic default" begin
        with_spec_file(_SYGUS_V2_SPEC) do path
            g = CEGIS.build_grammar_from_spec(path)
            @test length(g.rules) == 9
            @test Set(unique(g.types)) == Set([:Expr, :BoolExpr])
        end
    end

    @testset "SyGuS-v1 merged declarations, and + translation" begin
        with_spec_file(_SYGUS_V1_SPEC) do path
            spec = CXGT.parse_spec_from_file(path)
            g = GBT.build_grammar_from_synth_fun(spec.synth_funs[1])
            @test any(r -> r isa Expr && r.head === :call && r.args[1] === :+, g.rules)
            @test any(r -> r isa Expr && r.head === :call && r.args[1] === :<=, g.rules)
        end
    end

    @testset "(Variable Int) and (Constant Int) special forms" begin
        with_spec_file("""
        (set-logic LIA)
        (synth-fun f ((a Int) (b Int)) Int
          ((Start Int) (C Bool))
          ((Start Int ((Variable Int) (Constant Int) (ite C Start Start)))
           (C Bool ((< Start Start)))))
        (declare-var a Int)
        (constraint (>= (f a a) a))
        (check-synth)
        """) do path
            spec = CXGT.parse_spec_from_file(path)
            sf = spec.synth_funs[1]
            g = GBT.build_grammar_from_synth_fun(sf; constants = Int[0, 7])
            @test :a in g.rules && :b in g.rules       # (Variable Int) → both parameters
            @test 0 in g.rules && 7 in g.rules         # (Constant Int) → the supplied set
            # Without a constant set, (Constant Int) is an error rather than a silent drop.
            @test_throws Exception GBT.build_grammar_from_synth_fun(sf)
        end
    end

    @testset "unsupported constructs are rejected loudly" begin
        # A Bool start nonterminal cannot work: the search starts at :Expr.
        with_spec_file("""
        (set-logic LIA)
        (synth-fun p ((x Int)) Bool
          ((Start Bool) (E Int))
          ((Start Bool ((< E E))) (E Int (x 0))))
        (declare-var x Int)
        (constraint (p x))
        (check-synth)
        """) do path
            spec = CXGT.parse_spec_from_file(path)
            @test_throws Exception GBT.build_grammar_from_synth_fun(spec.synth_funs[1])
        end
    end

    @testset "SMT conversion of a program over a parsed grammar" begin
        with_spec_file(_SYGUS_V2_SPEC) do path
            spec = CXGT.parse_spec_from_file(path)
            g = GBT.build_grammar_from_synth_fun(spec.synth_funs[1])
            ridx(pred) = findfirst(i -> pred(g.rules[i]), 1:length(g.rules))
            ite = ridx(r -> r isa Expr && r.head === :call && r.args[1] === :ifelse)
            lt  = ridx(r -> r isa Expr && r.head === :call && r.args[1] === :<)
            k   = ridx(r -> r === :k)
            x0  = ridx(r -> r === :x0)
            zero_, one_ = ridx(r -> r isa Integer && r == 0), ridx(r -> r isa Integer && r == 1)

            node = RuleNode(ite, [RuleNode(lt, [RuleNode(k), RuleNode(x0)]),
                                  RuleNode(zero_), RuleNode(one_)])
            smt = CXGT.rulenode_to_smt2(node, g)
            @test smt == "(ite (< k x0) 0 1)"
        end
    end

    @testset "the reference solution verifies against the spec it came from" begin
        with_spec_file(_SYGUS_V2_SPEC) do path
            spec = CXGT.parse_spec_from_file(path)
            g = GBT.build_grammar_from_synth_fun(spec.synth_funs[1])
            ridx(pred) = findfirst(i -> pred(g.rules[i]), 1:length(g.rules))
            ite = ridx(r -> r isa Expr && r.head === :call && r.args[1] === :ifelse)
            lt  = ridx(r -> r isa Expr && r.head === :call && r.args[1] === :<)
            v(name) = RuleNode(ridx(r -> r === Symbol(name)))
            lit(x) = RuleNode(ridx(r -> r isa Integer && r == x))
            # ite(k < x0, 0, ite(k < x1, 1, 2))
            node = RuleNode(ite, [RuleNode(lt, [v("k"), v("x0")]), lit(0),
                        RuleNode(ite, [RuleNode(lt, [v("k"), v("x1")]), lit(1), lit(2)])])
            exprs = Dict("findIdx" => CXGT.rulenode_to_smt2(node, g))
            @test CXGT.verify_query(CXGT.generate_query(spec, exprs)).status == :unsat
        end
    end

    @testset "programs transfer between two problems' grammars" begin
        two = """
        (set-logic LIA)
        (synth-fun m ((x1 Int) (x2 Int)) Int
          ((Start Int) (C Bool))
          ((Start Int (x1 x2 (ite C Start Start))) (C Bool ((> Start Start)))))
        (declare-var x1 Int)
        (constraint (>= (m x1 x1) x1))
        (check-synth)
        """
        three = """
        (set-logic LIA)
        (synth-fun m ((x1 Int) (x2 Int) (x3 Int)) Int
          ((Start Int) (C Bool))
          ((Start Int (x1 x2 x3 (ite C Start Start))) (C Bool ((> Start Start)))))
        (declare-var x1 Int)
        (constraint (>= (m x1 x1 x1) x1))
        (check-synth)
        """
        with_spec_file(two) do p2
            with_spec_file(three) do p3
                g2 = CEGIS.build_grammar_from_spec(p2)
                g3 = CEGIS.build_grammar_from_spec(p3)
                ridx(g, pred) = findfirst(i -> pred(g.rules[i]), 1:length(g.rules))
                ite2 = ridx(g2, r -> r isa Expr && r.head === :call && r.args[1] === :ifelse)
                gt2  = ridx(g2, r -> r isa Expr && r.head === :call && r.args[1] === :>)
                x1, x2 = ridx(g2, r -> r === :x1), ridx(g2, r -> r === :x2)
                max2 = RuleNode(ite2, [RuleNode(gt2, [RuleNode(x1), RuleNode(x2)]),
                                       RuleNode(x1), RuleNode(x2)])

                moved = GBT.remap_rulenode_by_expression(max2, g2, g3)
                # Same program, different rule indices: ifelse sits after three variables
                # in g3 but after two in g2, which is exactly what an index shift gets wrong.
                @test rulenode2expr(moved, g3) == rulenode2expr(max2, g2)
                @test moved.ind != max2.ind

                # A seed using a rule the target grammar lacks is skipped, not mangled.
                g1_only = RuleNode(ridx(g3, r -> r === :x3))
                @test GBT.try_remap_rulenode(g1_only, g3, g2) === nothing
                @test_throws Exception GBT.remap_rulenode_by_expression(g1_only, g3, g2)
            end
        end
    end
end
