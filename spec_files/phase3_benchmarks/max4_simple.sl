(set-logic LIA)

(synth-fun max4 ((x0 Int) (x1 Int) (x2 Int) (x3 Int)) Int)

(declare-var x0 Int)
(declare-var x1 Int)
(declare-var x2 Int)
(declare-var x3 Int)
(constraint (>= (max4 x0 x1 x2 x3) x0))
(constraint (>= (max4 x0 x1 x2 x3) x1))
(constraint (>= (max4 x0 x1 x2 x3) x2))
(constraint (>= (max4 x0 x1 x2 x3) x3))
(constraint (or (= x0 (max4 x0 x1 x2 x3))
            (or (= x1 (max4 x0 x1 x2 x3))
            (or (= x2 (max4 x0 x1 x2 x3))
                (= x3 (max4 x0 x1 x2 x3))))))

(check-synth)
