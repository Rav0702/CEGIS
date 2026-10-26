; above7.sl — a MULTI-ANSWER specification: any value strictly greater than all of 7 integers.
;
; Built to test incomplete tests (src/GeneticSearch/incomplete_tests.jl). At
; every input the spec accepts more than one output, so a counterexample's output
; cannot be demanded of later candidates: CDGP must keep the input only.
; Grammar: the CDGP-paper LIA grammar used by spec_files/paired/cdgp/*.sl.
; Known solution: maximum + 1, or 1 + the sum of max(v, 0) over the inputs.
; Part of the above_n family (n = 4..7): one independent constraint per input,
; used to test whether per-constraint counterexamples help more as n grows.

(set-logic LIA)

(synth-fun above7 ( (t Int) (u Int) (v Int) (w Int) (x Int) (y Int) (z Int) ) Int
    ((Start Int (t u v w x y z 0 1
                 (+ Start Start)
                 (- Start Start)
                 (ite StartBool Start Start)))
     (StartBool Bool ((and StartBool StartBool)
                      (or  StartBool StartBool)
                      (not StartBool)
                      (<=  Start Start)
                      (=   Start Start)
                      (>=  Start Start)))))

(declare-var t Int)
(declare-var u Int)
(declare-var v Int)
(declare-var w Int)
(declare-var x Int)
(declare-var y Int)
(declare-var z Int)

(constraint (> (above7 t u v w x y z) t))
(constraint (> (above7 t u v w x y z) u))
(constraint (> (above7 t u v w x y z) v))
(constraint (> (above7 t u v w x y z) w))
(constraint (> (above7 t u v w x y z) x))
(constraint (> (above7 t u v w x y z) y))
(constraint (> (above7 t u v w x y z) z))

(check-synth)
