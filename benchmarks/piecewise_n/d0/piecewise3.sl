(set-logic LIA)

(synth-fun piecewise ((x Int)) Int
  ((Start Int) (CondExpr Bool))
  ((Start Int (x 2 8 9 10 20 (ite CondExpr Start Start)))
   (CondExpr Bool ((< Start Start) (<= Start Start) (> Start Start) (>= Start Start))))
)

(declare-var x Int)

(constraint (=> (< x 10) (= (piecewise x) 8)))
(constraint (=> (and (>= x 10) (< x 20)) (= (piecewise x) 2)))
(constraint (=> (>= x 20) (= (piecewise x) 9)))

(check-synth)
