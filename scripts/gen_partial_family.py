#!/usr/bin/env python3
"""
Partial-knowledge spec family (spec_knowledge/, E6b). Each spec is a case split of m regions over n integer inputs,
written like spec_files/partial_knowledge/tiered3.sl:

  - regions form a decision list: region i holds when conditions c_1 .. c_{i-1} are false and c_i is true; the last
    region holds when all are false. Conditions are random atoms (x_j < 0, x_j <= x_k, ...);
  - k regions WRITE their answer:              (=> P_i (= f t_i))                   -> recipe
  - the other m - k give it only as a relation: (=> P_i (= (- f a_i) b_i))  with t_i = a_i + b_i  -> region guard only
    or, with --bounds W, only as an interval:  (=> P_i (and (>= (- f a_i) b_i) (<= (- f a_i) (+ b_i W))))  (multi-answer)
  - answers t_i are random linear terms over the inputs with about s grammar nodes (s = 5, 9, 13, ...).

Dials: m regions, k answered, s answer size, W answer slack. The compiler's knowledge shrinks as k drops; the leaf
search a decomposed synthesizer must do grows with s; W > 0 makes regions multi-answer (IO examples then carry an
arbitrary pick of the solver). Deterministic per --seed. Prints the known solution.

    bench/.venv/Scripts/python scripts/gen_partial_family.py --n 3 --m 6 --k 2 --s 9 --seed 1 [--bounds 0]
"""
import argparse, os, random

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
GRAMMAR_BOOL = """     (StartBool Bool ((and StartBool StartBool)
                      (or  StartBool StartBool)
                      (not StartBool)
                      (<=  Start Start)
                      (=   Start Start)
                      (>=  Start Start)))))"""


def term_nodes(t):
    return 1 if isinstance(t, str) else 1 + sum(term_nodes(a) for a in t[1:])


def show(t):
    return t if isinstance(t, str) else "(" + " ".join(show(a) for a in t) + ")"


