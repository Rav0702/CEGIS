; range3_slack.sl — a MULTI-ANSWER specification: any value in [range, range+1], range = max - min of 3 integers.
;
; Built to test incomplete tests (src/GeneticSearch/incomplete_tests.jl). At
; every input the spec accepts more than one output, so a counterexample's output
; cannot be demanded of later candidates: CDGP must keep the input only.
; Grammar: the CDGP-paper LIA grammar used by spec_files/paired/cdgp/*.sl.
; Known solution: max - min (ite chains), or that + 1.

(set-logic LIA)

(synth-fun range3_slack ( (x Int) (y Int) (z Int) ) Int
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

(constraint (>= (range3_slack x y z) (- x y)))
(constraint (>= (range3_slack x y z) (- x z)))
(constraint (>= (range3_slack x y z) (- y x)))
(constraint (>= (range3_slack x y z) (- y z)))
(constraint (>= (range3_slack x y z) (- z x)))
(constraint (>= (range3_slack x y z) (- z y)))
(constraint (or (<= (range3_slack x y z) (+ (- x y) 1)) (<= (range3_slack x y z) (+ (- x z) 1)) (<= (range3_slack x y z) (+ (- y x) 1)) (<= (range3_slack x y z) (+ (- y z) 1)) (<= (range3_slack x y z) (+ (- z x) 1)) (<= (range3_slack x y z) (+ (- z y) 1))))

(check-synth)
