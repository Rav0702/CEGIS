; avoid2.sl — a MULTI-ANSWER specification: a value in {0, 1, 2} different from both x and y.
;
; Built to test incomplete tests (src/GeneticSearch/incomplete_tests.jl). At
; most inputs (every input where x, y do not cover two of 0..2) the spec accepts more than one output, so a counterexample's output
; cannot be demanded of later candidates: CDGP must keep the input only.
; Grammar: the CDGP-paper LIA grammar used by spec_files/paired/cdgp/*.sl.
; Known solution: (ite (or (= x 0) (= y 0)) (ite (or (= x 1) (= y 1)) (+ 1 1) 1) 0).
; Mixed: at (0,1) the only valid output is 2, so some counterexamples still
; complete into sound complete tests — this spec exercises both kinds.

(set-logic LIA)

(synth-fun avoid2 ( (x Int) (y Int) ) Int
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

(constraint (>= (avoid2 x y) 0))
(constraint (<= (avoid2 x y) 2))
(constraint (distinct (avoid2 x y) x))
(constraint (distinct (avoid2 x y) y))

(check-synth)
