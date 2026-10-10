(set-logic LIA)

(synth-fun max14 ((x1 Int) (x2 Int) (x3 Int) (x4 Int) (x5 Int) (x6 Int) (x7 Int) (x8 Int) (x9 Int) (x10 Int) (x11 Int) (x12 Int) (x13 Int) (x14 Int)) Int
  ((Start Int) (CondExpr Bool))
  ((Start Int (x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14 (ite CondExpr Start Start)))
   (CondExpr Bool ((< Start Start) (> Start Start))))
)

(declare-var x1 Int)
(declare-var x2 Int)
(declare-var x3 Int)
(declare-var x4 Int)
(declare-var x5 Int)
(declare-var x6 Int)
(declare-var x7 Int)
(declare-var x8 Int)
(declare-var x9 Int)
(declare-var x10 Int)
(declare-var x11 Int)
(declare-var x12 Int)
(declare-var x13 Int)
(declare-var x14 Int)

(constraint (and (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x1) (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x2) (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x3) (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x4) (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x5) (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x6) (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x7) (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x8) (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x9) (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x10) (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x11) (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x12) (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x13) (>= (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14) x14) (or (= x1 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)) (= x2 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)) (= x3 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)) (= x4 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)) (= x5 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)) (= x6 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)) (= x7 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)) (= x8 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)) (= x9 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)) (= x10 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)) (= x11 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)) (= x12 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)) (= x13 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)) (= x14 (max14 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14)))))

(check-synth)
