(set-logic LIA)

(synth-fun findIdx ((x0 Int) (x1 Int) (k Int)) Int
  ((Start Int) (CondExpr Bool))
  ((Start Int (x0 x1 k 0 1 2 (ite CondExpr Start Start)))
   (CondExpr Bool ((< Start Start) (<= Start Start) (> Start Start) (>= Start Start))))
)

(declare-var x0 Int)
(declare-var x1 Int)
(declare-var k Int)

(constraint (=> (and (< x0 x1) (< k x0)) (= (findIdx x0 x1 k) 0)))
(constraint (=> (and (< x0 x1) (> k x0) (< k x1)) (= (findIdx x0 x1 k) 1)))
(constraint (=> (and (< x0 x1) (> k x1)) (= (findIdx x0 x1 k) 2)))

(check-synth)
