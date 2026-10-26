; max6_logic.sl — max6_simple.sl's constraints with an explicit grammar: the operators of the
; grammar generated for max6_simple (build_grammar_from_spec: variables, 0, 1, + - *, ite,
; < > <= >= =) PLUS and / or / not. Grammar ablation for the guided-patch operator
; (RQ1_RQ2_PLAN.md §7.9): with no and/or/not its guards are single comparisons and Bool sites
; cannot be patched, and it solved 0/66 on max6. The one other difference from the generated
; grammar is the missing Bool->Int coercion rule (Expr = BoolExpr), which a SyGuS grammar
; block cannot express and which a max program does not need.

(set-logic LIA)

(synth-fun max6 ((x0 Int) (x1 Int) (x2 Int) (x3 Int) (x4 Int) (x5 Int)) Int
    ((Start Int (x0 x1 x2 x3 x4 x5 0 1
                 (+ Start Start)
                 (- Start Start)
                 (* Start Start)
                 (ite StartBool Start Start)))
     (StartBool Bool ((and StartBool StartBool)
                      (or  StartBool StartBool)
                      (not StartBool)
                      (<   Start Start)
                      (>   Start Start)
                      (<=  Start Start)
                      (>=  Start Start)
                      (=   Start Start)))))

(declare-var x0 Int)
(declare-var x1 Int)
(declare-var x2 Int)
(declare-var x3 Int)
(declare-var x4 Int)
(declare-var x5 Int)
(constraint (>= (max6 x0 x1 x2 x3 x4 x5) x0))
(constraint (>= (max6 x0 x1 x2 x3 x4 x5) x1))
(constraint (>= (max6 x0 x1 x2 x3 x4 x5) x2))
(constraint (>= (max6 x0 x1 x2 x3 x4 x5) x3))
(constraint (>= (max6 x0 x1 x2 x3 x4 x5) x4))
(constraint (>= (max6 x0 x1 x2 x3 x4 x5) x5))
(constraint (or (= x0 (max6 x0 x1 x2 x3 x4 x5))
            (or (= x1 (max6 x0 x1 x2 x3 x4 x5))
            (or (= x2 (max6 x0 x1 x2 x3 x4 x5))
            (or (= x3 (max6 x0 x1 x2 x3 x4 x5))
            (or (= x4 (max6 x0 x1 x2 x3 x4 x5))
                (= x5 (max6 x0 x1 x2 x3 x4 x5))))))))

(check-synth)
