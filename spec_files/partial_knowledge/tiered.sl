; tiered.sl — a PARTIAL-KNOWLEDGE case split (spec_knowledge/, E6/E7 example).
;
; Four regions of the (x, y) plane, each with its own constraint:
;   A  x < 0                    f = 0                    answer written      -> recipe
;   B  x >= 0, y <= 0           f = x                    answer written      -> recipe
;   C  x >= 0, y > 0, x <= y    f - y = x + x            answer NOT written  -> guard only (f = 2x + y)
;   D  x >= 0, y > 0, x > y     f + y = x + x + x        answer NOT written  -> guard only (f = 3x - y)
; The syntactic compiler reads answers only where f(x) stands alone (f = t, f >= t, ...). In C and D, f sits
; inside arithmetic, so it gets each region's guard (the premise) but not its answer. Unique answer at every
; input. Known solution: ite(x < 0, 0, ite(y <= 0, x, ite(x <= y, (x + x) + y, ((x + x) + x) - y))).
; Grammar: the SyGuS-COMP LIA grammar used by the other case-split specs.

(set-logic LIA)

(synth-fun tiered ( (x Int) (y Int) ) Int
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

(constraint (=> (< x 0) (= (tiered x y) 0)))
(constraint (=> (and (>= x 0) (<= y 0)) (= (tiered x y) x)))
(constraint (=> (and (>= x 0) (and (> y 0) (<= x y))) (= (- (tiered x y) y) (+ x x))))
(constraint (=> (and (>= x 0) (and (> y 0) (> x y))) (= (+ (tiered x y) y) (+ x (+ x x)))))

(check-synth)
