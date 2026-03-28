# Z3 SMT CEGIS: Quick Reference

**Quick lookup for common tasks.**

---

## Getting Started (2 min)

```bash
cd $CEGIS/scripts
julia z3_smt_cegis.jl
# Takes ~5 seconds, should say "SUCCESS"
```

---

## Command Syntax

```bash
julia z3_smt_cegis.jl [spec] [depth] [enums] [candidate]
```

| Position | Default | Example |
|----------|---------|---------|
| 1: spec | `findidx_problem.sl` | `../spec_files/findidx_2_simple.sl` |
| 2: depth | `6` | `4` |
| 3: enums | `50000` | `10000` |
| 4: candidate | none | `"ifelse(x1 > 5, x1 + x2, 0)"` |

---

## Test Specs

| Spec | Time | Use When |
|------|------|----------|
| `findidx_2_simple.sl` | <1s | Quick test (recommended start) |
| `findidx_problem.sl` | 1-5s | Baseline (default) |
| `findidx_2_problem.sl` | 5-30s | Larger problem |
| `findidx_5_problem.sl` | 30-120s| Very large |

---

## Result Meanings

| Status | Meaning | Next Step |
|--------|---------|-----------|
| **SUCCESS** | Found valid program ✓ | Done! Check `Synthesized Program` line |
| **FAILURE** | Max resources hit | Increase `max_depth` or `max_enumerations` |
| **TIMEOUT** | Exceeded time | Your problem is very hard; simplify or increase resources |

---

## Parser Selection

### Default (InfixCandidateParser)
```julia
oracle = Z3Oracle(spec_file, grammar)
```
✅ Use if: Clean type separation (Int vs Bool)  
❌ Use if: Type error about Bool+Int

### Alternative (SymbolicCandidateParser)
```julia
oracle = Z3Oracle(spec_file, grammar,
                  parser=CEXGeneration.SymbolicCandidateParser())
```
✅ Use if: Mixing booleans and integers  
❌ Use if: No type issues (slower)

**How to switch**: Edit `z3_smt_cegis.jl` line ~270, change Z3Oracle constructor.

---

## Tuning Parameters

**Problem too hard?**
```bash
# Increase depth (more expressive)
julia z3_smt_cegis.jl <spec> 7 50000

# Or increase enumerations (more thorough)
julia z3_smt_cegis.jl <spec> 6 100000

# Or both
julia z3_smt_cegis.jl <spec> 7 100000
```

**Synthesis too slow?**
```bash
# Reduce depth (cuts search space exponentially)
julia z3_smt_cegis.jl <spec> 4 50000

# Or reduce enumerations
julia z3_smt_cegis.jl <spec> 6 10000
```

---

## File Locations

```
CEGIS/
├── scripts/
│   └── z3_smt_cegis.jl        ← Main script (RUN THIS)
├── spec_files/
│   ├── findidx_problem.sl     ← Test specs (use these)
│   ├── findidx_2_simple.sl
│   └── ...
├── src/
│   ├── Oracles/
│   │   └── z3_oracle.jl       ← Z3Oracle implementation
│   ├── CEXGeneration/
│   │   ├── parser.jl          ← Spec parsing
│   │   ├── query.jl           ← Query generation
│   │   └── z3_verify.jl       ← Z3 verification
│   └── ...
└── docs/
    ├── IMPLEMENTATION_STATUS.md   ← Overall status
    ├── ARCHITECTURE_OVERVIEW.md   ← How components work
    ├── WORKFLOW_GUIDE.md          ← Usage guide (THIS IS FOR YOU)
    ├── Z3_ORACLE_GUIDE.md         ← Technical deep-dive
    ├── API_REFERENCE.md           ← Function signatures
    └── QUICK_REFERENCE.md         ← This file
```

---

## Common Issues

### "Spec file not found"
```bash
# Check you're in scripts/ directory
pwd
cd scripts

# Verify file exists
ls ../spec_files/findidx_problem.sl
```

### "No solution found"
→ Increase `max_depth` or `max_enumerations`, try simpler spec

### "type error: Bool + Int"
→ Switch to SymbolicCandidateParser (edit z3_smt_cegis.jl line ~270)

