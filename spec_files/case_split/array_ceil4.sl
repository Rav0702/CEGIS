; array_ceil4.sl — ceiling lookup in a sorted 4-element array: the smallest element above k,
; or k itself when k is above every element. A 5-region ORDERED CASE SPLIT with the same
; regions as array_search4 (k against x1 < x2 < x3 < x4), but each region returns a
; *variable* instead of a constant index — so a region's repair is `ite(k <= x_i, x_i, …)`.
; Written 2026-09-28 as a second member of the ordered case-split family (RQ1_RQ2_PLAN.md
; §7.9). Same CDGP-paper LIA grammar as the other case-split specs. As in array_search4,
; unsorted arrays and k equal to an element are don't-care inputs, so the spec is not
; single-answer there (counterexamples inside the regions still get unique outputs).
; Known solution: (ite (<= k x1) x1 (ite (<= k x2) x2 (ite (<= k x3) x3 (ite (<= k x4) x4 k))))

(set-logic LIA)

(synth-fun findCeil ( (x1 Int) (x2 Int) (x3 Int) (x4 Int) (k Int) ) Int
    ((Start Int (x1 x2 x3 x4 k 0 1
                 (+ Start Start)
                 (- Start Start)
                 (ite StartBool Start Start)))
     (StartBool Bool ((and StartBool StartBool)
                      (or  StartBool StartBool)
                      (not StartBool)
                      (<=  Start Start)
                      (=   Start Start)
                      (>=  Start Start)))))

(declare-var x1 Int)
(declare-var x2 Int)
(declare-var x3 Int)
(declare-var x4 Int)
(declare-var k Int)

(constraint (=> (and (< x1 x2) (and (< x2 x3) (< x3 x4))) (=> (< k x1) (= (findCeil x1 x2 x3 x4 k) x1))))
(constraint (=> (and (< x1 x2) (and (< x2 x3) (< x3 x4))) (=> (and (> k x1) (< k x2)) (= (findCeil x1 x2 x3 x4 k) x2))))
(constraint (=> (and (< x1 x2) (and (< x2 x3) (< x3 x4))) (=> (and (> k x2) (< k x3)) (= (findCeil x1 x2 x3 x4 k) x3))))
(constraint (=> (and (< x1 x2) (and (< x2 x3) (< x3 x4))) (=> (and (> k x3) (< k x4)) (= (findCeil x1 x2 x3 x4 k) x4))))
(constraint (=> (and (< x1 x2) (and (< x2 x3) (< x3 x4))) (=> (> k x4) (= (findCeil x1 x2 x3 x4 k) k))))

(check-synth)
