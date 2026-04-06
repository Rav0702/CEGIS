(set-logic LIA)
(set-option :model.completion true)

(declare-const x Int)
(declare-const y Int)
(declare-const z Int)

(define-fun guard_fn ((x Int) (y Int) (z Int)) Int (ite (< y z) 1 0))

(declare-const out_guard_fn Int)

; Spec constraints for guard_fn (valid outputs: out_guard_fn)
(assert (=> (> x 0) (= out_guard_fn (+ x y))))
(assert (=> (<= x 0) (= out_guard_fn z)))

; Check if candidate violates any constraint
(assert (not
  (and
    (=> (> x 0) (= (guard_fn x y z) (+ x y)))
  (=> (<= x 0) (= (guard_fn x y z) z))
  )
))

(check-sat)

; Free variable values at counterexample
(get-value (x y z))

; Candidate output(s)
(get-value ((guard_fn x y z)))

; Valid spec output(s) - what the spec says is correct
(get-value (out_guard_fn))