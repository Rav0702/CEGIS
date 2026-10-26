; isseries3.sl — do arguments form an arithmetic series?
; CDGP paper LIA suite (Bladek, Krawiec & Swan). Grammar follows the
; official SyGuS-COMP style used by max4.sl.

(set-logic LIA)

(synth-fun isseries3 ( (x Int) (y Int) (z Int) ) Bool
    ((StartBool Bool ((and StartBool StartBool)
                      (or  StartBool StartBool)
                      (not StartBool)
                      (<=  Start Start)
                      (=   Start Start)
                      (>=  Start Start)))
     (Start Int (x y z 0 1
                 (+ Start Start)
                 (- Start Start)
                 (ite StartBool Start Start)))))

(declare-var x Int)
(declare-var y Int)
(declare-var z Int)
(constraint (= (isseries3 x y z) (= (- y x) (- z y))))

(check-synth)
