(set-logic LIA)

(synth-fun sym_max ((x Int) (y Int)) Int)

(declare-var x Int)
(declare-var y Int)
(constraint (= (sym_max x y) (sym_max y x)))
(constraint (and (<= x (sym_max x y)) (<= y (sym_max x y))))

(check-synth)
