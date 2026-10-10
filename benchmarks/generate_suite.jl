#!/usr/bin/env julia
#
# Generator for the scalable benchmark families.
# =============================================
# Emits SyGuS-v2 `.sl` files for three families that scale in a parameter N, each
# carrying its own grammar in the `synth-fun` body (see src/GrammarBuilding/SyGuSGrammar.jl):
#
#   array_search_N   N = 2…15   N+1 constraints, mutually exclusive ordered guards.
#   piecewise_N      N = 2…12   N independent bracket constraints, arity stays 1.
#   max_N            N = 3…16   in three constraint granularities (see below).
#
# A family is useful here only if (a) its spec splits into many independently
# checkable constraints, so the partial-satisfaction score is graded rather than 0/1,
# and (b) solution_N embeds solution_{N-1}, so seed transfer between problems pays off.
#
# The max_N granularities are an ablation on (a) with everything else held fixed:
#   conj     1 constraint   — the whole spec as one conjunction; score degenerates to 0/1.
#   split    N+1            — N inequalities + the witness disjunction (today's files).
#   witness  2N             — the inequalities plus a per-input case split of the
#                             disjunction: "if x_i dominates every input then y = x_i".
#                             Each is sound and the set is complete, so the three
#                             granularities specify exactly the same function.
#
# Grammar tiers add a second axis, orthogonal to N:
#   d0  what the family needs: variables, the family's constants, ite, comparisons.
#   d1  d0 + `+` and `-`.
#   d2  d1 + `*` and the constants -1, 1, 2.
#
# Usage:
#   julia --project benchmarks/generate_suite.jl                  # all families, tier d0
#   julia --project benchmarks/generate_suite.jl --tier d0,d1     # several tiers
#   julia --project benchmarks/generate_suite.jl --family piecewise --validate
#
# --validate checks every emitted file: it parses, its declared grammar builds, the
# family's reference solution is expressible as a RuleNode *over that grammar*, and
# that program verifies `unsat` against the full spec. Without this gate a mistake in
# a generated spec would surface later as a solver failure rather than as a spec bug.

CEGIS_ROOT = dirname(@__DIR__)
push!(LOAD_PATH, joinpath(CEGIS_ROOT, "src"))

using HerbCore, HerbGrammar

# The validation gate needs the full pipeline (parser, grammar builder, Z3); plain
# generation does not, so only pay for loading it when asked.
const DO_VALIDATE = "--validate" in ARGS
if DO_VALIDATE
    include(joinpath(CEGIS_ROOT, "src", "CEGIS.jl"))
end

const OUT_ROOT = joinpath(CEGIS_ROOT, "benchmarks")

# ─────────────────────────────────────────────────────────────────────────────
# Grammar emission
# ─────────────────────────────────────────────────────────────────────────────

const TIERS = ("d0", "d1", "d2")

"""
    grammar_block(vars, constants, tier; indent)

The `synth-fun` grammar body: an Int start nonterminal `Start` over `vars`, the integer
`constants`, `ite` and the tier's arithmetic, plus a Bool nonterminal `CondExpr` over the
four order comparisons. Productions are emitted in a fixed order, so rule indices are a
deterministic function of the file — which is what lets a program be remapped between the
grammars of two problems in the same family.
"""
function grammar_block(vars::Vector{String}, constants::Vector{Int}, tier::String;
                       indent::String = "  ")
    tier in TIERS || error("unknown tier $tier (expected one of $(join(TIERS, ", ")))")
    terms = copy(vars)
    append!(terms, smt_int.(constants))
    tier == "d2" && append!(terms, smt_int.([-1, 1, 2]))
    unique!(terms)

    prods = String[join(terms, " "), "(ite CondExpr Start Start)"]
    if tier in ("d1", "d2")
        push!(prods, "(+ Start Start)", "(- Start Start)")
    end
    tier == "d2" && push!(prods, "(* Start Start)")

    conds = "(< Start Start) (<= Start Start) (> Start Start) (>= Start Start)"
    return string(
        indent, "((Start Int) (CondExpr Bool))\n",
        indent, "((Start Int (", join(prods, " "), "))\n",
        indent, " (CondExpr Bool (", conds, ")))")
