; issorted4.sl — are arguments in ascending order?
; CDGP paper LIA suite (Bladek, Krawiec & Swan). Grammar follows the
; official SyGuS-COMP style used by max4.sl.

(set-logic LIA)

(synth-fun issorted4 ( (x Int) (y Int) (z Int) (w Int) ) Bool
    ((StartBool Bool ((and StartBool StartBool)
                      (or  StartBool StartBool)
                      (not StartBool)
                      (<=  Start Start)
                      (=   Start Start)
                      (>=  Start Start)))
     (Start Int (x y z w 0 1
                 (+ Start Start)
                 (- Start Start)
                 (ite StartBool Start Start)))))

(declare-var x Int)
(declare-var y Int)
(declare-var z Int)
(declare-var w Int)
(constraint (= (issorted4 x y z w) (and (<= x y) (and (<= y z) (<= z w)))))

(check-synth)
