# Spec-enriched grammars (RQ1_RQ2_PLAN.md §7.14): add each answer recipe to the spec's own grammar as one
# production of the Int start symbol,
#
#     Start → (ite G_t t Start)          ("case rule": the recipe's guard, its answer, and the rest)
#
# and write a decoy grammar with the same number of productions of the same shape but scrambled content
# (every variable in a guard atom redrawn at random, two distinct per atom; answers shuffled across the
# productions, their variables redrawn too), as the placebo. Recipes are built in the spec's grammar, so every
# enriched program unfolds into a program of the original grammar: the search space gains shortcuts, not
# new programs. Output (SyGuS v1 grammar layout, as our other specs):
#
#     spec_files/enriched/<stem>_case.sl, spec_files/enriched/<stem>_decoy.sl
#
#     julia --project=. scripts/gen_enriched_grammars.jl [spec.sl ...]      (default: the E1 specs)
#
# Specs with guard-only regions (`spec_region_guards`, spec_knowledge/PARTIAL_KNOWLEDGE.md) also get
#
#     <stem>_caseguard.sl   recipes + one production (ite G_R Start Start) per region guard
#
# and their decoy takes that richer shape (scrambled case productions + scrambled guard productions). For specs
# without region guards the output is unchanged, so regenerating a file reproduces it byte for byte. Only the
# specs named on the command line are written: files used by stored runs are hashed in their manifests.
#
# E5a (spec_knowledge/E5A_DESIGN.md) adds three variants with k productions of the same shape, one per recipe guard,
# from their own RNG (so the files above are unchanged):
#
#     <stem>_guard.sl        (ite G Start Start)    the recipe's guard, both branches free ("where", not "what")
#     <stem>_inert.sl        (ite ⊥ Start Start)    ⊥ = G with one atom replaced by the negation of another:
#                                                   unsatisfiable (z3), so it never fires (cost-only placebo)
#     <stem>_guarddecoy.sl   (ite G̃ Start Start)    G̃ = a scrambled guard that fires where the spec has tests and
#                                                   matches no real region at any grain (wrong-content placebo);
#                                                   not written when no draw passes (countpos4.split)
using HerbCore, HerbGrammar, HerbConstraints, HerbInterpret, HerbSearch, HerbSpecification
include(joinpath(@__DIR__, "..", "src", "CEGIS.jl"))
using Random
const CG = CEGIS.CEXGeneration
const GS = CEGIS.GeneticSearch
const ROOT = normpath(joinpath(@__DIR__, ".."))

const SPECS = [
    "spec_files/multi_answer/above4.sl",
    "spec_files/case_split/array_search4.sl",
    "spec_files/case_split/countpos4_split.sl",
    "spec_files/grammar_variants/max6_sygus.sl",
]

"""Julia expression (from `rulenode2expr`) → SyGuS term."""
function sygus(e)::String
    e isa Bool && return string(e)
    e isa Integer && return e < 0 ? "(- $(abs(e)))" : string(e)
    e isa Symbol && return string(e)
    e.head === :&& && return "(and $(sygus(e.args[1])) $(sygus(e.args[2])))"
    e.head === :|| && return "(or $(sygus(e.args[1])) $(sygus(e.args[2])))"
    e.head === :call || error("unexpected term $e")
    op = get(Dict(:ifelse => "ite", :(==) => "=", :! => "not"), e.args[1], string(e.args[1]))
    return "($op " * join(sygus.(e.args[2:end]), " ") * ")"
end

"""Redraw every parameter occurrence; an atom's two operands are drawn distinct (no `v >= v`)."""
function scramble(e, params, rng)
    e isa Symbol && e in params && return rand(rng, params)
    e isa Expr || return e
    if e.head === :call && e.args[1] in (:>=, :<=, :>, :<, :(==)) && all(a -> a isa Symbol && a in params, e.args[2:3])
        a, b = randperm(rng, length(params))[1:2]
        return Expr(:call, e.args[1], params[a], params[b])
    end
    return Expr(e.head, (scramble(a, params, rng) for a in e.args)...)
end

_vars(e, params) = e isa Symbol ? (e in params ? Set([e]) : Set{Symbol}()) :
                   e isa Expr ? union(Set{Symbol}(), (_vars(a, params) for a in e.args)...) : Set{Symbol}()
_is_atom(e) = e isa Expr && e.head === :call && e.args[1] in (:>=, :<=, :>, :<, :(==))