end

"""SMT-LIB2 writes a negative integer as the application `(- k)`, never as `-k`."""
smt_int(v::Int) = v < 0 ? "(- $(abs(v)))" : string(v)

# ─────────────────────────────────────────────────────────────────────────────
# Family: array_search_N
# ─────────────────────────────────────────────────────────────────────────────
#
# Given x0 < x1 < … < x_{N-1} and a key k, return the index of the gap k falls into.
# The N+1 guards are mutually exclusive and ordered, so "satisfies constraints {1,2,3}"
# means "the first three branches of the decision list are right" — unlike max_N, whose
# N inequality constraints are interchangeable under permuting the inputs.
#
# Constraint shape follows spec_files/findidx_5_problem.sl verbatim (sortedness guard,
# strict bounds on k), so the generated files match the SyGuS-COMP array_search family.

function array_search_spec(n::Int, tier::String)
    xs = ["x$i" for i in 0:(n - 1)]
    vars = vcat(xs, ["k"])
    sorted = join(["(< x$(i) x$(i + 1))" for i in 0:(n - 2)], " ")
    guard(extra) = n == 1 ? "(and $extra)" : "(and $sorted $extra)"

    io = IOBuffer()
    println(io, "(set-logic LIA)")
    println(io)
    println(io, "(synth-fun findIdx (", join(["($v Int)" for v in vars], " "), ") Int")
    println(io, grammar_block(vars, collect(0:n), tier))
    println(io, ")")
    println(io)
    for v in vars
        println(io, "(declare-var $v Int)")
    end
    println(io)
    call = "(findIdx " * join(vars, " ") * ")"
    # Branch 0: k below the whole array.
    println(io, "(constraint (=> ", guard("(< k x0)"), " (= $call 0)))")
    # Branches 1…N-1: k strictly between two neighbours.
    for i in 1:(n - 1)
        println(io, "(constraint (=> ", guard("(> k x$(i - 1)) (< k x$(i))"), " (= $call $i)))")
    end
    # Branch N: k above the whole array.
    println(io, "(constraint (=> ", guard("(> k x$(n - 1))"), " (= $call $n)))")
    println(io)
    println(io, "(check-synth)")
    return String(take!(io))
end

"""Reference solution: `ite(k < x0, 0, ite(k < x1, 1, … N))`."""
function array_search_reference(g::AbstractGrammar, n::Int)
    node = int_literal(g, n)
    for i in (n - 1):-1:0
        node = ite(g, less(g, var(g, "k"), var(g, "x$i")), int_literal(g, i), node)
    end
    return node
end

# ─────────────────────────────────────────────────────────────────────────────
# Family: piecewise_N
# ─────────────────────────────────────────────────────────────────────────────
#
# One input, N brackets: (-inf, a1), [a1, a2), …, [a_{N-1}, inf), with output c_i on
# bracket i. The N constraints are fully independent — each is satisfiable alone by a
# constant program — so the partial score is exactly "brackets correct". Scales the
# solution's depth while arity stays 1, which separates "the bank helps" from "the
# grammar grew".
#
# Outputs are deliberately non-monotone in the bracket index (c_i = ((7i) mod 13) + 1,
# distinct for i = 1…12 because 7 is invertible mod 13) so no linear expression in x
# short-circuits the branching.

piecewise_thresholds(n::Int) = [10 * i for i in 1:(n - 1)]
piecewise_outputs(n::Int) = [((7 * i) % 13) + 1 for i in 1:n]

function piecewise_spec(n::Int, tier::String)
    a = piecewise_thresholds(n)
    c = piecewise_outputs(n)
    constants = sort(unique(vcat(a, c)))

    io = IOBuffer()
    println(io, "(set-logic LIA)")
    println(io)
    println(io, "(synth-fun piecewise ((x Int)) Int")
    println(io, grammar_block(["x"], constants, tier))
    println(io, ")")
    println(io)
    println(io, "(declare-var x Int)")
    println(io)
    call = "(piecewise x)"
    for i in 1:n
        lo = i == 1 ? nothing : a[i - 1]
        hi = i == n ? nothing : a[i]
        cond = lo === nothing ? "(< x $(hi))" :
               hi === nothing ? "(>= x $(lo))" :
               "(and (>= x $(lo)) (< x $(hi)))"
        println(io, "(constraint (=> $cond (= $call $(smt_int(c[i])))))")
    end
    println(io)
    println(io, "(check-synth)")
    return String(take!(io))
