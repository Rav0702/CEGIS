;; Easy: Maximum of Four Numbers
;; Simple specification with basic constraints
;; Expected solution: nested ifelse to find max of four values

(set-logic LIA)

(synth-fun max4 ((x Int) (y Int) (z Int) (w Int)) Int)

(declare-var x Int)
(declare-var y Int)
(declare-var z Int)
(declare-var w Int)

;; Result must be >= all inputs
(constraint (>= (max4 x y z w) x))
(constraint (>= (max4 x y z w) y))
(constraint (>= (max4 x y z w) z))
(constraint (>= (max4 x y z w) w))

;; Result is one of the inputs
(constraint (or (= x (max4 x y z w))
                (or (= y (max4 x y z w))
                    (or (= z (max4 x y z w))
                        (= w (max4 x y z w))))))

(check-synth)
