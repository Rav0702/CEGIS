; recur3.sl — a RELATIONAL partial-knowledge case split (spec_knowledge/, E6b). Sibling of tiered3.sl.
;
; Four regions of (x, y, z):
;   A  x < 0                         f = 0                                         answer written -> recipe
;   B  x >= 0, y < 0                 f = x                                         answer written -> recipe
;   C  x >= 0, y >= 0, z >= 0        f(0, y, z) = y + z             (base plane)   -> recipe on x = 0 only
;                                    f(x+1, y, z) = f(x, y, z) + 2  (recurrence)   relational: answer 2x + y + z
;   D  x >= 0, y >= 0, z < 0         f(x, 0, z) = x - z             (base plane)   -> recipe on y = 0 only
;                                    f(x, y+1, z) = f(x, y, z) - 1  (recurrence)   relational: answer x - y - z
; Regions C and D are defined by a base case plus a recurrence: their closed forms are never written, and
; deriving them needs induction (not single-invocation: f is applied at x+1 / y+1). Recurrences stay inside
; their region. Known solution: ite(x<0, 0, ite(y<0, x, ite(z>=0, (x+x)+(y+z), (x-y)-z))).
; Grammar: the SyGuS-COMP LIA grammar used by the other case-split specs.

(set-logic LIA)

(synth-fun recur3 ( (x Int) (y Int) (z Int) ) Int
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

(constraint (=> (< x 0) (= (recur3 x y z) 0)))
(constraint (=> (and (>= x 0) (< y 0)) (= (recur3 x y z) x)))
(constraint (=> (and (= x 0) (and (>= y 0) (>= z 0))) (= (recur3 x y z) (+ y z))))
(constraint (=> (and (>= x 0) (and (>= y 0) (>= z 0))) (= (recur3 (+ x 1) y z) (+ (recur3 x y z) 2))))
(constraint (=> (and (= y 0) (and (>= x 0) (< z 0))) (= (recur3 x y z) (- x z))))
(constraint (=> (and (>= x 0) (and (>= y 0) (< z 0))) (= (recur3 x (+ y 1) z) (- (recur3 x y z) 1))))

(check-synth)
