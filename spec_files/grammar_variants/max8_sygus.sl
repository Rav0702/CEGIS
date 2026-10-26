; max8_sygus.sl — max8_simple.sl's constraints with the SyGuS-COMP LIA grammar block of the
; competition's max_n benchmarks (as copied in spec_files/paired/cdgp/max4.sl): variables, 0, 1,
; + -, ite, and/or/not, <= = >=. The "official" grammar variant of max8 (2026-09-28).

(set-logic LIA)

(synth-fun max8 ((x0 Int) (x1 Int) (x2 Int) (x3 Int) (x4 Int) (x5 Int) (x6 Int) (x7 Int)) Int
    ((Start Int (x0 x1 x2 x3 x4 x5 x6 x7 0 1
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
(declare-var x7 Int)
(constraint (>= (max8 x0 x1 x2 x3 x4 x5 x6 x7) x0))
(constraint (>= (max8 x0 x1 x2 x3 x4 x5 x6 x7) x1))
(constraint (>= (max8 x0 x1 x2 x3 x4 x5 x6 x7) x2))
(constraint (>= (max8 x0 x1 x2 x3 x4 x5 x6 x7) x3))
(constraint (>= (max8 x0 x1 x2 x3 x4 x5 x6 x7) x4))
(constraint (>= (max8 x0 x1 x2 x3 x4 x5 x6 x7) x5))
(constraint (>= (max8 x0 x1 x2 x3 x4 x5 x6 x7) x6))
(constraint (>= (max8 x0 x1 x2 x3 x4 x5 x6 x7) x7))
(constraint (or (= x0 (max8 x0 x1 x2 x3 x4 x5 x6 x7))
            (or (= x1 (max8 x0 x1 x2 x3 x4 x5 x6 x7))
            (or (= x2 (max8 x0 x1 x2 x3 x4 x5 x6 x7))
            (or (= x3 (max8 x0 x1 x2 x3 x4 x5 x6 x7))
            (or (= x4 (max8 x0 x1 x2 x3 x4 x5 x6 x7))
            (or (= x5 (max8 x0 x1 x2 x3 x4 x5 x6 x7))
            (or (= x6 (max8 x0 x1 x2 x3 x4 x5 x6 x7))
                (= x7 (max8 x0 x1 x2 x3 x4 x5 x6 x7))))))))))

(check-synth)
