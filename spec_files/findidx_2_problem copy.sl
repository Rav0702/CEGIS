(set-logic LIA)

(synth-fun findIdx ((x0 Int) (x1 Int) (x2 Int) (x3 Int) (x4 Int) (k Int)) Int )

(declare-var x0 Int)
(declare-var x1 Int)
(declare-var x2 Int)
(declare-var x3 Int)
(declare-var x4 Int)
(declare-var k Int)

(constraint (=> (and (< x0 x1) (< x1 x2) (< x2 x3) (< x3 x4) (< k x0)) (= (findIdx x0 x1 x2 x3 x4 k) 0)))

(constraint (=> (and (< x0 x1) (< x1 x2) (< x2 x3) (< x3 x4) (> k x0) (< k x1)) (= (findIdx x0 x1 x2 x3 x4 k) 1)))

(constraint (=> (and (< x0 x1) (< x1 x2) (< x2 x3) (< x3 x4) (> k x1) (< k x2)) (= (findIdx x0 x1 x2 x3 x4 k) 2)))

(constraint (=> (and (< x0 x1) (< x1 x2) (< x2 x3) (< x3 x4) (> k x2) (< k x3)) (= (findIdx x0 x1 x2 x3 x4 k) 3)))

(constraint (=> (and (< x0 x1) (< x1 x2) (< x2 x3) (< x3 x4) (> k x3) (< k x4)) (= (findIdx x0 x1 x2 x3 x4 k) 4)))

(constraint (=> (and (< x0 x1) (< x1 x2) (< x2 x3) (< x3 x4) (> k x4)) (= (findIdx x0 x1 x2 x3 x4 k) 5)))

(check-synth)
