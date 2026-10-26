#!/usr/bin/env python3
"""
cvc5 on our benchmark specs: time, solution size, and an independent Z3 check of every solution.

    bench/.venv/Scripts/python scripts/cvc5_compare.py --tlimit 60 --modes default,si-all max6 above4 ...
    (a name from SPECS below, or a path to an .sl file)

- Our specs write grammars in the SyGuS v1 layout `((Start Int (...)) ...)`; cvc5 only reads v2, which
  also needs the non-terminal predeclaration `((Start Int) ...)`. The converter adds it (same grammar)
  and writes the copy to results/cvc5/specs/.
- Modes: `default` (cvc5's own defaults: enumerative CEGIS; single-invocation off), `si-use`
  (single-invocation only when the grammar is not restrictive), `si-all` (single invocation always,
  solution reconstructed into the grammar), `unif-pi` (piecewise-independent unification: decision-tree
  learning over enumerated terms, the EUSolver-style approach), `si-nogram` (grammar removed, full LIA;
  informational only: our arms must stay inside the grammar).
- Time: `cvc5_s` = wall clock of the process (about 0.75 s of it is startup on this machine);
  `cvc5_internal_s` = cvc5's own `global::totalTime` (--stats), the solve time. One run each (deterministic).
- Size = tree size with `let`s expanded (comparable to our RuleNode sizes); dag = the printed size.
- Check: z3 on (declare-var -> declare-const, synth-fun -> define-fun with the solution,
  assert (not (and constraints...))): `unsat` = correct for every input.
"""
import argparse, csv, os, re, subprocess, sys, time

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
CVC5 = r"C:\Users\rafal\tools\cvc5\cvc5-Win64-x86_64-static\bin\cvc5.exe"
Z3 = r"C:\Users\rafal\tools\z3\z3-4.16.0-x64-win\bin\z3.exe"
OUT = os.path.join(ROOT, "results", "cvc5")

SPECS = {  # the harness specs (bench/common.jl) and the scaled family
    "max6": "spec_files/phase3_benchmarks/max6_simple.sl",
    "max6.logic": "spec_files/grammar_variants/max6_logic.sl",
    "above4": "spec_files/multi_answer/above4.sl",
    "array_search4": "spec_files/case_split/array_search4.sl",
    "countpos4.split": "spec_files/case_split/countpos4_split.sl",
    **{f"max{n}.sygus": f"spec_files/grammar_variants/max{n}_sygus.sl" for n in (6, 7, 8, 10, 12, 16, 18, 20, 30)},
    **{f"above{n}": f"spec_files/scaled/above{n}.sl" for n in (8, 10, 12, 14, 16, 20)},
    "array_search20": "spec_files/scaled/array_search20.sl",
}
MODES = {
    "default": [],
    "si-use": ["--sygus-si=use"],
    "si-all": ["--sygus-si=all"],
    "unif-pi": ["--sygus-unif-pi=complete"],
    "random": ["--sygus-enum=random"],   # random enumeration (cvc5 default seed: deterministic)
    "si-nogram": ["--sygus-si=use"],   # grammar removed: cvc5's single-invocation technique itself
}


# --- s-expressions -------------------------------------------------------------------------------
def tokenize(text):
    text = re.sub(r";[^\n]*", "", text)
    return re.findall(r'\(|\)|"[^"]*"|[^\s()]+', text)


def parse_all(text):
    toks, pos, out = tokenize(text), 0, []

    def one():
        nonlocal pos
        t = toks[pos]; pos += 1
        if t == "(":
            lst = []
            while toks[pos] != ")":
                lst.append(one())
            pos += 1
            return lst
        return t

    while pos < len(toks):
        out.append(one())
    return out


def show(e):
    return e if isinstance(e, str) else "(" + " ".join(show(x) for x in e) + ")"


def tree_size(e, env=None):
    """Node count with let-bound names expanded (memoized per binding, so no blow-up)."""
    env = env or {}
    if isinstance(e, str):
        return env.get(e, 1)
    if e and e[0] == "let":
        env2 = dict(env)
        for name, val in e[1]:
            env2[name] = tree_size(val, env)
        return tree_size(e[2], env2)
    if e and isinstance(e[0], list):               # ((_ bv ..) ...) style heads; not expected in LIA
        return sum(tree_size(x, env) for x in e)
    return 1 + sum(tree_size(x, env) for x in e[1:])


def dag_size(e):
    return 1 if isinstance(e, str) else sum(dag_size(x) for x in e)


# --- spec conversion and checking ----------------------------------------------------------------
def to_v2(forms):
    out = []
    for f in forms:
        if isinstance(f, list) and f and f[0] == "synth-fun" and len(f) == 5:
            g = f[4]
            v1 = all(isinstance(nt, list) and len(nt) == 3 and isinstance(nt[2], list) for nt in g)
            if v1:
                f = f[:4] + [[[nt[0], nt[1]] for nt in g], g]
        out.append(f)
    return out


