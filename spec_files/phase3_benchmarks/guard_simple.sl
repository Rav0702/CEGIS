(set-logic LIA)

(synth-fun guard_fn ((x Int) (y Int) (z Int)) Int)

(declare-var x Int)
(declare-var y Int)
(declare-var z Int)

; If x > 0, then output must be (+ x y)
(constraint (=> (> x 0) (= (guard_fn x y z) (+ x y))))

; If x <= 0, then output must be z
(constraint (=> (<= x 0) (= (guard_fn x y z) z)))

(check-synth)
