# CEXGeneration Usage Examples

Quick reference for using the CEXGeneration module through various workflows.

## Quick Start

### 1. Generate a Query (One-Shot)

```bash
julia example_basic.jl spec.sl "x + 1"
# Output: spec_query.smt2
```

### 2. Test Multiple Candidates

```bash
julia example_caching.jl spec.sl "x + 1" "x - 1" "0" "x * 2"
# Output: query_1.smt2, query_2.smt2, query_3.smt2, query_4.smt2
```

### 3. Integrate into Your Code

```bash
julia example_integration.jl spec.sl my_func "your_candidate_expression"
```

## Examples Detailed

### `example_basic.jl`

**Purpose**: One-off query generation for a single candidate

**Usage**:
```bash
julia example_basic.jl path/to/spec.sl "candidate_expression"
```

**Features**:
- Parses specification file
- Generates counterexample query
- Writes to `spec_query.smt2` (or custom name)
- Good for: Quick testing, single verification

**Output**:
```
Parsed specification:
  Logic: QF_LIA
  Synthesis targets: f, g
  Free variables: x1, x2
  Constraints: 3

Generated query written to: spec_query.smt2

To check satisfiability:
  z3 spec_query.smt2
```

---

### `example_caching.jl`

**Purpose**: Efficient batch testing with specification caching

**Usage**:
```bash
# First run - parses and caches
julia example_caching.jl path/to/spec.sl "candidate1" "candidate2" "candidate3"

# Subsequent runs - loads from cache (fast!)
julia example_caching.jl path/to/spec.sl "new_candidate"
```

**Features**:
- Caches parsed specification to `.parsed.jl` file
- Generates multiple queries from same spec (no re-parsing)
- Good for: CEGIS loops, batch verification, benchmarking

**Caching Behavior**:
```
# First run - parses (slow)
Parsing specification from spec.sl
Saving cache to spec.parsed.jl

# Second run - cached (fast)
Loading cached specification from spec.parsed.jl
```

**Performance**:
- Parse: ~500ms (one-time)
- Cache save: ~10ms (one-time)
- Cache load: ~2ms (per run)
- Query generation: ~20ms (per candidate)

Result: 100 candidates = 500ms + 100×20ms = ~2 seconds (vs ~50 seconds without cache)

---

### `example_integration.jl`

**Purpose**: Programmatic verification within Julia code

**Usage**:
```bash
# Command-line mode
julia example_integration.jl spec.sl synthesis_func_name "candidate"

# Or in Julia code
julia -e 'include("example_integration.jl"); verify_candidate("spec.sl", "f", "x+1")'
```

**Features**:
- `verify_candidate()` function for programmatic checks
- Returns satisfiability result + Z3 model
- Good for: Integration into synthesis loops, CEGIS oracles

**Example Code**:
```julia
using CEXGeneration

sat, model = verify_candidate("spec.sl", "f", "x + 1")
if sat
    println("Candidate is valid!")
else
    println("Counterexample found:")
    println(model)
end
```

---

## Common Patterns

### Pattern 1: Simple Verification

```bash
# Generate query and verify with Z3
julia example_basic.jl problem.sl "if x > 0 then x else 0"
z3 problem_query.smt2
```

### Pattern 2: Batch Verification

```bash
# Test multiple candidates
candidates=(
    "0"
    "1"
    "x"
    "x + 1"
    "if x = 0 then 1 else x"
)

for cand in "${candidates[@]}"; do
    julia example_basic.jl problem.sl "$cand"
    z3 problem_query.smt2
done
```

### Pattern 3: CEGIS Integration (Julia)

```julia
using CEXGeneration

spec = parse_spec_from_file("problem.sl")

for iteration in 1:10
    # ... synthesize candidate ...
    candidates = Dict("f" => my_candidate)
    query = generate_cex_query(spec, candidates)
    
    # ... run Z3 and extract model ...
end
```

### Pattern 4: Cached Specification