end

"""Reference solution: `ite(x < a1, c1, ite(x < a2, c2, … cN))`."""
function piecewise_reference(g::AbstractGrammar, n::Int)
    a = piecewise_thresholds(n)
    c = piecewise_outputs(n)
    node = int_literal(g, c[n])
    for i in (n - 1):-1:1
        node = ite(g, less(g, var(g, "x"), int_literal(g, a[i])), int_literal(g, c[i]), node)
    end
    return node
end

# ─────────────────────────────────────────────────────────────────────────────
# Family: max_N, three constraint granularities
# ─────────────────────────────────────────────────────────────────────────────

const MAX_GRANULARITIES = ("conj", "split", "witness")

function max_spec(n::Int, tier::String, granularity::String)
    granularity in MAX_GRANULARITIES ||
        error("unknown granularity $granularity (expected one of $(join(MAX_GRANULARITIES, ", ")))")
    xs = ["x$i" for i in 1:n]
    call = "(max$n " * join(xs, " ") * ")"
    ge = ["(>= $call $x)" for x in xs]
    witness_disjunction = "(or " * join(["(= $x $call)" for x in xs], " ") * ")"

    io = IOBuffer()
    println(io, "(set-logic LIA)")
    println(io)
    println(io, "(synth-fun max$n (", join(["($x Int)" for x in xs], " "), ") Int")
    println(io, grammar_block(xs, Int[], tier))
    println(io, ")")
    println(io)
    for x in xs
        println(io, "(declare-var $x Int)")
    end
    println(io)
    if granularity == "conj"
        # Everything as a single constraint: the score can only ever be 0 or 1.
        println(io, "(constraint (and ", join(ge, " "), " ", witness_disjunction, "))")
    elseif granularity == "split"
        for g in ge
            println(io, "(constraint $g)")
        end
        println(io, "(constraint $witness_disjunction)")
    else  # witness
        for g in ge
            println(io, "(constraint $g)")
        end
        # Case split of the disjunction: if x_i dominates every input, the answer is x_i.
        # These N constraints are complete on their own; together with the inequalities
        # they give 2N graded constraints over the same function.
        for x in xs
            dom = join(["(>= $x $y)" for y in xs if y != x], " ")
            println(io, "(constraint (=> (and $dom) (= $call $x)))")
        end
    end
    println(io)
    println(io, "(check-synth)")
    return String(take!(io))
end

"""Reference solution: `ite(x1 > rest, x1, rest)` unfolded right to left."""
function max_reference(g::AbstractGrammar, n::Int)
    node = var(g, "x$n")
    for i in (n - 1):-1:1
        xi = var(g, "x$i")
        node = ite(g, greater(g, xi, node), xi, node)
    end
    return node
end

# ─────────────────────────────────────────────────────────────────────────────
# RuleNode construction helpers (look rules up by expression, never by index)
# ─────────────────────────────────────────────────────────────────────────────

function rule_index(g::AbstractGrammar, pred::Function, what::String)
    idx = findfirst(i -> pred(g.rules[i]), 1:length(g.rules))
    idx === nothing && error("grammar has no rule for $what")
    return idx
end

var(g, name) = RuleNode(rule_index(g, r -> r === Symbol(name), "variable $name"))
int_literal(g, v::Int) = RuleNode(rule_index(g, r -> r isa Integer && r == v, "literal $v"))

_binop(g, op) = rule_index(g, r -> r isa Expr && r.head === :call && r.args[1] === op, "operator $op")
less(g, a, b) = RuleNode(_binop(g, :<), [a, b])
greater(g, a, b) = RuleNode(_binop(g, :>), [a, b])
ite(g, c, t, e) = RuleNode(_binop(g, :ifelse), [c, t, e])