def rand_term(rng, xs, s):
    """A linear term with L = (s + 1) // 2 unit atoms (a variable occurrence or the constant 1, each signed), at
    least two distinct variables, no cancelling pairs: written as a + / - chain it has 2L - 1 = s nodes and no
    shorter equivalent in this grammar (constants are only 0 and 1). Returns (atoms, coefficient dict)."""
    L = max(3, (s + 1) // 2)
    while True:
        coef = {x: 0 for x in xs + ["1"]}
        for _ in range(L):
            coef[rng.choice(xs + ["1"])] += 1
        for x in coef:                                   # flip whole coefficients' signs (never a cancellation)
            if coef[x] and rng.random() < 0.3:
                coef[x] = -coef[x]
        if sum(1 for x in xs if coef[x]) >= 2 and any(c > 0 for c in coef.values()):
            return coef


def chain(atoms):
    """Signed atoms [(sign, name), ...], positives first, as a + / - chain. All-negative lists start from 0
    (fixed 2026-10-03: the first atom's sign was dropped, so a relation's right-hand side could flip a sign)."""
    atoms = sorted(atoms, key=lambda a: -a[0])
    if atoms[0][0] < 0:
        t = ["-", "0", atoms[0][1]]
    else:
        t = atoms[0][1]
    for sg, x in atoms[1:]:
        t = ["+" if sg > 0 else "-", t, x]
    return t


def atoms_of(coef):
    return [(1 if c > 0 else -1, x) for x, c in coef.items() for _ in range(abs(c))]


def term_of(coef):
    return chain(atoms_of(coef))


def split(rng, coef):
    """t = a + b, both non-empty and neither equal to t: the relation never writes the answer verbatim."""
    at = atoms_of(coef)
    rng.shuffle(at)
    pos = [a for a in at if a[0] > 0]
    first = pos[0]
    rest = [a for a in at if a is not first]
    a, b = [first], rest
    if len(b) > 1:                                       # move a random share of b into a
        for x in list(b[: len(b) // 2]):
            if any(y[0] > 0 for y in b if y is not x) or x[0] > 0 and sum(1 for y in b if y[0] > 0) > 1:
                a.append(x); b.remove(x)
    return chain(a), (chain(b) if b else "0")


def evalc(c, env):
    op, l, r = c
    lv, rv = env[l], (0 if r == "0" else env[r])
    return {"<": lv < rv, ">=": lv >= rv, "<=": lv <= rv, ">": lv > rv}[op]


def region_sizes(conds, xs, lo=-4, hi=4):
    """Share of points (each input in lo..hi) in each decision-list region: the full grid for up to 4 inputs,
    a fixed random sample of 20 000 points beyond (9^n grows too fast)."""
    import itertools
    cnt = [0] * (len(conds) + 1)
    if len(xs) <= 4:
        pts = list(itertools.product(range(lo, hi + 1), repeat=len(xs)))
    else:
        r = random.Random(12345)
        pts = [tuple(r.randint(lo, hi) for _ in xs) for _ in range(20000)]
    for v in pts:
        env = dict(zip(xs, v))
        i = next((j for j, c in enumerate(conds) if evalc(c, env)), len(conds))
        cnt[i] += 1
    return [c / len(pts) for c in cnt]


def rand_cond(rng, xs):
    a = rng.choice(xs)
    if rng.random() < 0.5:
        return [rng.choice(["<", ">="]), a, "0"]
    b = rng.choice([x for x in xs if x != a])
    return [rng.choice(["<=", ">"]), a, b]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=3)
    ap.add_argument("--m", type=int, default=6)
    ap.add_argument("--k", type=int, default=2)
    ap.add_argument("--s", type=int, default=9)
    ap.add_argument("--bounds", type=int, default=0, help="slack W > 0: relation regions give an interval")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rng = random.Random(1000 * a.seed + 7 * a.s + a.m)
    xs = ["x", "y", "z", "w", "v"][: a.n] if a.n <= 5 else [f"x{i}" for i in range(1, a.n + 1)]
    while True:                                      # every region covers >= 3% of the grid (no empty region)
        conds = []
        while len(conds) < a.m - 1:
            c = rand_cond(rng, xs)
            if show(c) not in {show(d) for d in conds}:
                conds.append(c)
        sizes = region_sizes(conds, xs)
        if min(sizes) >= 0.03:
            break
    coefs = [rand_term(rng, xs, a.s) for _ in range(a.m)]
    answers = [term_of(c) for c in coefs]
    answered = set(rng.sample(range(a.m), a.k))
    fname = "pk"
    app = f"({fname} {' '.join(xs)})"
    cons, sol = [], show(answers[-1])
    for i in reversed(range(a.m)):
        prem = [["not", conds[j]] for j in range(i)] + ([conds[i]] if i < a.m - 1 else [])
        P = prem[0] if len(prem) == 1 else (["and"] + prem if prem else "true")
        t = answers[i]
        if i in answered:
            body = f"(= {app} {show(t)})"
        elif a.bounds > 0:
            # interval [t, t + W], with f inside arithmetic so the bounds do not expose the answer terms
            lhs, rhs = split(rng, coefs[i])
            hi = rhs if a.bounds == 0 else f"(+ {show(rhs)} {a.bounds})" if rhs != "0" else str(a.bounds)
            body = f"(and (>= (- {app} {show(lhs)}) {show(rhs)}) (<= (- {app} {show(lhs)}) {hi}))"
        else:
            lhs, rhs = split(rng, coefs[i])
            body = f"(= (- {app} {show(lhs)}) {show(rhs)})"
        cons.append(f"(constraint (=> {show(P)} {body}))" if P != "true" else f"(constraint {body})")
        if i < a.m - 1:
            sol = f"(ite {show(conds[i])} {show(t)} {sol})"
    cons.reverse()
    name = f"pk_n{a.n}_m{a.m}_k{a.k}_s{a.s}" + (f"_w{a.bounds}" if a.bounds else "") + f"_seed{a.seed}"
    sig = " ".join(f"({x} Int)" for x in xs)
    text = (f"; {name}.sl — generated by scripts/gen_partial_family.py (spec_knowledge/, E6b).\n"
            f"; {a.m} regions over ({', '.join(xs)}); {a.k} write their answer (recipes), {a.m - a.k} give it only "
            + ("as an interval of width " + str(a.bounds) if a.bounds else "as a relation (guard-only)")
            + f"; answers ~{a.s} nodes.\n; Known solution: {sol}\n\n"
            f"(set-logic LIA)\n\n(synth-fun {fname} ( {sig} ) Int\n"
            f"    ((Start Int ({' '.join(xs)} 0 1\n                 (+ Start Start)\n                 (- Start Start)\n"
            f"                 (ite StartBool Start Start)))\n{GRAMMAR_BOOL}\n\n"
            + "".join(f"(declare-var {x} Int)\n" for x in xs) + "\n" + "\n".join(cons) + "\n\n(check-synth)\n")
    out = os.path.join(ROOT, "spec_files", "partial_knowledge", "family", name + ".sl")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "w", encoding="utf-8").write(text)
    print(os.path.relpath(out, ROOT))
    print("solution:", sol)
    print("region shares:", " ".join(f"{x:.2f}" for x in sizes), " answered:", sorted(answered),
          " answer nodes:", [term_nodes(t) for t in answers])


if __name__ == "__main__":
    main()
