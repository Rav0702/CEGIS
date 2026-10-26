#!/usr/bin/env python3
"""
build_pairs.py — generate the paired benchmark set and verify every pair.

Two directories with matched filenames:

    ours/   one functional-definition constraint per spec (our style)
    cdgp/   CDGP's case-split specification of the SAME function

Both sides of a pair carry an IDENTICAL synth-fun signature and grammar block,
so a paired sweep varies specification style and nothing else.

For every pair this script emits `equiv/<name>.smt2`, a pointwise mutual
entailment check on an uninterpreted `f`:

    ours  /\ not theirs   -> expect unsat
    theirs /\ not ours    -> expect unsat

Both unsat means the two constraint sets admit exactly the same functions.
Pointwise is sound here because every constraint in every spec mentions the
synth-fun at one and the same argument tuple (single-invocation).

Run:  python spec_files/paired/build_pairs.py [--verify-only]
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
CEGIS = os.path.normpath(os.path.join(ROOT, "..", ".."))
DEV = os.path.normpath(os.path.join(CEGIS, ".."))

OURS_SRC = os.path.join(CEGIS, "spec_files", "cdgp_paper")
PHASE3 = os.path.join(CEGIS, "spec_files", "phase3_benchmarks")
CDGP_LIA = os.path.join(DEV, "CDGP", "resources", "benchmarks_phd", "cdgp", "LIA")
CDGP_OTHER = os.path.join(CDGP_LIA, "other")
SYGUS = os.path.join(DEV, "benchmarks", "comp", "2017", "General_Track")

OUT_OURS = os.path.join(ROOT, "ours")
OUT_CDGP = os.path.join(ROOT, "cdgp")
OUT_EQUIV = os.path.join(ROOT, "equiv")


# ---------------------------------------------------------------- s-expr utils

def balanced_from(text, start):
    """Return the balanced s-expression beginning at text[start] == '('."""
    depth = 0
    i = start
    while i < len(text):
        if text[i] == ";":                       # SMT-LIB line comment
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1
    raise ValueError("unbalanced s-expression")


def extract_forms(text, head):
    """All top-level `(head ...)` forms, in order, as source strings."""
    out = []
    for m in re.finditer(r"\(" + re.escape(head) + r"\b", text):
        out.append(balanced_from(text, m.start()))
    return out


def synth_fun_block(path):
    """The whole `(synth-fun ...)` form — signature plus grammar — verbatim."""
    text = open(path, encoding="utf-8").read()
    forms = extract_forms(text, "synth-fun")
    if not forms:
        raise ValueError("no synth-fun in " + path)
    return forms[0]


def _synth_fun_args_span(block):
    """(start, end) of the parameter list form inside a synth-fun."""
    m = re.search(r"\(synth-fun\s+([^\s()]+)", block)
    argstart = block.index("(", m.end())
    args = balanced_from(block, argstart)
    return argstart, argstart + len(args)


def synth_fun_params(block):
    """[(name, sort), ...] from a synth-fun form."""
    lo, hi = _synth_fun_args_span(block)
    return re.findall(r"\(\s*([^\s()]+)\s+(Int|Bool|String)\s*\)", block[lo:hi])


def synth_fun_sort(block):
    """The declared return sort — the token right after the parameter list."""
    _, hi = _synth_fun_args_span(block)
    return re.match(r"\s*(Int|Bool|String)\b", block[hi:]).group(1)


def synth_fun_name(block):
    return re.search(r"\(synth-fun\s+([^\s()]+)", block).group(1)


def rename_vars(text, mapping):
    """Word-boundary rename, applied simultaneously so renames cannot chain."""
    pattern = re.compile(r"(?<![\w.-])(" + "|".join(map(re.escape, mapping)) + r")(?![\w.-])")
    return pattern.sub(lambda m: mapping[m.group(1)], text)


# ---------------------------------------------------------------- pair catalog

# `ours`      — basename under spec_files/cdgp_paper (or an absolute path)
# `theirs`    — CDGP source file
# `adapt`     — "bool1_0" rewrites their Int 1/0 result to Bool true/false
# `note`      — carried into the generated file's header
PAIRS = [
    dict(name="median3", ours=os.path.join(OURS_SRC, "median3.sl"),
         theirs=os.path.join(CDGP_OTHER, "Median3.sl")),
    dict(name="range3", ours=os.path.join(OURS_SRC, "range3.sl"),
         theirs=os.path.join(CDGP_OTHER, "Range3.sl")),
    dict(name="countpos2", ours=os.path.join(OURS_SRC, "countpos2.sl"),
         theirs=os.path.join(CDGP_OTHER, "CountPositive2.sl")),
    dict(name="countpos3", ours=os.path.join(OURS_SRC, "countpos3.sl"),
         theirs=os.path.join(CDGP_OTHER, "CountPositive3.sl")),
    dict(name="countpos4", ours=os.path.join(OURS_SRC, "countpos4.sl"),
         theirs=os.path.join(CDGP_OTHER, "CountPositive4.sl"),
         note="NOT a case-split spec: CDGP wrote this one with a `define-fun isPos` "
              "preamble and a single constraint, so this pair has ZERO style "
              "contrast (1 vs 1). Kept as a negative control; the preamble also "
              "forces the subprocess Z3 path. Do not read a style result off it."),
    dict(name="isseries3", ours=os.path.join(OURS_SRC, "isseries3.sl"),
         theirs=os.path.join(CDGP_OTHER, "ArithmeticSeries3.sl"), adapt="bool1_0"),
    dict(name="isseries4", ours=os.path.join(OURS_SRC, "isseries4.sl"),
         theirs=os.path.join(CDGP_OTHER, "ArithmeticSeries4.sl"), adapt="bool1_0"),
    dict(name="issorted4", ours=os.path.join(OURS_SRC, "issorted4.sl"),
         theirs=os.path.join(CDGP_OTHER, "SortedAscending4.sl"), adapt="bool1_0"),
    dict(name="issorted5", ours=os.path.join(OURS_SRC, "issorted5.sl"),
         theirs=os.path.join(CDGP_OTHER, "SortedAscending5.sl"), adapt="bool1_0"),
    dict(name="max4", ours=os.path.join(SYGUS, "max4.sl"),
         theirs=os.path.join(CDGP_LIA, "fg_max4.sl"),
         note="IDENTITY PAIR: CDGP's fg_max4.sl is the SyGuS-COMP max4.sl with the "
              "grammar block deleted, so both sides carry the same 5 declarative "
              "constraints (4 lower bounds + membership). Zero style contrast by "
              "construction. Use it as the runner's noise floor, not as a result."),
]

ADAPT_NOTE = (
    "RETURN SORT ADAPTED. CDGP declares this predicate as an Int-valued function "
    "returning 1/0; ours declares it Bool. Those are different synthesis problems "
    "(different start non-terminal, different SMT sort), so a literal transcription "
    "would not be a controlled pair. Their `(= (f ...) 1)` / `(= (f ...) 0)` results "
    "are rewritten to `true` / `false`, which preserves their case-split STRUCTURE "
    "(the experimental variable) while holding the return sort fixed."
)


# ---------------------------------------------------------------- generation

def build_cdgp_side(pair):
    ours_block = synth_fun_block(pair["ours"])
    our_params = synth_fun_params(ours_block)
    our_names = [n for n, _ in our_params]
    fname = synth_fun_name(ours_block)

    their_text = open(pair["theirs"], encoding="utf-8").read()
    their_block = synth_fun_block(pair["theirs"])
    their_names = [n for n, _ in synth_fun_params(their_block)]
    their_fname = synth_fun_name(their_block)

    if len(their_names) != len(our_names):
        raise ValueError("%s: arity mismatch %s vs %s" % (pair["name"], their_names, our_names))

    mapping = dict(zip(their_names, our_names))
    mapping[their_fname] = fname

    constraints = [rename_vars(c, mapping) for c in extract_forms(their_text, "constraint")]
    defines = [rename_vars(d, mapping) for d in extract_forms(their_text, "define-fun")]

    if pair.get("adapt") == "bool1_0":
        call = re.escape("(%s %s)" % (fname, " ".join(our_names)))
        constraints = [
            re.sub(r"\(=\s*" + call + r"\s*1\s*\)", "(= (%s %s) true)" % (fname, " ".join(our_names)), c)
            for c in constraints
        ]
        constraints = [
            re.sub(r"\(=\s*" + call + r"\s*0\s*\)", "(= (%s %s) false)" % (fname, " ".join(our_names)), c)
            for c in constraints
        ]

    rel_theirs = os.path.relpath(pair["theirs"], DEV).replace("\\", "/")
    rel_ours = os.path.relpath(pair["ours"], CEGIS).replace("\\", "/")

    head = [
        "; %s.sl — CDGP's specification of this problem." % pair["name"],
        ";",
        "; GENERATED by spec_files/paired/build_pairs.py — do not edit by hand.",
        ";",
        "; Constraints transcribed from",
        ";   ~/.julia/dev/%s" % rel_theirs,
        "; with their parameters renamed %s -> %s." % (
            ",".join(their_names), ",".join(our_names)),
        ";",
        "; The synth-fun signature and grammar block are copied verbatim from",
        ";   %s" % rel_ours,
        "; so this file and ours/%s.sl differ ONLY in specification style." % pair["name"],
    ]
    if pair.get("adapt") == "bool1_0":
        head += [";"] + [";   " + ln for ln in wrap(ADAPT_NOTE, 70)]
    if pair.get("note"):
        head += [";"] + [";   " + ln for ln in wrap(pair["note"], 70)]

    body = ["", "(set-logic LIA)", "", ours_block, ""]
    body += ["(declare-var %s %s)" % (n, s) for n, s in our_params]
    body += [""]
    if defines:
        body += defines + [""]
    body += constraints + ["", "(check-synth)", ""]
    return "\n".join(head + body)


def wrap(text, width):
    words, lines, cur = text.split(), [], ""
    for w in words:
        if len(cur) + len(w) + 1 > width:
            lines.append(cur)
            cur = w
        else:
            cur = (cur + " " + w).strip()
    if cur:
        lines.append(cur)
    return lines


def build_equiv(pair, ours_path, cdgp_path):
    """Pointwise mutual-entailment query between the two constraint sets."""
    ours_block = synth_fun_block(ours_path)
    params = synth_fun_params(ours_block)
    fname = synth_fun_name(ours_block)
    sort = synth_fun_sort(ours_block)

    def body_of(path):
        text = open(path, encoding="utf-8").read()
        cons = [strip_constraint(c) for c in extract_forms(text, "constraint")]
        defs = extract_forms(text, "define-fun")
        return defs, cons

    our_defs, our_cons = body_of(ours_path)
    their_defs, their_cons = body_of(cdgp_path)

    defs = our_defs + [d for d in their_defs if d not in our_defs]

    lines = [
        "; %s — are ours/ and cdgp/ the same specification?" % pair["name"],
        "; GENERATED by build_pairs.py. Two checks, both must answer unsat:",
        ";   1. ours entails theirs      2. theirs entails ours",
        "; Pointwise is sound: every constraint mentions the synth-fun at one",
        "; and the same argument tuple.",
        "",
        "(set-logic LIA)",
    ]
    lines += ["(declare-const %s %s)" % (n, s) for n, s in params]
    lines += defs
    lines.append("(declare-fun %s (%s) %s)" % (fname, " ".join(s for _, s in params), sort))
    lines.append("")
    lines.append("(push 1)  ; 1. ours /\\ not theirs")
    lines += ["(assert %s)" % c for c in our_cons]
    lines.append("(assert (not (and %s)))" % " ".join(their_cons)
                 if len(their_cons) > 1 else "(assert (not %s))" % their_cons[0])
    lines.append("(check-sat)")
    lines.append("(pop 1)")
    lines.append("")
    lines.append("(push 1)  ; 2. theirs /\\ not ours")
    lines += ["(assert %s)" % c for c in their_cons]
    lines.append("(assert (not (and %s)))" % " ".join(our_cons)
                 if len(our_cons) > 1 else "(assert (not %s))" % our_cons[0])
    lines.append("(check-sat)")
    lines.append("(pop 1)")
    lines.append("")
    return "\n".join(lines)


def strip_constraint(form):
    """`(constraint X)` -> `X`."""
    inner = form[len("(constraint"):].rstrip()
    assert inner.endswith(")")
    return inner[:-1].strip()


# ---------------------------------------------------------------- driver

def main():
    verify_only = "--verify-only" in sys.argv
    for d in (OUT_OURS, OUT_CDGP, OUT_EQUIV):
        os.makedirs(d, exist_ok=True)

    rows = []
    for pair in PAIRS:
        name = pair["name"]
        ours_out = os.path.join(OUT_OURS, name + ".sl")
        cdgp_out = os.path.join(OUT_CDGP, name + ".sl")
        equiv_out = os.path.join(OUT_EQUIV, name + ".smt2")

        if not verify_only:
            with open(ours_out, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(open(pair["ours"], encoding="utf-8").read())
            with open(cdgp_out, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(build_cdgp_side(pair))
            with open(equiv_out, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(build_equiv(pair, ours_out, cdgp_out))

        res = subprocess.run(["z3", equiv_out], capture_output=True, text=True)
        verdict = " ".join(res.stdout.split())
        ok = verdict == "unsat unsat"

        n_ours = len(extract_forms(open(ours_out, encoding="utf-8").read(), "constraint"))
        n_cdgp = len(extract_forms(open(cdgp_out, encoding="utf-8").read(), "constraint"))
        rows.append((name, n_ours, n_cdgp, "PASS" if ok else "FAIL", verdict or res.stderr.strip()))

    w = max(len(r[0]) for r in rows)
    print("%-*s  %5s  %5s  %6s  %s" % (w, "pair", "ours", "cdgp", "status", "z3"))
    print("-" * (w + 34))
    for name, a, b, st, v in rows:
        print("%-*s  %5d  %5d  %6s  %s" % (w, name, a, b, st, v))
    bad = [r[0] for r in rows if r[3] != "PASS"]
    print()
    print("%d/%d pairs verified" % (len(rows) - len(bad), len(rows)))
    if bad:
        print("FAILED: " + ", ".join(bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
