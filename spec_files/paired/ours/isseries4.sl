; isseries4.sl — do arguments form an arithmetic series?
; CDGP paper LIA suite (Bladek, Krawiec & Swan). Grammar follows the
; official SyGuS-COMP style used by max4.sl.

(set-logic LIA)

(synth-fun isseries4 ( (x Int) (y Int) (z Int) (w Int) ) Bool
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
(constraint (= (isseries4 x y z w) (and (= (- y x) (- z y)) (= (- z y) (- w z)))))

(check-synth)
