; sum4.sl — the sum of arguments
; CDGP paper LIA suite (Bladek, Krawiec & Swan). Grammar follows the
; official SyGuS-COMP style used by max4.sl.

(set-logic LIA)

(synth-fun sum4 ( (x Int) (y Int) (z Int) (w Int) ) Int
    ((Start Int (x y z w 0 1
                 (+ Start Start)
                 (- Start Start)
                 (ite StartBool Start Start)))
     (StartBool Bool ((and StartBool StartBool)
                      (or  StartBool StartBool)
                      (not StartBool)
                      (<=  Start Start)
                      (=   Start Start)
                      (>=  Start Start)))))

(declare-var x Int)
(declare-var y Int)
(declare-var z Int)
(declare-var w Int)
(constraint (= (sum4 x y z w) (+ x (+ y (+ z w)))))

(check-synth)
