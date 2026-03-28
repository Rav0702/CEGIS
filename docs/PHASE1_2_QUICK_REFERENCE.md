"""
PHASE1_2_QUICK_REFERENCE.md

Quick reference for using the new generic CEGISProblem architecture (Phase 1 & 2).
Status: Foundation implemented, integration testing in progress.
"""

# Phase 1 & 2: Quick Reference

## TL;DR Usage

```julia
# Old way (still works):
oracle = Z3Oracle(spec_file, grammar)
result, _ = synth_with_oracle(grammar, :Expr, oracle)

# New way (recommended):
problem = CEGISProblem(
    spec_file;
    oracle_factory = Z3OracleFactory(),
    iterator_config = BFSIteratorConfig(max_depth=6)
)
result = run_synthesis(problem)
```

## Component Overview

### 1. Spec Parsers (AbstractSpecParser)

**Purpose**: Convert specification files (any format) to Spec type

**Implemented**:
- `SyGuSParser()` — Parses `.sl` files (delegate to CEXGeneration)

**Template** (User can implement):
- `JSONSpecParser()` — For JSON specs
- `YAMLSpecParser()` — For YAML specs

**Usage**:
```julia
parser = SyGuSParser()
spec = parse_spec(parser, "benchmark.sl")
# Returns: CEXGeneration.Spec with logic, synth_funs, free_vars, constraints
```

### 2. Oracle Factories (AbstractOracleFactory)

**Purpose**: Encapsulate oracle instantiation and configuration

**Implemented**:
- `Z3OracleFactory()` — Formal verification via Z3 SMT solver
- `IOExampleOracleFactory(examples)` — Test-based verification
- `SemanticSMTOracleFactory()` — Legacy oracle (compatibility)

**Usage**:
```julia
# Default Z3 oracle
oracle_factory = Z3OracleFactory()

# With custom candidate parser
oracle_factory = Z3OracleFactory(parser=SymbolicCandidateParser())

# Test-based oracle
test_examples = [IOExample(...), ...]
oracle_factory = IOExampleOracleFactory(test_examples)

# Create actual oracle
oracle = create_oracle(oracle_factory, spec, grammar)
```

### 3. Iterator Configurations (AbstractSynthesisIterator)

**Purpose**: Configure search strategy (BFS, DFS, random, etc.)

**Implemented**:
- `BFSIteratorConfig(max_depth=5)` — Breadth-first (DEFAULT)
- `DFSIteratorConfig(max_depth=6)` — Depth-first
- `RandomSearchIteratorConfig(max_depth=6, seed=42)` — Random enumeration

**Usage**:
```julia
# Default BFS
config = BFSIteratorConfig()

# Custom depth DFS
config = DFSIteratorConfig(max_depth=8)

# Random with seed for reproducibility
config = RandomSearchIteratorConfig(max_depth=7, seed=123)

# Create actual iterator (low-level, rarely needed)
iterator = create_iterator(config, grammar, :Expr)
```

### 4. Grammar Configuration (GrammarConfig)

**Purpose**: Declarative grammar specification instead of hardcoded strings

**Reusable Operation Sets**:
- `BASE_OPERATIONS` — Standard arithmetic (+, -, *, <, >, ifelse, etc.)
- `EXTENDED_OPERATIONS` — Plus division, sqrt, min, max
- `STRING_OPERATIONS` — String functions (length, substr, concat, etc.)
- `BITVECTOR_OPERATIONS` — Bitwise operations (&, |, ^, ~, <<, >>)

**Usage**:
```julia
# Default configuration
config = GrammarConfig()

# Extended operations
config = GrammarConfig(base_operations=EXTENDED_OPERATIONS)

# Custom rules
config = GrammarConfig(
    base_operations = BASE_OPERATIONS,
    additional_rules = ["Expr = Expr ^ Expr"]  # XOR
)

# Build grammar (placeholder - not fully implemented)
grammar = build_generic_grammar(spec, config)
```

### 5. Generic CEGISProblem

**Purpose**: Unified configuration object for entire synthesis task

**Fields**:
- **Configuration**: spec_path, spec_parser, grammar_config, oracle_factory, iterator_config
- **Parameters**: start_symbol, max_depth, max_enumerations, max_time, max_iterations
- **Debug**: desired_solution, metadata
- **Lazy Init**: spec, grammar, oracle, is_initialized

**Usage**:
```julia
# Minimal (uses all defaults)
problem = CEGISProblem("benchmark.sl")

# Full configuration
problem = CEGISProblem(
    "benchmark.sl";
    spec_parser = SyGuSParser(),
    grammar_config = GrammarConfig(base_operations=EXTENDED_OPERATIONS),
    oracle_factory = Z3OracleFactory(),
    iterator_config = DFSIteratorConfig(max_depth=8),
    start_symbol = :Expr,
    max_depth = 7,
    max_enumerations = 100_000,
    max_time = 300.0,  # 5 minutes
    desired_solution = "max(x, y)",
    metadata = Dict("author" => "Alice", "source" => "SyGuS comp")
)

# Inspection before running
ensure_initialized!(problem)
println("Spec has $(length(problem.spec.constraints)) constraints")
println("Grammar ready: $(problem.is_initialized)")

# Run synthesis
result = run_synthesis(problem)
```

### 6. Universal Run Function

**Purpose**: Orchestrate entire synthesis pipeline from config

