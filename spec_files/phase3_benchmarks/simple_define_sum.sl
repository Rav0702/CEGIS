(set-logic LIA)

(define-fun sum ((x Int) (y Int)) Int (+ x y))

(synth-fun f ((a Int) (b Int)) Int)

(declare-var x Int)
(declare-var y Int)

(constraint (= (f x y) (sum x y)))

(check-synth)
