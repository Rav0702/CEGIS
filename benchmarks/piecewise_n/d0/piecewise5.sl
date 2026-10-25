(set-logic LIA)

(synth-fun piecewise ((x Int)) Int
  ((Start Int) (CondExpr Bool))
  ((Start Int (x 2 3 8 9 10 20 30 40 (ite CondExpr Start Start)))
   (CondExpr Bool ((< Start Start) (<= Start Start) (> Start Start) (>= Start Start))))
)

(declare-var x Int)

(constraint (=> (< x 10) (= (piecewise x) 8)))
(constraint (=> (and (>= x 10) (< x 20)) (= (piecewise x) 2)))
(constraint (=> (and (>= x 20) (< x 30)) (= (piecewise x) 9)))
(constraint (=> (and (>= x 30) (< x 40)) (= (piecewise x) 3)))
(constraint (=> (>= x 40) (= (piecewise x) 10)))

(check-synth)
