(set-logic LIA)
(declare-const x1 Int)
(declare-const x2 Int)
(declare-const x3 Int)

(define-fun fnd_sum ((y1 Int) (y2 Int) (y3 Int)) Int (+ y1 1))

(assert (and
  (=> (> (+ x1 x2) 15) (= (fnd_sum x1 x2 x3) (+ x1 x2)))
  (=> (and (<= (+ x1 x2) 15) (> (+ x2 x3) 15)) (= (fnd_sum x1 x2 x3) (+ x2 x3)))
  (=> (and (<= (+ x1 x2) 15) (<= (+ x2 x3) 15)) (= (fnd_sum x1 x2 x3) 0))
))

(check-sat)

; free-variable assignments
(get-value (x1 x2 x3))

; synthesised function value(s) at the counterexample point
(get-value ((fnd_sum x1 x2 x3)))
