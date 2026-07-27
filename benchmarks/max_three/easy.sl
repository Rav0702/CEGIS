;; Easy: Maximum of Three Numbers
;; Simple specification with basic constraints
;; Expected solution: nested ifelse to find max of three values

(set-logic LIA)

(synth-fun max3 ((x Int) (y Int) (z Int)) Int)

(declare-var x Int)
(declare-var y Int)
(declare-var z Int)

;; Result must be >= all inputs
(constraint (>= (max3 x y z) x))
(constraint (>= (max3 x y z) y))
(constraint (>= (max3 x y z) z))

;; Result is one of the inputs
(constraint (or (= x (max3 x y z))
                (or (= y (max3 x y z))
                    (= z (max3 x y z)))))

(check-synth)
