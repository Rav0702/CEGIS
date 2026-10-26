; tiered3.sl — a harder PARTIAL-KNOWLEDGE case split (spec_knowledge/, E6a). Sibling of tiered.sl
; (which CDGP solves 20/20 in a median 5 s: too easy to calibrate).
;
; Six regions of (x, y, z), each with its own constraint:
;   A  x < 0                                   f = 0                answer written     -> recipe
;   B  x >= 0, y < 0                           f = x                answer written     -> recipe
;   C  x >= 0, y >= 0, z < 0                   f - y = x + x        guard only  (f = 2x + y)
;   D  x >= 0, y >= 0, z >= 0, x <= y          f + z = x + y + y    guard only  (f = x + 2y - z)
;   E  x >= 0, y >= 0, z >= 0, x > y, y <= z   f - z = x + x + x    guard only  (f = 3x + z)
;   F  x >= 0, y >= 0, z >= 0, x > y, y > z    f + x = y + z + z    guard only  (f = y + 2z - x)
; The syntactic compiler reads answers only where f(x) stands alone, so it gets recipes for A and B and only
; the region guards (premises) for C-F. Unique answer at every input. Known solution (about 50 grammar nodes):
;   ite(x<0, 0, ite(y<0, x, ite(z<0, (x+x)+y, ite(x<=y, ((x+y)+y)-z, ite(y<=z, ((x+x)+x)+z, ((y+z)+z)-x))))))
; Grammar: the SyGuS-COMP LIA grammar used by the other case-split specs.

(set-logic LIA)

(synth-fun tiered3 ( (x Int) (y Int) (z Int) ) Int
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

(constraint (=> (< x 0) (= (tiered3 x y z) 0)))
(constraint (=> (and (>= x 0) (< y 0)) (= (tiered3 x y z) x)))
(constraint (=> (and (>= x 0) (and (>= y 0) (< z 0))) (= (- (tiered3 x y z) y) (+ x x))))
(constraint (=> (and (>= x 0) (and (>= y 0) (and (>= z 0) (<= x y)))) (= (+ (tiered3 x y z) z) (+ x (+ y y)))))
(constraint (=> (and (>= x 0) (and (>= y 0) (and (>= z 0) (and (> x y) (<= y z))))) (= (- (tiered3 x y z) z) (+ x (+ x x)))))
(constraint (=> (and (>= x 0) (and (>= y 0) (and (>= z 0) (and (> x y) (> y z))))) (= (+ (tiered3 x y z) x) (+ y (+ z z)))))

(check-synth)