"""
`scramble`, but no atom degenerates: an atom over two or more distinct variables keeps at least two after
scrambling (`z ≥ y + 1` may become `x ≥ z + 1`, never the always-false `z ≥ z + 1`). Used for the
region-guard decoys only, so the E1 decoy files, made with `scramble`, are reproduced unchanged.
"""
function scramble_nd(e, params, rng)
    if _is_atom(e) && length(_vars(e, params)) >= 2
        for _ in 1:100
            a = scramble(e, params, rng)
            length(_vars(a, params)) >= 2 && return a
        end
    end
    e isa Expr && !_is_atom(e) && return Expr(e.head, (scramble_nd(a, params, rng) for a in e.args)...)
    return scramble(e, params, rng)
end

"""Evaluate a guard (Julia expression over the parameters) at one input."""
function _holds(e, env)
    e isa Bool && return e
    e isa Integer && return e
    e isa Symbol && return env[e]
    e.head === :&& && return _holds(e.args[1], env) && _holds(e.args[2], env)
    e.head === :|| && return _holds(e.args[1], env) || _holds(e.args[2], env)
    op, a = e.args[1], [_holds(x, env) for x in e.args[2:end]]
    op === :! && return !a[1]
    op === :+ && return a[1] + a[2]
    op === :- && return length(a) == 1 ? -a[1] : a[1] - a[2]
    op === :(==) && return a[1] == a[2]
    return getfield(Base, op)(a[1], a[2])
end

"""
Region of a guard on a fixed point set: the full grid (each parameter in -5:5) for up to 3 parameters, a fixed
random sample of 20 000 points beyond (11^n grows too fast; the full grid hung the generator at n = 16).
"""
function _region(G, params)
    pts = length(params) <= 3 ? Iterators.product(ntuple(_ -> -5:5, length(params))...) :
          (let r = MersenneTwister(4242); [Tuple(rand(r, -5:5, length(params))) for _ in 1:20_000] end)
    return Set(i for (i, v) in enumerate(pts) if _holds(G, Dict(zip(params, v))))
end
_jaccard(a, b) = isempty(a ∪ b) ? 0.0 : length(a ∩ b) / length(a ∪ b)

"""
Region-guard decoy: `scramble_nd`, redrawn (fixed RNG, up to 500 tries) until the decoy's region is non-empty and
overlaps no real guard's region (recipes' and region guards') with Jaccard similarity above 0.5 on the grid —
a near-copy of a real region would carry real knowledge into the placebo. Returns (guard, max Jaccard).
"""
function region_decoy(G, real, params, rng)
    regs = [_region(R, params) for R in real]
    best = nothing
    for _ in 1:500
        d = scramble_nd(G, params, rng)
        dr = _region(d, params)
        isempty(dr) && continue
        j = maximum(_jaccard(dr, r) for r in regs)
        (best === nothing || j < best[2]) && (best = (d, j))
        j <= 0.5 && return (d, j)
    end
    return best
end

# ── E5a variants ─────────────────────────────────────────────────────────────

"""E5 inert atom: always false, built from a real atom's two sides (`d ≥ d + 1` with `d = l − r`), so it is distinct
for distinct (operator, sides)."""
function inert_atom(a)
    op, l, r = a.args
    d = Expr(:call, :-, l, r)
    d1 = Expr(:call, :+, d, 1)
    op === :>= && return Expr(:call, :>=, d, d1)
    op === :<= && return Expr(:call, :<=, d1, d)
    op === :(==) && return Expr(:call, :(==), d, d1)
    error("inert_atom: unexpected atom $a")
end

"""E5 inert term: the answer term with every constant 1 replaced by 0, so it equals 0 or a variable, both already
one-node productions: the same shape, no new value."""
_zero_ones(e) = e === 1 ? 0 : e isa Expr ? Expr(e.head, map(_zero_ones, e.args)...) : e

"""Comparison atoms of a guard, left to right."""
_atoms(e) = _is_atom(e) ? Any[e] : e isa Expr ? vcat(Any[], (_atoms(a) for a in e.args)...) : Any[]

"""Replace the `j`-th atom (left to right) of `e` by `new`."""
function _replace_atom(e, j, new)
    k = Ref(0)
    sub(x) = _is_atom(x) ? ((k[] += 1) == j ? new : x) : x isa Expr ? Expr(x.head, map(sub, x.args)...) : x
    return sub(e)
end

