#!/usr/bin/env julia
"""
saturate.jl — Equality-saturation backend for e-graph–derived constraint generation.

This script lives in its own Julia environment (tools/egraph_gen) because
Metatheory.jl pins DataStructures 0.18 while HerbSearch requires 0.19, so the
two packages cannot coexist in one environment. CEGIS invokes this script as a
subprocess; the protocol is deliberately trivial (plain term strings) so the
two environments only share standard Julia syntax.

Usage:
    julia --project=tools/egraph_gen tools/egraph_gen/saturate.jl <terms-file> [theory]

Input:  <terms-file> contains one Julia expression per line (e.g. `a + 0`).
Output: one e-class id per input term, in input order, on stdout.
        Two terms received the same id  ⟺  the e-graph proved them equivalent
        under the selected theory (modulo saturation limits).

Theories: "lia" (default) — linear integer arithmetic with comparisons & ifelse.
"""

using Metatheory

# Algebraic identities for LIA-style grammars (integers, comparisons, ifelse).
# `-->` is a directed rewrite, `==` is bidirectional. Saturation is bounded by
# SaturationParams, so non-terminating rule sets (commutativity, associativity)
# are safe: incomplete saturation only *misses* equivalences, it never reports
# false ones — so the derived constraints stay sound.
const LIA_THEORY = @theory a b c p begin
    # identity / absorbing elements
    a + 0 --> a
    0 + a --> a
    a - 0 --> a
    a - a --> 0
    a * 1 --> a
    1 * a --> a
    a * 0 --> 0
    0 * a --> 0
    # commutativity / associativity
    a + b == b + a
    a * b == b * a
    (a + b) + c == a + (b + c)
    a + a == 2 * a
    # comparison mirror symmetries
    (a < b) == (b > a)
    (a <= b) == (b >= a)
    (a == b) == (b == a)
    # reflexive comparisons collapse to boolean literals
    (a < a) --> false
    (a > a) --> false
    (a <= a) --> true
    (a >= a) --> true
    (a == a) --> true
    # conditionals
    ifelse(p, a, a) --> a
    ifelse(true, a, b) --> a
    ifelse(false, a, b) --> b
end

const THEORIES = Dict("lia" => LIA_THEORY)

function main()
    if isempty(ARGS)
        error("usage: saturate.jl <terms-file> [theory]")
    end
    theory_name = length(ARGS) >= 2 ? ARGS[2] : "lia"
    haskey(THEORIES, theory_name) || error("unknown theory: $theory_name")
    theory = THEORIES[theory_name]

    lines = filter(!isempty, strip.(readlines(ARGS[1])))
    terms = [Meta.parse(String(l)) for l in lines]

    g = EGraph()
    ids = [addexpr!(g, t) for t in terms]
    saturate!(g, theory, SaturationParams(timeout=12))

    for id in ids
        println(find(g, id))
    end
end

main()
