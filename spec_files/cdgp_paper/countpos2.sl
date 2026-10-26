; countpos2.sl — number of positive arguments
; CDGP paper LIA suite (Bladek, Krawiec & Swan). Grammar follows the
; official SyGuS-COMP style used by max4.sl.

(set-logic LIA)

(synth-fun countpos2 ( (x Int) (y Int) ) Int
    ((Start Int (x y 0 1
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
(constraint (= (countpos2 x y) (+ (ite (> x 0) 1 0) (ite (> y 0) 1 0))))

(check-synth)