_is_pm1(x, op) = x isa Expr && x.head === :call && length(x.args) == 3 && x.args[1] === op && x.args[3] == 1

"""Integer negation of a `>=` / `<=` atom in the grammar's own operators: ¬(a ≥ b) = a ≤ b − 1, ¬(a ≥ b + 1) = a ≤ b."""
function _negate(a)
    op, l, r = a.args
    op === :>= && return _is_pm1(r, :+) ? Expr(:call, :<=, l, r.args[2]) : Expr(:call, :<=, l, Expr(:call, :-, r, 1))
    op === :<= && return _is_pm1(r, :-) ? Expr(:call, :>=, l, r.args[2]) : Expr(:call, :>=, l, Expr(:call, :+, r, 1))
    error("cannot negate atom $a")
end

"""z3 satisfiability of a conjunction of SyGuS terms over the (Int) parameters."""
function z3_sat(params, asserts...)
    q = "(set-logic LIA)\n" * join(("(declare-fun $p () Int)" for p in params), "\n") * "\n" *
        join(("(assert $a)" for a in asserts), "\n") * "\n(check-sat)\n"
    st = CG.verify_query(q).status
    st in (:sat, :unsat) || error("z3 returned $st on\n$q")
    return st === :sat
end

"""
Inert guards, one per recipe guard: the guard with atom j replaced by the negation of atom i, so the conjunction
holds nowhere (`(>= w x)` beside `(<= w (- x 1))`). Same atom count and shape as the real guard. The pair (i, j) is
the first, in a fixed order starting at (1, 2), that keeps the guard distinct from those already made (Herb drops
duplicate rules). Each is checked unsatisfiable by z3.
"""
function inert_guards(guards, params)
    made, used = Any[], Set{String}()
    for G in guards
        as = _atoms(G)
        pairs = [(i, j) for i in eachindex(as) for j in eachindex(as) if i != j]
        sort!(pairs; by = p -> (p != (1, 2), p))
        # Candidates in a fixed order; the first that is new and unsatisfiable (z3) is taken. For the E1–E5 specs the
        # first negated-atom candidate always qualifies, so their files are unchanged. The later candidates serve the
        # confirmatory specs: one atom replaced by E5's always-false form of it (d ≥ d + 1), for single-atom guards
        # (array_sum3_15) and guards sharing their atoms (countpos2); then every atom replaced so, which is false under
        # any and/or structure (conditional_sum_hard's disjunctive guard). Same atom count and shape throughout.
        tryto(f) = try f() catch; nothing end      # an equality atom has no `_negate` form (abs_value_easy)
        cands = filter(!isnothing, vcat(
            [tryto(() -> _replace_atom(G, p[2], _negate(as[p[1]]))) for p in pairs],
            [tryto(() -> _replace_atom(G, j, inert_atom(as[j]))) for j in eachindex(as)],
            [tryto(() -> foldl((e, j) -> _replace_atom(e, j, inert_atom(as[j])), eachindex(as); init = G))]))
        k = findfirst(c -> !(sygus(c) in used) && !z3_sat(params, sygus(c)), cands)
        k === nothing && error("no distinct unsatisfiable inert guard for $(sygus(G))")
        I = cands[k]
        push!(made, I); push!(used, sygus(I))
    end
    return made
end

"""
Points of the spec's care set: each parameter uniform in -5:5, a point kept when some recipe guard holds there
(fixed RNG). The recipes cover every input at which the spec fixes the answer; elsewhere (array_search4's unsorted
arrays) every output is accepted, so no counterexample, and no test, can arise there.
"""
function care_points(guards, params; n = 4000, tries = 3_000_000)
    r, pts = MersenneTwister(4243), Dict{Symbol,Int}[]
    for _ in 1:tries
        env = Dict(zip(params, rand(r, -5:5, length(params))))
        any(G -> _holds(G, env), guards) && push!(pts, env)
        length(pts) == n && break
    end
    return pts
end

_bits(G, pts) = BitVector([_holds(G, p) for p in pts])

