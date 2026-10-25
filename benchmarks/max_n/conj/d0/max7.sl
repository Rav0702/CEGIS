(set-logic LIA)

(synth-fun max7 ((x1 Int) (x2 Int) (x3 Int) (x4 Int) (x5 Int) (x6 Int) (x7 Int)) Int
  ((Start Int) (CondExpr Bool))
  ((Start Int (x1 x2 x3 x4 x5 x6 x7 (ite CondExpr Start Start)))
   (CondExpr Bool ((< Start Start) (<= Start Start) (> Start Start) (>= Start Start))))
)

(declare-var x1 Int)
(declare-var x2 Int)
(declare-var x3 Int)
(declare-var x4 Int)
(declare-var x5 Int)
(declare-var x6 Int)
(declare-var x7 Int)

(constraint (and (>= (max7 x1 x2 x3 x4 x5 x6 x7) x1) (>= (max7 x1 x2 x3 x4 x5 x6 x7) x2) (>= (max7 x1 x2 x3 x4 x5 x6 x7) x3) (>= (max7 x1 x2 x3 x4 x5 x6 x7) x4) (>= (max7 x1 x2 x3 x4 x5 x6 x7) x5) (>= (max7 x1 x2 x3 x4 x5 x6 x7) x6) (>= (max7 x1 x2 x3 x4 x5 x6 x7) x7) (or (= x1 (max7 x1 x2 x3 x4 x5 x6 x7)) (= x2 (max7 x1 x2 x3 x4 x5 x6 x7)) (= x3 (max7 x1 x2 x3 x4 x5 x6 x7)) (= x4 (max7 x1 x2 x3 x4 x5 x6 x7)) (= x5 (max7 x1 x2 x3 x4 x5 x6 x7)) (= x6 (max7 x1 x2 x3 x4 x5 x6 x7)) (= x7 (max7 x1 x2 x3 x4 x5 x6 x7)))))

(check-synth)
