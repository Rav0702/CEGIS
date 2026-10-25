(set-logic LIA)

(synth-fun max4 ((x1 Int) (x2 Int) (x3 Int) (x4 Int)) Int
  ((Start Int) (CondExpr Bool))
  ((Start Int (x1 x2 x3 x4 (ite CondExpr Start Start)))
   (CondExpr Bool ((< Start Start) (> Start Start))))
)

(declare-var x1 Int)
(declare-var x2 Int)
(declare-var x3 Int)
(declare-var x4 Int)

(constraint (>= (max4 x1 x2 x3 x4) x1))
(constraint (>= (max4 x1 x2 x3 x4) x2))
(constraint (>= (max4 x1 x2 x3 x4) x3))
(constraint (>= (max4 x1 x2 x3 x4) x4))
(constraint (=> (and (>= x1 x2) (>= x1 x3) (>= x1 x4)) (= (max4 x1 x2 x3 x4) x1)))
(constraint (=> (and (>= x2 x1) (>= x2 x3) (>= x2 x4)) (= (max4 x1 x2 x3 x4) x2)))
(constraint (=> (and (>= x3 x1) (>= x3 x2) (>= x3 x4)) (= (max4 x1 x2 x3 x4) x3)))
(constraint (=> (and (>= x4 x1) (>= x4 x2) (>= x4 x3)) (= (max4 x1 x2 x3 x4) x4)))

(check-synth)
