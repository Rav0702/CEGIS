(set-logic LIA)
(set-option :model.completion true)

(declare-const x0 Int)
(declare-const x1 Int)
(declare-const k Int)

(define-fun findIdx ((x0 Int) (x1 Int) (k Int)) Int (ite (< k x0) 0 (ite (< k x1) 1 2)))

(declare-const out_findIdx Int)

; Spec constraints for findIdx (valid outputs: out_findIdx)
(assert (=> (and (< x0 x1) (< k x0)) (= out_findIdx 0)))
(assert (=> (and (< x0 x1) (>= k x0) (< k x1)) (= out_findIdx 1)))
(assert (=> (and (< x0 x1) (>= k x1)) (= out_findIdx 2)))

; Check if candidate violates any constraint
(assert (not
  (and
    (=> (and (< x0 x1) (< k x0)) (= (findIdx x0 x1 k) 0))
  (=> (and (< x0 x1) (>= k x0) (< k x1)) (= (findIdx x0 x1 k) 1))
  (=> (and (< x0 x1) (>= k x1)) (= (findIdx x0 x1 k) 2))
  )
))

(check-sat)

; Free variable values at counterexample
(get-value (x0 x1 k))

; Candidate output(s)
(get-value ((findIdx x0 x1 k)))

; Valid spec output(s) - what the spec says is correct
(get-value (out_findIdx))