# ─────────────────────────────────────────────────────────────────────────────
# Emission and validation
# ─────────────────────────────────────────────────────────────────────────────

"""One generated benchmark: where it goes, its text, and how to build its reference."""
struct Benchmark
    path      :: String
    contents  :: String
    reference :: Function    # (grammar) -> RuleNode
end

function enumerate_benchmarks(families::Vector{String}, tiers::Vector{String})
    out = Benchmark[]
    for tier in tiers
        if "array_search" in families
            for n in 2:15
                push!(out, Benchmark(
                    joinpath(OUT_ROOT, "array_search_n", tier, "array_search$n.sl"),
                    array_search_spec(n, tier),
                    g -> array_search_reference(g, n)))
            end
        end
        if "piecewise" in families
            for n in 2:12
                push!(out, Benchmark(
                    joinpath(OUT_ROOT, "piecewise_n", tier, "piecewise$n.sl"),
                    piecewise_spec(n, tier),
                    g -> piecewise_reference(g, n)))
            end
        end
        if "max" in families
            for granularity in MAX_GRANULARITIES, n in 3:16
                push!(out, Benchmark(
                    joinpath(OUT_ROOT, "max_n", granularity, tier, "max$n.sl"),
                    max_spec(n, tier, granularity),
                    g -> max_reference(g, n)))
            end
        end
    end
    return out
end

function write_benchmarks(benches::Vector{Benchmark})
    for b in benches
        mkpath(dirname(b.path))
        open(b.path, "w") do f
            write(f, b.contents)
        end
    end
    println("wrote $(length(benches)) spec file(s)")
end

"""
    validate(benches) :: Bool

For each benchmark: parse it, build the grammar it declares, build the reference
solution as a RuleNode over that grammar, convert it to SMT and verify it against the
full spec. Returns true if every file passed.
"""
function validate(benches::Vector{Benchmark})
    CEX = CEGIS.CEXGeneration
    GB = CEGIS.GrammarBuilding

    failures = String[]
    for b in benches
        rel = relpath(b.path, OUT_ROOT)
        try
            spec = CEX.parse_spec_from_file(b.path)
            sf = spec.synth_funs[1]
            GB.has_sygus_grammar(sf) || error("no grammar body was parsed back")
            g = GB.build_grammar_from_synth_fun(sf)
            node = b.reference(g)
            exprs = Dict(sf.name => CEX.rulenode_to_smt2(node, g))
            v = CEX.verify_query(CEX.generate_query(spec, exprs))
            if v.status == :unsat
                println("  PASS  $rel  ($(length(spec.constraints)) constraints, $(length(g.rules)) rules)")
            else
                push!(failures, "$rel — reference solution not verified ($(v.status))")
                println("  FAIL  $rel  ($(v.status))")
            end
        catch e
            push!(failures, "$rel — $(sprint(showerror, e))")
            println("  FAIL  $rel  $(sprint(showerror, e))")
        end
    end
    if isempty(failures)
        println("\nvalidation: all $(length(benches)) file(s) PASS")
        return true
    end
    println("\nvalidation: $(length(failures)) of $(length(benches)) file(s) FAILED")
    for f in failures
        println("  - $f")
    end
    return false
end

# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

function main(args::Vector{String})
    families = ["array_search", "piecewise", "max"]
    tiers = ["d0"]
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--tier"
            tiers = split(args[i + 1], ","); i += 2
        elseif a == "--family"
            families = split(args[i + 1], ","); i += 2
        elseif a == "--validate"
            i += 1   # handled at load time by DO_VALIDATE
        else
            error("unknown argument $a")
        end
    end
    benches = enumerate_benchmarks(String.(families), String.(tiers))
    write_benchmarks(benches)
    if DO_VALIDATE
        println("\nvalidating (parse → grammar → reference solution → Z3):")
        validate(benches) || exit(1)
    end
end

abspath(PROGRAM_FILE) == @__FILE__ && main(copy(ARGS))