"""
Scrambled-guard placebos, one per recipe guard: `scramble_nd` of the guard, redrawn (`rng`, up to `tries` per guard)
until, on the care points `pts`, the draw
- fires somewhere (otherwise it is one more inert production),
- overlaps no real region with Jaccard similarity above 0.5,
- lies inside no single real region (a correct sub-split: real knowledge at a finer grain),
- is not a union of real regions (real knowledge at a coarser grain),
- differs from every real guard and earlier placebo as text (Herb drops duplicate rules);
z3 then confirms the first, third and fourth exactly on the care set (the disjunction of the recipe guards).
Returns a vector of (guard, max Jaccard, purity, regions touched), purity = the largest share of its care points
inside one real region, or `nothing` if some guard has no passing draw.
"""
function guard_decoys(guards, params, pts, rng; tries = 2000)
    regs = [_bits(G, pts) for G in guards]
    care = "(or " * join(sygus.(guards), " ") * ")"
    used = Set(sygus.(guards))
    out = []
    for G in guards
        found = nothing
        for _ in 1:tries
            d = scramble_nd(G, params, rng)
            sd = sygus(d)
            sd in used && continue
            D = _bits(d, pts)
            nd = count(D)
            nd == 0 && continue
            j = maximum(count(D .& R) / count(D .| R) for R in regs)
            j <= 0.5 || continue
            purity = maximum(count(D .& R) for R in regs) / nd
            purity < 1 || continue
            inside = [count(R) > 0 && all(D .| .!R) for R in regs]          # R ⊆ D
            covered = reduce(.|, regs[inside]; init = falses(length(pts)))
            all(covered .| .!D) && continue                                  # D = union of the regions it contains
            # Exact: live on the care set, inside no region, not the union of the regions it contains.
            z3_sat(params, sd, care) || continue
            all(z3_sat(params, sd, care, "(not $(sygus(R)))") for R in guards) || continue
            contained = [sygus(R) for R in guards if !z3_sat(params, sygus(R), "(not $sd)")]
            z3_sat(params, sd, care, ("(not $c)" for c in contained)...) || continue
            found = (d, j, purity, count(R -> any(D .& R), regs))
            break
        end
        found === nothing && return nothing
        push!(out, found); push!(used, sygus(found[1]))
    end
    return out
end

"""Herb drops duplicate rules silently: check a written variant has exactly `k` more rules, `k` of them compound."""
function check_rule_count(file, g0, k)
    g = CEGIS.GrammarBuilding.build_grammar_from_sygus(CG.parse_spec_from_file(file))
    nc = count(i -> CG._is_compound_rule(g.rules[i], g), eachindex(g.rules))
    length(g.rules) == length(g0.rules) + k && nc == k + count(i -> CG._is_compound_rule(g0.rules[i], g0), eachindex(g0.rules)) ||
        error("$(basename(file)): $(length(g.rules)) rules ($nc compound), expected $(length(g0.rules)) + $k")
end

"""Text span of the `(synth-fun …)` form (paren matching, `;` comments skipped)."""
function synthfun_span(txt)
    i = findfirst("(synth-fun", txt).start
    depth, j = 0, i
    while true
        c = txt[j]
        if c == ';'
            j = findnext('\n', txt, j)
        elseif c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
            depth == 0 && return i:j
        end
        j = nextind(txt, j)
    end
end

function write_variant(path, sp, extra::Vector{String}, tag, note; extra_bool::Vector{String} = String[])
    sf = sp.synth_funs[1]
    start = findfirst(nt -> String(nt[2]) != "Bool", sf.grammar)
    bstart = findfirst(nt -> String(nt[2]) == "Bool", sf.grammar)
    nts = map(enumerate(sf.grammar)) do (k, nt)
        prods = [CG.sexp_to_str(p) for p in nt[3]]
        k == start && append!(prods, extra)
        k == bstart && append!(prods, extra_bool)
        "     ($(nt[1]) $(nt[2]) (" * join(prods, "\n" * " "^(length(String(nt[1])) + length(String(nt[2])) + 9)) * "))"
    end
    sig = join(("($p $s)" for (p, s) in sf.params), " ")
    block = "(synth-fun $(sf.name) ($sig) $(sf.sort)\n    (\n" * join(nts, "\n") * "))"
    txt = read(joinpath(ROOT, path), String)
    body = txt[1:prevind(txt, first(synthfun_span(txt)))] * block * txt[nextind(txt, last(synthfun_span(txt))):end]
    stem = replace(basename(path), ".sl" => "")
    out = joinpath(ROOT, "spec_files", "enriched", "$(stem)_$tag.sl")
    mkpath(dirname(out))
    head = "; $(stem)_$tag.sl — generated by scripts/gen_enriched_grammars.jl from $path.\n; $note\n\n"
    write(out, head * body)
    return out
end

