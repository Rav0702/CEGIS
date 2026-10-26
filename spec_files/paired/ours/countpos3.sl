; countpos3.sl — number of positive arguments
; CDGP paper LIA suite (Bladek, Krawiec & Swan). Grammar follows the
; official SyGuS-COMP style used by max4.sl.

(set-logic LIA)

(synth-fun countpos3 ( (x Int) (y Int) (z Int) ) Int
    ((Start Int (x y z 0 1
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
(constraint (= (countpos3 x y z) (+ (ite (> x 0) 1 0) (+ (ite (> y 0) 1 0) (ite (> z 0) 1 0)))))

(check-synth)
