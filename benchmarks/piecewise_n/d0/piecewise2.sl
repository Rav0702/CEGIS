(set-logic LIA)

(synth-fun piecewise ((x Int)) Int
  ((Start Int) (CondExpr Bool))
  ((Start Int (x 2 8 10 (ite CondExpr Start Start)))
   (CondExpr Bool ((< Start Start) (<= Start Start) (> Start Start) (>= Start Start))))
)

(declare-var x Int)

(constraint (=> (< x 10) (= (piecewise x) 8)))
(constraint (=> (>= x 10) (= (piecewise x) 2)))

(check-synth)
