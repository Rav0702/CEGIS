; above4.sl — a MULTI-ANSWER specification: any value strictly greater than all of 4 integers.
;
; Built to test incomplete tests (src/GeneticSearch/incomplete_tests.jl). At
; every input the spec accepts more than one output, so a counterexample's output
; cannot be demanded of later candidates: CDGP must keep the input only.
; Grammar: the CDGP-paper LIA grammar used by spec_files/paired/cdgp/*.sl.
; Known solution: maximum + 1.

(set-logic LIA)

(synth-fun above4 ( (w Int) (x Int) (y Int) (z Int) ) Int
    ((Start Int (w x y z 0 1
                 (+ Start Start)
                 (- Start Start)
                 (ite StartBool Start Start)))
     (StartBool Bool ((and StartBool StartBool)
                      (or  StartBool StartBool)
                      (not StartBool)
                      (<=  Start Start)
                      (=   Start Start)
                      (>=  Start Start)))))

(declare-var w Int)
(declare-var x Int)
(declare-var y Int)
(declare-var z Int)

(constraint (> (above4 w x y z) w))
(constraint (> (above4 w x y z) x))
(constraint (> (above4 w x y z) y))
(constraint (> (above4 w x y z) z))

(check-synth)