```bash
# Automatic caching
julia example_caching.jl problem.sl

# Subsequent runs reuse cache
julia example_caching.jl problem.sl "candidate1"
julia example_caching.jl problem.sl "candidate2"
```

---

## Candidate Expression Syntax

### Supported Surface Syntax

| Type | Syntax | Example |
|---|---|---|
| Literals | `0`, `-5`, `true`, `false` | `42`, `-1` |
| Arithmetic | `+`, `-`, `*` | `x + 1`, `x - y`, `x * 2` |
| Comparison | `=`, `!=`, `<`, `<=`, `>`, `>=` | `x = 0`, `x < 10` |
| Boolean | `and`, `or`, `not` | `x > 0 and y < 10` |
| If-then-else | `if C then T else E` | `if x = 0 then 1 else 0` |
| Alternative ITE | `ite(C, T, E)` | `ite(x > 0, x, 0)` |
| Raw SMT-LIB2 | Parentheses | `(ite (= x 0) 1 x)` |

### Examples

```
"x + 1"                              → (+ x 1)
"if x = 0 then 1 else 0"            → (ite (= x 0) 1 0)
"x > 0 and y < 10"                  → (and (> x 0) (< y 10))
"if x > y then x else y"            → (ite (> x y) x y)
"(+ (* x 2) 1)"                     → (+ (* x 2) 1)  [pass-through]
```

---

## Troubleshooting

### Error: Module not found

```julia
ERROR: ArgumentError: Module CEXGeneration not found
```

**Solution**: Change to CEGIS directory:
```bash
cd ~/.julia/dev/CEGIS
julia example_basic.jl ...
```

### Error: File encoding issues

```
z3: ERROR: (parse error) ...
```

**Old Solution**: Use `iconv` or special shell redirects  
**New Solution**: Module handles UTF-8 automatically

### Error: Z3 not found (in example_integration.jl)

```
ERROR: z3: command not found
```

**Solution**: Install Z3 or skip the Z3 step
```bash
# Linux
sudo apt-get install z3

# macOS
brew install z3

# Windows - download from https://github.com/Z3Prover/z3/releases
```

---

## File Organization

```
CEGIS/
├── scripts/
│   ├── example_basic.jl              ← Start here
│   ├── example_caching.jl            ← For batches
│   ├── example_integration.jl        ← For loops
│   └── README.md                     ← This file
├── src/
│   └── CEXGeneration/
│       ├── CEXGeneration.jl          ← Module entry
│       ├── types.jl
│       ├── sexp.jl
│       ├── parser.jl
│       ├── candidates.jl
│       ├── query.jl
│       └── README.md                 ← Full API docs
├── MIGRATION_GUIDE.md                ← Tech details
└── test/
    └── test_cex_generation.jl        ← Unit tests
```

---

## Next Steps

1. **Try a basic example**:
   ```bash
   julia example_basic.jl ../spec_files/findidx_problem.sl "x + 1"
   ```

2. **Read the module docs**:
   ```bash
   less ../src/CEXGeneration/README.md
   ```

3. **Integrate into your code**:
   - See `example_integration.jl`
   - Import: `using CEXGeneration`
   - Call APIs: `parse_spec_from_file()`, `generate_cex_query()`

4. **Use caching for performance**:
   ```bash
   julia example_caching.jl spec.sl cand1 cand2 cand3
   ```

---

## Performance Tips

- **Cache large specs**: Use `serialize_spec()` to save parsed specifications
- **Reuse Spec objects**: Parse once, generate many queries
- **Batch candidates**: Use `example_caching.jl` for multiple tests
- **Expected timings**:
  - Spec parsing: 100-500ms (depends on size)
  - Spec serialization: 5-20ms
  - Query generation: 5-20ms
  - Z3 solving: 10ms-5s (solver-dependent)

---

## Support

For issues or questions:
1. Check [MIGRATION_GUIDE.md](../MIGRATION_GUIDE.md) for tech details
2. Review [CEXGeneration README](../src/CEXGeneration/README.md) for API docs
3. Run tests: `julia ../test/test_cex_generation.jl`