for path in (isempty(ARGS) ? SPECS : ARGS)
    sp = CG.parse_spec_from_file(joinpath(ROOT, path))
    g = CEGIS.GrammarBuilding.build_grammar_from_sygus(sp)
    recipes = GS.spec_answer_recipes(sp, g)
    startname = String(sp.synth_funs[1].grammar[findfirst(nt -> String(nt[2]) != "Bool", sp.synth_funs[1].grammar)][1])
    params = [Symbol(p) for (p, _) in sp.synth_funs[1].params]
    guards = [rulenode2expr(r.guard, g) for r in recipes]
    terms = [rulenode2expr(r.term, g) for r in recipes]
    case = ["(ite $(sygus(G)) $(sygus(t)) $startname)" for (G, t) in zip(guards, terms)]
    rng = MersenneTwister(sum(codeunits(basename(path))))           # fixed per spec
    perm = length(terms) > 1 ? circshift(1:length(terms), rand(rng, 1:length(terms)-1)) : [1]
    decoy = ["(ite $(sygus(scramble(guards[k], params, rng))) $(sygus(scramble(terms[perm[k]], params, rng))) $startname)"
             for k in eachindex(guards)]
    same = count(in(case), decoy)
    regions = GS.spec_region_guards(sp, g)
    rguards = [rulenode2expr(r.guard, g) for r in regions]
    rcase = ["(ite $(sygus(G)) $startname $startname)" for G in rguards]
    rd = [region_decoy(G, vcat(guards, rguards), params, rng) for G in rguards]
    rdecoy = ["(ite $(sygus(d)) $startname $startname)" for (d, _) in rd]
    isempty(rd) || println("   region decoys: max Jaccard overlap with a real guard = ",
                           join((round(j, digits = 2) for (_, j) in rd), ", "))
    a = write_variant(path, sp, case, "case",
        "Spec-enriched grammar: one production (ite G_t t $startname) per answer recipe ($(length(case))).")
    if !isempty(regions)
        write_variant(path, sp, vcat(case, rcase), "caseguard",
            "Spec-enriched grammar: $(length(case)) recipe productions (ite G_t t $startname) and $(length(rcase)) " *
            "region-guard productions (ite G_R $startname $startname) for regions whose answer the spec does not write.")
        same += count(in(rcase), rdecoy)
    end
    b = write_variant(path, sp, vcat(decoy, rdecoy), "decoy",
        "Decoy grammar (placebo): $(length(decoy) + length(rdecoy)) productions of the same shape, scrambled content (seed fixed).")
    println(rpad(basename(path), 22), " recipes $(length(case))  region guards $(length(regions))  decoys equal to a real production: $same")
    println("   ", relpath(a, ROOT), "\n   ", relpath(b, ROOT))
    println("   e.g. case  ", case[1][1:min(end, 150)], "\n        decoy ", decoy[1][1:min(end, 150)])

    # E5a: recipe guards only (region-guard specs are outside E5a's family); own RNG, after the files above.
    k = length(guards)
    f = write_variant(path, sp, ["(ite $(sygus(G)) $startname $startname)" for G in guards], "guard",
        "E5a guard-only grammar: one production (ite G $startname $startname) per recipe guard ($k): where the " *
        "regions are, not their answers.")
    check_rule_count(f, g, k)
    ig = inert_guards(guards, params)
    f = write_variant(path, sp, ["(ite $(sygus(I)) $startname $startname)" for I in ig], "inert",
        "E5a inert placebo: $k productions (ite ⊥ $startname $startname), ⊥ a recipe guard with one atom replaced " *
        "by the negation of another (unsatisfiable, z3-checked): they never fire.")
    check_rule_count(f, g, k)
    pts = care_points(guards, params)
    gd = guard_decoys(guards, params, pts, MersenneTwister(5000 + sum(codeunits(basename(path)))))
    println("   E5a guard ", sygus(guards[1])[1:min(end, 120)], "\n       inert ", sygus(ig[1])[1:min(end, 120)])
    if gd === nothing
        println("   E5a: some recipe guard has no passing scrambled draw ($(length(pts)) care points); guarddecoy not written")
    else
        f = write_variant(path, sp, ["(ite $(sygus(d)) $startname $startname)" for (d, _) in gd], "guarddecoy",
            "E5a scrambled-guard placebo: $k productions (ite G̃ $startname $startname), G̃ a scrambled recipe guard " *
            "that fires where the spec has tests and matches no real region (Jaccard <= 0.5, inside none, not a " *
            "union; seed fixed).")
        check_rule_count(f, g, k)
        for (d, j, p, t) in gd
            println("       decoy ", rpad(sygus(d)[1:min(end, 100)], 100), "  Jaccard ", round(j, digits = 2),
                    "  purity ", round(p, digits = 2), "  regions ", t, "/", k, "  share ", round(count(_bits(d, pts)) / length(pts), digits = 3))
        end
    end
    println("   written: $(replace(basename(path), ".sl" => ""))_{guard,inert$(gd === nothing ? "" : ",guarddecoy")}.sl")

    # E5 (granularity): the recipes' atoms, or their whole guards, as productions of the Bool start symbol, and their
    # answer terms not already in the grammar as productions of the Int start symbol; each level with an inert
    # placebo of the same counts. No RNG, so everything above is unchanged.
    have = Set(CG.sexp_to_str(p) for p in sp.synth_funs[1].grammar[findfirst(nt -> String(nt[2]) != "Bool", sp.synth_funs[1].grammar)][3])
    nterms = unique(filter(t -> !(sygus(t) in have), terms))
    # A term without constants (array_sum3_15's `x1 + x2`) stays itself after zeroing its 1s: give it the
    # always-zero term `(- a a)` of the same size instead. Terms that zeroing already makes 0 or a parameter keep
    # that form, so existing files are unchanged.
    is_trivial(z) = any(v -> !z3_sat(params, "(distinct $(sygus(z)) $v)"), vcat(["0"], string.(params)))
    taken = Set{String}()
    function zero_of(t)
        z = _zero_ones(t)
        is_trivial(z) && return z
        t isa Expr && t.head === :call && length(t.args) == 3 || return z
        a, b = t.args[2], t.args[3]
        # Distinct same-size terms equal to 0 or a parameter, so no two collapse into one rule (range3: x - y, x - z).
        for c in (Expr(:call, :-, a, a), Expr(:call, :-, b, b), Expr(:call, :+, a, 0), Expr(:call, :+, b, 0),
                  Expr(:call, :-, a, 0), Expr(:call, :-, b, 0))
            sygus(c) in taken && continue
            push!(taken, sygus(c))
            return c
        end
        return z
    end
    iterms = [zero_of(t) for t in nterms]
    for t in iterms
        any(v -> !z3_sat(params, "(distinct $(sygus(t)) $v)"), vcat(["0"], string.(params))) ||
            error("inert term $(sygus(t)) is not equal to 0 or a parameter")
    end
    atoms = unique(sygus, vcat(Any[], (_atoms(G) for G in guards)...))
    iatoms = inert_atom.(atoms)
    allunique(sygus.(iatoms)) || error("inert atoms are not distinct")
    all(a -> z3_sat(params, sygus(a)), atoms) || error("a real atom is unsatisfiable")
    any(a -> z3_sat(params, sygus(a)), iatoms) && error("an inert atom is satisfiable")
    nt, na = length(nterms), length(atoms)
    for (tag, bools, ints, note) in (
            ("atoms", sygus.(atoms), sygus.(nterms),
             "E5 atoms: the recipe guards' $na distinct atoms as Bool productions and the $nt answer terms not already in the grammar as productions of the Int start symbol."),
            ("atomsinert", sygus.(iatoms), sygus.(iterms),
             "E5 inert placebo for atoms: $na always-false atoms (d ≥ d + 1 with d = left − right of a real atom) and $nt terms equal to 0 or a variable (each 1 of a real term replaced by 0)."),
            ("blocks", sygus.(guards), sygus.(nterms),
             "E5 blocks: the $k recipe guards as Bool productions and the $nt answer terms not already in the grammar as productions of the Int start symbol."),
            ("blocksinert", sygus.(ig), sygus.(iterms),
             "E5 inert placebo for blocks: E5a's $k unsatisfiable guards as Bool productions and $nt terms equal to 0 or a variable."))
        f = write_variant(path, sp, ints, tag, note; extra_bool = bools)
        check_rule_count(f, g, length(bools) + length(ints))
    end
    println("   E5: $na atoms, $k blocks, $nt new terms; written: $(replace(basename(path), ".sl" => ""))_{atoms,atomsinert,blocks,blocksinert}.sl")
    println("       atom ", sygus(atoms[1]), "  inert ", sygus(iatoms[1]), isempty(nterms) ? "" : "  term " * sygus(nterms[1]) * "  inert " * sygus(iterms[1]))
end
