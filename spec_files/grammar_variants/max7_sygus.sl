; max7_sygus.sl — max7_simple.sl's constraints with the SyGuS-COMP LIA grammar block of the
; competition's max_n benchmarks (as copied in spec_files/paired/cdgp/max4.sl): variables, 0, 1,
; + -, ite, and/or/not, <= = >=. The "official" grammar variant of max7 (2026-09-28).

(set-logic LIA)

(synth-fun max7 ((x0 Int) (x1 Int) (x2 Int) (x3 Int) (x4 Int) (x5 Int) (x6 Int)) Int
    ((Start Int (x0 x1 x2 x3 x4 x5 x6 0 1
                 (+ Start Start)
                 (- Start Start)
                 (ite StartBool Start Start)))
     (StartBool Bool ((and StartBool StartBool)
                      (or  StartBool StartBool)
                      (not StartBool)
                      (<=  Start Start)
                      (=   Start Start)
                      (>=  Start Start)))))

(declare-var x0 Int)
(declare-var x1 Int)
(declare-var x2 Int)
(declare-var x3 Int)
(declare-var x4 Int)
(declare-var x5 Int)
(declare-var x6 Int)
(constraint (>= (max7 x0 x1 x2 x3 x4 x5 x6) x0))
(constraint (>= (max7 x0 x1 x2 x3 x4 x5 x6) x1))
(constraint (>= (max7 x0 x1 x2 x3 x4 x5 x6) x2))
(constraint (>= (max7 x0 x1 x2 x3 x4 x5 x6) x3))
(constraint (>= (max7 x0 x1 x2 x3 x4 x5 x6) x4))
(constraint (>= (max7 x0 x1 x2 x3 x4 x5 x6) x5))
(constraint (>= (max7 x0 x1 x2 x3 x4 x5 x6) x6))
(constraint (or (= x0 (max7 x0 x1 x2 x3 x4 x5 x6))
            (or (= x1 (max7 x0 x1 x2 x3 x4 x5 x6))
            (or (= x2 (max7 x0 x1 x2 x3 x4 x5 x6))
            (or (= x3 (max7 x0 x1 x2 x3 x4 x5 x6))
            (or (= x4 (max7 x0 x1 x2 x3 x4 x5 x6))
            (or (= x5 (max7 x0 x1 x2 x3 x4 x5 x6))
            (= x6 (max7 x0 x1 x2 x3 x4 x5 x6)))))))))

(check-synth)
