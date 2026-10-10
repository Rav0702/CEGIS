(set-logic LIA)

(synth-fun max8 ((x1 Int) (x2 Int) (x3 Int) (x4 Int) (x5 Int) (x6 Int) (x7 Int) (x8 Int)) Int
  ((Start Int) (CondExpr Bool))
  ((Start Int (x1 x2 x3 x4 x5 x6 x7 x8 (ite CondExpr Start Start)))
   (CondExpr Bool ((< Start Start) (<= Start Start) (> Start Start) (>= Start Start))))
)

(declare-var x1 Int)
(declare-var x2 Int)
(declare-var x3 Int)
(declare-var x4 Int)
(declare-var x5 Int)
(declare-var x6 Int)
(declare-var x7 Int)
(declare-var x8 Int)

(constraint (and (>= (max8 x1 x2 x3 x4 x5 x6 x7 x8) x1) (>= (max8 x1 x2 x3 x4 x5 x6 x7 x8) x2) (>= (max8 x1 x2 x3 x4 x5 x6 x7 x8) x3) (>= (max8 x1 x2 x3 x4 x5 x6 x7 x8) x4) (>= (max8 x1 x2 x3 x4 x5 x6 x7 x8) x5) (>= (max8 x1 x2 x3 x4 x5 x6 x7 x8) x6) (>= (max8 x1 x2 x3 x4 x5 x6 x7 x8) x7) (>= (max8 x1 x2 x3 x4 x5 x6 x7 x8) x8) (or (= x1 (max8 x1 x2 x3 x4 x5 x6 x7 x8)) (= x2 (max8 x1 x2 x3 x4 x5 x6 x7 x8)) (= x3 (max8 x1 x2 x3 x4 x5 x6 x7 x8)) (= x4 (max8 x1 x2 x3 x4 x5 x6 x7 x8)) (= x5 (max8 x1 x2 x3 x4 x5 x6 x7 x8)) (= x6 (max8 x1 x2 x3 x4 x5 x6 x7 x8)) (= x7 (max8 x1 x2 x3 x4 x5 x6 x7 x8)) (= x8 (max8 x1 x2 x3 x4 x5 x6 x7 x8)))))

(check-synth)