**Function Signature**:
```julia
function run_synthesis(problem::CEGISProblem) :: CEGISResult
```

**Process**:
1. Call `ensure_initialized!(problem)` — parse, build, instantiate
2. Create iterator via `create_iterator(problem.iterator_config, ...)`
3. Call `synth_with_oracle()` with custom iterator
4. Call `check_desired_solution()` if provided (optional debug)
5. Return `CEGISResult`

**Usage**:
```julia
problem = CEGISProblem("spec.sl"; oracle_factory=oracle_factory)
result = run_synthesis(problem)

# Check result
if result.status == cegis_success
    println("Solution found!")
    println("Program: $(rulenode2expr(result.program, problem.grammar))")
    println("Required $(result.iterations) CEGIS iterations")
else
    println("No solution found (status=$(result.status))")
    println("Reached $(result.iterations) iterations")
    println("$(length(result.counterexamples)) counterexamples collected")
end
```

## Migration: Old API → New API

### Before (Hardcoded)
```julia
# 1. Build grammar with string interpolation
grammar_str = """
@csgrammar begin
    Expr = x | y | 0 | 1
    Expr = Expr + Expr
    Expr = Expr - Expr
    Expr = Expr < Expr
    Expr = ifelse(Expr, Expr, Expr)
end
"""
grammar = eval_typed(Meta.parse(grammar_str), Main)

# 2. Create oracle
oracle = Z3Oracle("spec.sl", grammar)

# 3. Run hardcoded CEGIS
result, _ = synth_with_oracle(grammar, :Expr, oracle; max_depth=5)
```

### After (Configuration-Driven)
```julia
# 1. Create problem with configuration (replaces hardcoding)
problem = CEGISProblem(
    "spec.sl";
    grammar_config = GrammarConfig(base_operations=BASE_OPERATIONS),
    oracle_factory = Z3OracleFactory(),
    iterator_config = BFSIteratorConfig(max_depth=5)
)

# 2. Run synthesis (handles everything)
result = run_synthesis(problem)
```

## Extension Guide: Adding Custom Components

### Add Custom Spec Parser
```julia
struct MyCustomParser <: AbstractSpecParser end

function parse_spec(::MyCustomParser, path::String) :: Spec
    # Read file
    data = read_my_format(path)
    
    # Convert to Spec
    logic = data["logic"]
    synth_funs = [SynthFun(...) for ...]
    free_vars = [FreeVar(...) for ...]
    constraints = data["constraints"]
    
    return Spec(logic, synth_funs, free_vars, constraints)
end

# Use it
problem = CEGISProblem("spec.custom"; spec_parser=MyCustomParser())
```

### Add Custom Oracle Factory
```julia
struct MyOracleFactory <: AbstractOracleFactory
    config :: MyConfig
end

function create_oracle(factory::MyOracleFactory, spec, grammar)
    return MyOracle(spec, grammar, factory.config)
end

# Use it
factory = MyOracleFactory(my_config)
problem = CEGISProblem("spec.sl"; oracle_factory=factory)
```

### Add Custom Iterator Config
```julia
struct MyIteratorConfig <: AbstractSynthesisIterator
    max_depth :: Int
    # your fields
end

function create_iterator(config::MyIteratorConfig, grammar, start_symbol)
    # Build custom iterator
    return MyIterator(grammar, start_symbol, config.max_depth)
end

# Use it
problem = CEGISProblem("spec.sl"; iterator_config=MyIteratorConfig(7))
```

## Backward Compatibility

### Old Code Still Works
```julia
# These all continue to work exactly as before:

# Direct oracle creation
oracle = Z3Oracle(spec_file, grammar)

# Legacy synth_with_oracle
result, _ = synth_with_oracle(grammar, :Expr, oracle)

# Manual grammar building
grammar = @csgrammar begin
    Expr = x | y | 0 | 1
    Expr = Expr + Expr
end

# Accessing legacy CEGISProblem (renamed)
problem_legacy = CEGISProblemLegacy(grammar, :Expr, spec, oracle_func)
```

### Gradual Migration Path
1. **Year 1**: Use new API for new problems, keep old code as-is
2. **Year 2**: Migrate important scripts to new API
3. **Year 3**: Deprecate old API, require new API

## Current Limitations

| Feature | Status | Notes |
|---------|--------|-------|
| SyGuSParser | ✅ Works | Full SyGuS-v2 support via CEXGeneration |
| Z3OracleFactory | ⚠️ Partial | Needs Spec.file_path metadata |
| BFSIteratorConfig | ✅ Works | Uses HerbSearch.BFSIterator |
| DFSIteratorConfig | ⚠️ Partial | Uses HerbSearch.DFSIterator |
| RandomSearchConfig | ⚠️ Partial | Currently uses BFS (fallback) |
| GrammarConfig | ⚠️ Partial | build_generic_grammar() is stub |
| desired_solution | ⏳ Not yet | check_desired_solution() is stub |

## Next Steps (Phase 3)

- [ ] Complete build_generic_grammar() with HerbGrammar integration
- [ ] Implement check_desired_solution() with proper verification
- [ ] Add default factories to CEGISProblem constructor
- [ ] Create 6+ example scripts showcasing new API
- [ ] Update documentation with migration guide

---

**Phase Status**: ✅ Core architecture complete, integration testing in progress  
**Last Updated**: March 28, 2026
