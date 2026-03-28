(set-logic LIA)
(declare-const x0 Int)
(declare-const x1 Int)
(declare-const k Int)

(define-fun findIdx ((x0 Int) (x1 Int) (k Int)) Int (ite (< k x0) 0 (ite (< k x1) 1 2)))

(define-fun findIdx_spec ((x0 Int) (x1 Int) (k Int)) Int (ite (and (< x0 x1) (< k x0)) 0 (ite (and (< x0 x1) (>= k x0) (< k x1)) 1 (ite (and (< x0 x1) (>= k x1)) 2 0))))

(assert (not
  (and
    (=> (and (< x0 x1) (< k x0)) (= (findIdx x0 x1 k) 0))
  (=> (and (< x0 x1) (>= k x0) (< k x1)) (= (findIdx x0 x1 k) 1))
  (=> (and (< x0 x1) (>= k x1)) (= (findIdx x0 x1 k) 2))
  )
))

(check-sat)

; free-variable assignments
(get-value (x0 x1 k))

; candidate function value(s) at the counterexample point
(get-value ((findIdx x0 x1 k)))

; expected output from spec
(get-value ((findIdx_spec x0 x1 k)))
