(set-logic LIA)

(synth-fun guard_fn ((x Int) (y Int) (z Int)) Int)

(declare-var x Int)
(declare-var y Int)
(declare-var z Int)
(constraint (or (= (guard_fn x y z) (+ x y)) (= (guard_fn x y z) z)))

(check-synth)
