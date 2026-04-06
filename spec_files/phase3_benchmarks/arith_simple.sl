(set-logic LIA)

(synth-fun arith ((x Int) (y Int)) Int)

(declare-var x Int)
(declare-var y Int)
(constraint (= (arith x y) (+ (* 2 x) y)))

(check-synth)