def drop_grammar(forms):
    return [f[:4] if isinstance(f, list) and f and f[0] == "synth-fun" else f for f in forms]


def check_query(forms, sols):
    q, cons = ["(set-logic LIA)"], []
    for f in forms:
        if not isinstance(f, list) or not f:
            continue
        if f[0] == "declare-var":
            q.append(show(["declare-const", f[1], f[2]]))
        elif f[0] == "define-fun":
            q.append(show(f))
        elif f[0] == "synth-fun":
            q.append(sols[f[1]])
        elif f[0] == "constraint":
            cons.append(show(f[1]))
    q.append("(assert (not (and true " + " ".join(cons) + ")))")
    q.append("(check-sat)")
    return "\n".join(q) + "\n"


def run(cmd, inp=None, limit=None):
    t = time.perf_counter()
    try:
        p = subprocess.run(cmd, input=inp, capture_output=True, text=True, timeout=limit)
        return p.stdout, p.stderr, time.perf_counter() - t, False
    except subprocess.TimeoutExpired:
        return "", "", time.perf_counter() - t, True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("specs", nargs="+")
    ap.add_argument("--modes", default="default,si-use,si-all,unif-pi")
    ap.add_argument("--tlimit", type=float, default=60.0, help="seconds per cvc5 run")
    ap.add_argument("--check-limit", type=float, default=60.0, help="seconds for the z3 check")
    ap.add_argument("--tag", default="cvc5_compare")
    a = ap.parse_args()
    os.makedirs(os.path.join(OUT, "specs"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "solutions"), exist_ok=True)
    rows = []
    for name in a.specs:
        path = os.path.join(ROOT, SPECS.get(name, name))
        forms = parse_all(open(path, encoding="utf-8").read())
        v2 = os.path.join(OUT, "specs", os.path.basename(path))
        open(v2, "w", encoding="utf-8").write("\n".join(show(f) for f in to_v2(forms)) + "\n")
        ng = v2[:-3] + "_nogrammar.sl"
        open(ng, "w", encoding="utf-8").write("\n".join(show(f) for f in drop_grammar(forms)) + "\n")
        for mode in a.modes.split(","):
            cmd = [CVC5, "--lang=sygus2", "--stats", f"--tlimit={int(a.tlimit * 1000)}", *MODES[mode],
                   ng if mode == "si-nogram" else v2]
            out, err, secs, killed = run(cmd, limit=a.tlimit + 2)   # cvc5 on Windows exits slowly after its tlimit
            m = re.search(r"global::totalTime\s*=\s*(\d+)ms", out + err)
            internal = f"{int(m.group(1)) / 1000:.3f}" if m else ""
            sols = {}
            try:
                for f in parse_all(out):
                    for d in (f if isinstance(f, list) and f and isinstance(f[0], list) else [f]):
                        if isinstance(d, list) and d and d[0] == "define-fun":
                            sols[d[1]] = d
            except (IndexError, RecursionError):
                pass
            if sols:
                status = "solved"
            elif killed or secs >= a.tlimit * 0.98 or "timeout" in (out + err).lower():
                status = "timeout"
            else:
                status = "fail: " + " ".join((out + err).split())[:120]
            size = dag = check = check_s = ""
            if sols:
                body = [d[4] for d in sols.values()][0]
                size, dag = tree_size(body), dag_size(body)
                sol_text = {k: show(v) for k, v in sols.items()}
                open(os.path.join(OUT, "solutions", f"{os.path.basename(name).removesuffix('.sl')}__{mode}.smt2"), "w").write("\n".join(sol_text.values()) + "\n")
                zo, _, check_s, zk = run([Z3, f"-T:{int(a.check_limit)}", "-in"], check_query(forms, sol_text),
                                         limit=a.check_limit + 30)
                check = "timeout" if zk else (zo.strip().splitlines() or ["?"])[0]
                check_s = f"{check_s:.2f}"
            row = dict(spec=name, mode=mode, status=status, cvc5_s=f"{secs:.2f}", cvc5_internal_s=internal, size=size, dag=dag,
                       z3_check=check, z3_check_s=check_s)
            rows.append(row)
            print("  ".join(f"{k}={v}" for k, v in row.items()), flush=True)
    dst = os.path.join(OUT, f"{a.tag}.tsv")
    new = not os.path.exists(dst)
    with open(dst, "a", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0]), delimiter="\t")
        if new:
            w.writeheader()
        w.writerows(rows)
    print("wrote", os.path.relpath(dst, ROOT))


if __name__ == "__main__":
    sys.setrecursionlimit(100_000)
    main()
