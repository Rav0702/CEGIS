(set-logic LIA)
(declare-const x Int)
(declare-const y Int)

(define-fun max2 ((x Int) (y Int)) Int y)

(declare-const out_max2 Int)

; Spec constraints for max2 (valid outputs: out_max2)
(assert (>= out_max2 x))
(assert (>= out_max2 y))
(assert (or (= x out_max2) (= y out_max2)))

; Check if candidate violates any constraint
(assert (not
  (and
    (>= (max2 x y) x)
  (>= (max2 x y) y)
  (or (= x (max2 x y)) (= y (max2 x y)))
  )
))

(check-sat)

; Free variable values at counterexample
(get-value (x y))

; Candidate output(s)
(get-value ((max2 x y)))

; Valid spec output(s) - what the spec says is correct
(get-value (out_max2))

