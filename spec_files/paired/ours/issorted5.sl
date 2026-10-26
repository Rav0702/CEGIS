; issorted5.sl — are arguments in ascending order?
; CDGP paper LIA suite (Bladek, Krawiec & Swan). Grammar follows the
; official SyGuS-COMP style used by max4.sl.

(set-logic LIA)

(synth-fun issorted5 ( (x Int) (y Int) (z Int) (w Int) (v Int) ) Bool
    ((StartBool Bool ((and StartBool StartBool)
                      (or  StartBool StartBool)
                      (not StartBool)
                      (<=  Start Start)
                      (=   Start Start)
                      (>=  Start Start)))
     (Start Int (x y z w v 0 1
                 (+ Start Start)
                 (- Start Start)
                 (ite StartBool Start Start)))))

(declare-var x Int)
(declare-var y Int)
(declare-var z Int)
(declare-var w Int)
(declare-var v Int)
(constraint (= (issorted5 x y z w v) (and (<= x y) (and (<= y z) (and (<= z w) (<= w v))))))

(check-synth)