### "Z3 timeout or crash"
→ Reduce `max_enumerations` or `max_depth`; simplify problem

---

## Code Examples

### Example 1: Run with custom spec
```bash
julia z3_smt_cegis.jl ../spec_files/findidx_2_simple.sl 4 10000
```

### Example 2: Test a candidate
```bash
julia z3_smt_cegis.jl ../spec_files/findidx_problem.sl 6 50000 \
  "ifelse(x1 > 5, x1 + x2, x2 + x3)"
```

### Example 3: From Julia code
```julia
using CEGIS

# Build grammar
grammar = build_grammar_from_spec_file("../spec_files/findidx_problem.sl")

# Create oracle
oracle = Z3Oracle("../spec_files/findidx_problem.sl", grammar)

# Synthesize
result, _ = synth_with_oracle(grammar, :Expr, oracle; 
                              max_depth=6, max_enumerations=50000)

# Check result
@show result.status, result.program
```

---

## Documentation Map

| Question | Read This |
|----------|-----------|
| What is z3_smt_cegis? | [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) — Component overview |
| How do I use it? | [WORKFLOW_GUIDE.md](WORKFLOW_GUIDE.md) — Step-by-step guide |
| How does it work? | [ARCHITECTURE_OVERVIEW.md](ARCHITECTURE_OVERVIEW.md) — System design |
| How does Z3Oracle work? | [Z3_ORACLE_GUIDE.md](Z3_ORACLE_GUIDE.md) — Verification details |
| What functions are there? | [API_REFERENCE.md](API_REFERENCE.md) — All signatures |
| Where is X in the code? | See "File Locations" above |

---

## Key Concepts (30-second version)

**Z3 SMT CEGIS** = Synthesize programs that satisfy formal constraints

1. **Parse** SyGuS spec (.sl file)
2. **Build** grammar of candidate operators
3. **Synthesize** candidates (RuleNodes)
4. **Verify** each with Z3 SMT solver
   - Valid? Done! Return program.
   - Invalid? Extract counterexample.
   - Learn from counterexample, repeat with smaller search space

**Counterexample**: Input values where candidate fails

**Spec**: SMT constraints defining what program should do

**Grammar**: Syntactic rules for candidates (e.g., `Expr = Expr + Expr`)

---

## Exit Codes

```bash
julia z3_smt_cegis.jl ...
echo $?  # Check exit code
```

| Code | Meaning |
|------|---------|
| 0 | SUCCESS — Found solution |
| 1 | FAILURE — No solution found |
| 2 | ERROR — Crash or exception |

---

## Checklist: Verify Installation

- [ ] Julia installed? `julia --version`
- [ ] In CEGIS directory? `pwd` should show `..\CEGIS`
- [ ] Spec files present? `ls spec_files/findidx_*.sl`
- [ ] Can run: `cd scripts && julia z3_smt_cegis.jl`
- [ ] Got SUCCESS? ✓ You're ready!

---

## Next Steps

1. **Start here**: [WORKFLOW_GUIDE.md](WORKFLOW_GUIDE.md)
2. **Understand design**: [ARCHITECTURE_OVERVIEW.md](ARCHITECTURE_OVERVIEW.md)
3. **Reference functions**: [API_REFERENCE.md](API_REFERENCE.md)
4. **Deep dive**: [Z3_ORACLE_GUIDE.md](Z3_ORACLE_GUIDE.md) (if curious about verification)

---

## One-Page Cheat Sheet

```julia
# Import
using CEGIS, HerbCore

# Setup
grammar = build_grammar_from_spec_file("spec.sl")
oracle = Z3Oracle("spec.sl", grammar)  # Or with SymbolicCandidateParser()

# Synthesize
result, _ = synth_with_oracle(grammar, :Expr, oracle; 
                              max_depth=6, max_enumerations=50000)

# Check
@show result.status                      # :success, :failure, :timeout
@show result.program                     # RuleNode (if success)
@show rulenode2expr(result.program, grammar)  # readable expression
@show result.counterexamples             # what was learned
```

---

**Quick Help**: See [WORKFLOW_GUIDE.md](WORKFLOW_GUIDE.md)  
**Found a Bug?**: Check [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md#known-issues--limitations)  
**Last Update**: March 28, 2026
