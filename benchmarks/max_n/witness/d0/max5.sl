(set-logic LIA)

(synth-fun max5 ((x1 Int) (x2 Int) (x3 Int) (x4 Int) (x5 Int)) Int
  ((Start Int) (CondExpr Bool))
  ((Start Int (x1 x2 x3 x4 x5 (ite CondExpr Start Start)))
   (CondExpr Bool ((< Start Start) (<= Start Start) (> Start Start) (>= Start Start))))
)

(declare-var x1 Int)
(declare-var x2 Int)
(declare-var x3 Int)
(declare-var x4 Int)
(declare-var x5 Int)

(constraint (>= (max5 x1 x2 x3 x4 x5) x1))
(constraint (>= (max5 x1 x2 x3 x4 x5) x2))
(constraint (>= (max5 x1 x2 x3 x4 x5) x3))
(constraint (>= (max5 x1 x2 x3 x4 x5) x4))
(constraint (>= (max5 x1 x2 x3 x4 x5) x5))
(constraint (=> (and (>= x1 x2) (>= x1 x3) (>= x1 x4) (>= x1 x5)) (= (max5 x1 x2 x3 x4 x5) x1)))
(constraint (=> (and (>= x2 x1) (>= x2 x3) (>= x2 x4) (>= x2 x5)) (= (max5 x1 x2 x3 x4 x5) x2)))
(constraint (=> (and (>= x3 x1) (>= x3 x2) (>= x3 x4) (>= x3 x5)) (= (max5 x1 x2 x3 x4 x5) x3)))
(constraint (=> (and (>= x4 x1) (>= x4 x2) (>= x4 x3) (>= x4 x5)) (= (max5 x1 x2 x3 x4 x5) x4)))
(constraint (=> (and (>= x5 x1) (>= x5 x2) (>= x5 x3) (>= x5 x4)) (= (max5 x1 x2 x3 x4 x5) x5)))

(check-synth)
