(set-logic LIA)

(synth-fun max2 ((x0 Int) (x1 Int)) Int)

(declare-var x0 Int)
(declare-var x1 Int)
(constraint (>= (max2 x0 x1) x0))
(constraint (>= (max2 x0 x1) x1))
(constraint (or (= x0 (max2 x0 x1)) (= x1 (max2 x0 x1))))

(check-synth)
