CEGIS PRESENTATION  (copy-paste into Google Slides)

How to use: each block below is one slide. Copy the "Title:" line into the slide
title, and copy the bullet lines into the slide body. Lines shown indented are
monospace code or a diagram; set them to a monospace font (e.g. Roboto Mono).
Part I is vanilla CEGIS (no optimizations). Part II is the research agenda.


====================================================================
SLIDE 1
Title: CEGIS for Formal Specifications, and Where We Go Next
• Counterexample-Guided Inductive Synthesis from formal specifications
• Built in Julia on the Herb stack, with Z3 as the verification oracle
• Plan: the plain loop, the Z3 query, then four ways to push it further


====================================================================
SLIDE 2  (section divider)
Title: Part I, Vanilla CEGIS
• The plain loop, no optimizations


====================================================================
SLIDE 3
Title: The problem
• Input is a SyGuS formal spec, not I/O examples
• It gives a logic, a synth-fun signature, free variables, and a conjunction of constraint predicates
• Goal: a function correct for all inputs
• The spec is universally quantified, so we cannot just test examples, we need a verifier

Spec example (monospace):
    (synth-fun max2 ((x0 Int) (x1 Int)) Int)
    (constraint (>= (max2 x0 x1) x0))                          C1
    (constraint (>= (max2 x0 x1) x1))                          C2
    (constraint (or (= x0 (max2 x0 x1)) (= x1 (max2 x0 x1))))  C3


====================================================================
SLIDE 4
Title: The loop
• Start with no examples
• Synthesizer (Herb search): enumerate the cheapest candidate f that fits the current examples
• Verifier / Oracle (Z3): is there an input where f breaks the spec?
   unsat  to  verified, done
   sat    to  Z3 returns a counterexample input; add (input, output) as a new example, then loop
• Each counterexample eliminates a whole class of wrong programs

Visual: insert the diagram from cegis_loop.html (export as an image).
Text fallback (monospace):
    Synthesizer  --candidate f-->  Verifier (Z3)
       ^                              |
       |                       unsat  ->  DONE
       +--- new example <-- sat (counterexample input)


====================================================================
SLIDE 5
Title: The verification query
• Install the candidate as a real function, then ask if it breaks any constraint
• unsat means no input breaks it, so it is correct for all inputs
• sat means Z3 found a counterexample input (plus a valid output)
• Sound and universal: we prove correctness for all inputs, we do not sample

Query for max2 = (ite (< x0 x1) x1 x0)  (monospace):
    (define-fun max2 ((x0 Int)(x1 Int)) Int (ite (< x0 x1) x1 x0))
    (assert (not (and (>= (max2 x0 x1) x0)
                      (>= (max2 x0 x1) x1)
                      (or (= x0 (max2 x0 x1)) (= x1 (max2 x0 x1))))))
    (check-sat)


====================================================================
SLIDE 6
Title: Convergence
• Round by round: cheapest candidate fitting the examples, then verify
• Verifier either accepts it or returns one counterexample, which becomes the next example
• Terminates when search finds a candidate the oracle cannot break
• Bottleneck is the search, not the oracle: the synthesizer enumerates a huge space
• Part II uses the spec to prune or guide that search


====================================================================
SLIDE 7  (section divider)
Title: Part II, Using the spec during search
• Vanilla CEGIS uses the spec only at the end, for verification
• Thesis: the spec has structure we can exploit during search

Agenda:
• 4.2 E-graphs to HerbConstraints: syntactic pruning. Status: prototype
• 4.3 Predicate abstraction: semantic guidance for bottom-up. Status: concept
• 4.4 Partial-spec satisfaction: fitness and building blocks. Status: prototype, working
• 4.5 Spec-based equivalence: dedup in bottom-up. Status: concept


====================================================================
SLIDE 8
Title: 4.2 Structural pruning via E-graphs
• Derive equivalences from grammar and spec, compile them into HerbConstraints
• Search then never enumerates redundant candidates
• How: pattern enumeration, then equality saturation (Metatheory), then constraints
• Result on max2 and max3: 18 constraints auto-derived, depth-3 space cut by 92 percent and 90 percent
• Reality: Metatheory runs offline due to a dependency conflict, compile once and feed in


====================================================================
SLIDE 9
Title: 4.3 Predicate abstraction
• Decompose the spec into atomic predicates, for max2 these are f>=x, f>=y, f=x, f=y
• Each candidate gets a predicate signature
• Group bottom-up bank entries by signature: coarser than full behaviour, but spec-aligned
• Prune or merge abstraction-equivalent partials, prioritize unmet predicates
• Status: concept. Open: which predicates, and signature cost (cheap eval vs Z3)


====================================================================
SLIDE 10
Title: 4.4 Partial-spec satisfaction  (prototype, working)
• Score a candidate by how many of the N constraints it satisfies
• One Z3 query per constraint: assert (not Ci); unsat means satisfied for all inputs, sat gives a witness
• Building blocks: keep the smallest program per satisfied-subset
   x0 satisfies C1 and C3, x1 satisfies C2 and C3, so they are complementary
• Recombination works: seed the building blocks into a bottom-up iterator and run normal Z3 CEGIS

Data flow (monospace):
    partials (at least half satisfied)  ->  bottom-up bank  ->  combine  ->  full candidate  ->  Z3 verified

• Result on max3: success in 5 iterations, a Z3-verified solution assembled from partial programs
   ifelse(y>x, ifelse(z<y,y,z), ifelse(z>x,z,x))


====================================================================
SLIDE 11
Title: 4.5 Spec-based equivalence
• Today bottom-up banks dedup by behaviour on a finite I/O set, which is brittle
• Define equivalence from the spec itself
   candidates equal if indistinguishable under the spec plus accumulated counterexamples
   or full behavioural equivalence checked by Z3
• Payoff: stronger dedup, smaller bank, more reach per depth
• A benchmarking question: compare equivalence notions on bank size, time, success rate


====================================================================
SLIDE 12
Title: Summary
• Sound, working vanilla CEGIS: Herb enumerates, Z3 verifies for all inputs, counterexamples feed back
• The search is the bottleneck, not the oracle
• Two working prototypes: e-graph pruning (90 percent smaller space) and partial programs that recombine into a Z3-verified solution
• Two next experiments: predicate abstraction and spec-based equivalence
• Ask: which direction should we push to a full evaluation first
