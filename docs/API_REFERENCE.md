# API Reference: Z3 SMT CEGIS

**Purpose**: Complete reference for all public functions, types, and exports.

---

## Table of Contents

1. [Main Entry Point](#main-entry-point)
2. [Z3Oracle Type](#z3oracle-type)
3. [CEXGeneration Module](#cexgeneration-module)
4. [Result Types](#result-types)
5. [Counterexample Type](#counterexample-type)
6. [Grammar Building](#grammar-building)
7. [Script Functions](#script-functions)

---

## Main Entry Point

### synth_with_oracle()

**Location**: `src/oracle_synth.jl`

```julia
function synth_with_oracle(
    grammar::AbstractGrammar,
    start_symbol::Symbol,
    oracle::AbstractOracle;
    max_depth::Int = 6,
    max_enumerations::Int = 50_000
) -> (result::CEGISResult, satisfied_examples::Int)
```

**Description**: Run CEGIS synthesis loop with provided oracle for verification.

**Parameters**:
- `grammar::AbstractGrammar` — Synthesis grammar (Herb)
- `start_symbol::Symbol` — Starting non-terminal (typically `:Expr`)
- `oracle::AbstractOracle` — Verification oracle (Z3Oracle, IOExampleOracle, etc.)
- `max_depth::Int` (optional, default=6) — Maximum RuleNode tree depth
- `max_enumerations::Int` (optional, default=50_000) — Maximum candidates to try

**Returns**:
- Tuple: `(CEGISResult, satisfied_examples::Int)`
  - `result::CEGISResult` — Synthesis result with status, program, and counterexamples
  - `satisfied_examples::Int` — Number of test examples satisfied (if applicable)

**Example**:
```julia
result, satisfied = synth_with_oracle(
    grammar, :Expr, oracle;
    max_depth = 6,
    max_enumerations = 50_000
)

if result.status == CEGIS.cegis_success
    println("Synthesized: $(result.program)")
else
    println("Failed after $(result.iterations) iterations")
end
```

---

## Z3Oracle Type

### Constructor

**Location**: `src/Oracles/z3_oracle.jl:72`

```julia
function Z3Oracle(
    spec_file::String,
    grammar::AbstractGrammar;
    parser::CEXGeneration.AbstractCandidateParser = 
        CEXGeneration.InfixCandidateParser()
) -> ::Z3Oracle
```

**Description**: Create a Z3-based SMT verification oracle.

**Parameters**:
- `spec_file::String` — Path to SyGuS specification file (.sl)
- `grammar::AbstractGrammar` — Herb grammar for synthesis
- `parser::AbstractCandidateParser` (optional) — Parser strategy
  - Default: `CEXGeneration.InfixCandidateParser()` (strict type checking)
  - Alternative: `CEXGeneration.SymbolicCandidateParser()` (mixed types)

**Returns**: `Z3Oracle` instance ready for verification

**Exceptions**:
- Throws if spec_file doesn't exist
- Throws if spec_file has invalid SyGuS syntax

**Example**:
```julia
# Default: strict type checking
oracle = Z3Oracle("../spec_files/findidx_problem.sl", grammar)

# With SymbolicCandidateParser: allows mixed bool-int
oracle = Z3Oracle("../spec_files/findidx_problem.sl", grammar,
                  parser=CEXGeneration.SymbolicCandidateParser())
```

### Type Definition

```julia
mutable struct Z3Oracle <: AbstractOracle
    spec_file::String
    spec::Any                                    # CEXGeneration.Spec
    grammar::AbstractGrammar
    z3_ctx::Z3.Context
    z3_vars::Dict{String, Z3.Expr}
    mod::Module
    enum_count::Int
    test_candidate::Union{String, Nothing}
    parser::CEXGeneration.AbstractCandidateParser
end
```

### Methods

#### extract_counterexample()

**Location**: `src/Oracles/z3_oracle.jl:110`

```julia
function extract_counterexample(
    oracle::Z3Oracle,
    candidate::RuleNode
) -> ::Union{Counterexample, Nothing}
```

**Description**: Verify candidate against SMT constraints. Returns counterexample if invalid, nothing if verified.

**Parameters**:
- `oracle::Z3Oracle` — Z3Oracle instance
- `candidate::RuleNode` — Candidate program (RuleNode tree)

**Returns**:
- `Counterexample` — If candidate is invalid (SAT model found)
- `nothing` — If candidate is valid (verified) or error occurs

**Process**:
1. Convert RuleNode to Julia Expr
2. Parse with selected parser (Infix or Symbolic)
3. Generate SMT-LIB2 query via CEXGeneration
4. Call Z3 with native API
5. Extract model if SAT
6. Build Counterexample from model

**Example**:
```julia
candidate = # ...RuleNode from synthesizer...

cex = extract_counterexample(oracle, candidate)

if cex !== nothing
    println("Invalid at: $(cex.input)")
    println("Expected: $(cex.expected_output)")
else
    println("Verified!")
end
```

**Counterexample Structure** (when returned):
```julia
Counterexample(
    input::Dict{Symbol, Any},           # Variable assignments
    expected_output::Any,               # What spec says output should be
    actual_output::Union{Any, Nothing}  # What candidate produced
)
```

---

## CEXGeneration Module

**Location**: `src/CEXGeneration/CEXGeneration.jl`

### Types

#### Spec

```julia
mutable struct Spec
    logic::String                        # "LIA", "NIA", "BV", "SLIA", etc.
    synth_funs::Vector{SynthFun}        # Functions to synthesize
    free_vars::Vector{FreeVar}          # Free variables in constraints
    constraints::Vector{String}         # SMT-LIB2 constraint strings
end
```

**Fields**:
- `logic::String` — SMT logic (e.g., "QF_LIA", "QF_BV")
- `synth_funs::Vector{SynthFun}` — Synthesis targets
- `free_vars::Vector{FreeVar}` — Variables used in constraints
- `constraints::Vector{String}` — Raw SMT constraint expressions

#### SynthFun

```julia
struct SynthFun
    name::String                         # Function name (e.g., "fnd_sum")
    params::Vector{Tuple{String, String}} # [(param_name, sort), ...]
    sort::String                         # Return sort (e.g., "Int")
end
```

**Fields**:
- `name::String` — Function to synthesize
- `params::Vector` — Parameters with types
- `sort::String` — Return type

**Example**: From `.sl` file `(synth-fun fnd_sum ((x1 Int) (x2 Int)) Int)`:
```julia
SynthFun(
    name="fnd_sum",
    params=[("x1", "Int"), ("x2", "Int")],
    sort="Int"
)
```

#### FreeVar

```julia
struct FreeVar
    name::String
    sort::String
end
```

**Fields**:
- `name::String` — Variable name
- `sort::String` — Type (e.g., "Int")

#### Z3Result

```julia
struct Z3Result
    status::Symbol                       # :sat, :unsat, or :error
    model::Dict{String, Any}            # Variable → value mappings
end
```

**Fields**:
- `status::Symbol` — Verification result status
- `model::Dict` — Z3 model (variable assignments)

### Main Functions

#### parse_spec_from_file()

```julia
function parse_spec_from_file(filename::String) -> ::Spec
```

**Description**: Parse SyGuS specification file into Spec object.

**Parameters**:
- `filename::String` — Path to .sl file

**Returns**: `Spec` object with parsed specification

**Supported Features**:
- SyGuS-v2 format
- Logical contexts (LIA, NIA, etc.)
- Synth-fun declarations
- Declare-var (free variables)
- Constraints with implications
- Inv-constraint expansion (pre/trans/post)

**Throws**:
- FileNotFoundError if file doesn't exist
- SyntaxError if spec is malformed

**Example**:
```julia
spec = CEXGeneration.parse_spec_from_file("../spec_files/findidx_problem.sl")

println("Logic: $(spec.logic)")
println("Synth function: $(spec.synth_funs[1].name)")
println("Free vars: $(length(spec.free_vars))")
println("Constraints: $(length(spec.constraints))")
```

#### generate_cex_query()

```julia
function generate_cex_query(
    spec::Spec,
    candidates::Dict{String, String}  # func_name => smt2_code
) -> ::String  # SMT-LIB2 query
```

**Description**: Generate SMT-LIB2 query for counterexample finding.

**Parameters**:
- `spec::Spec` — Specification object
- `candidates::Dict` — Dictionary mapping function names to SMT-LIB2 expressions

**Returns**: Complete SMT-LIB2 query string (ready for Z3)

**Query Features**:
- Variable declarations
- Candidate function definitions
- Spec function building (nested ITE from implications)
- Constraint negation (for CEX finding)
- Check-sat + get-value commands

**Example**:
```julia
query = CEXGeneration.generate_cex_query(
    spec,
    Dict("fnd_sum" => "(ite (> x1 5) (+ x1 x2) 0)")
)

# Query can be passed to verify_query()
result = CEXGeneration.verify_query(query)
```

#### verify_query()

```julia
function verify_query(query::String) -> ::Z3Result
```

**Description**: Verify SMT-LIB2 query using Z3.

**Parameters**:
- `query::String` — SMT-LIB2 query string

**Returns**: `Z3Result` with status and model

**Status Values**:
- `:sat` — Counterexample found (model available)
- `:unsat` — All constraints satisfied (verified)
- `:error` — Z3 error or timeout

**Example**:
```julia
result = CEXGeneration.verify_query(query)

if result.status == :unsat
    println("Verified!")
elseif result.status == :sat
    println("Found counterexample:")
    for (var, val) in result.model
        println("  $var = $val")
    end
end
```

#### candidate_to_smt2()

```julia
function candidate_to_smt2(src::String) -> ::String
```

**Description**: Convert infix expression string to SMT-LIB2 format.

**Parameters**:
- `src::String` — Infix expression (e.g., "x1 + x2 > 5")

**Returns**: SMT-LIB2 S-expression (e.g., "(> (+ x1 x2) 5)")

**Example**:
```julia
smt2 = CEXGeneration.candidate_to_smt2("x1 + x2 * 3")
# Returns: "(+ x1 (* x2 3))"
```

### Candidate Parsers

#### AbstractCandidateParser

**Definition**: Abstract base for candidate parsing strategies

```julia
abstract type AbstractCandidateParser end
```

**Subtypes**:
1. `InfixCandidateParser` — Strict SMT-LIB2 type checking
2. `SymbolicCandidateParser` — Mixed-type support via ITE coercion

#### InfixCandidateParser

```julia
struct InfixCandidateParser <: CEXGeneration.AbstractCandidateParser end
```

**Behavior**: Strict type checking, rejects mixed bool-int

**Usage**:
```julia
parser = CEXGeneration.InfixCandidateParser()
oracle = Z3Oracle(spec_file, grammar, parser=parser)
```

#### SymbolicCandidateParser

```julia
struct SymbolicCandidateParser <: CEXGeneration.AbstractCandidateParser end
```

**Behavior**: Auto-coerces mixed types with ITE

**Usage**:
```julia
parser = CEXGeneration.SymbolicCandidateParser()
oracle = Z3Oracle(spec_file, grammar, parser=parser)
```

---

## Result Types

### CEGISResult

**Location**: `src/types.jl`

```julia
struct CEGISResult
    status::CEGISStatus                 # :success, :failure, or :timeout
    program::Union{RuleNode, Nothing}   # Synthesized program if successful
    iterations::Int                     # Number of CEGIS iterations
    counterexamples::Vector{Counterexample}  # All counterexamples found
end
```

**Fields**:
- `status::CEGISStatus` — Synthesis outcome
- `program::Union{RuleNode, Nothing}` — Result program (if status == :success)
- `iterations::Int` — Number of synthesis iterations executed
- `counterexamples::Vector{Counterexample}` — Counterexamples found during search

**Status Values**:
- `CEGIS.cegis_success` — Successfully synthesized valid program
- `CEGIS.cegis_failure` — Failed (max resources exhausted)
- `CEGIS.cegis_timeout` — Timeout during synthesis

**Example**:
```julia
result, _ = synth_with_oracle(grammar, :Expr, oracle)

if result.status == CEGIS.cegis_success
    expr = rulenode2expr(result.program, grammar)
    println("Solution: $expr")
else
    println("Failed after $(result.iterations) iterations")
    if !isempty(result.counterexamples)
        println("Last counterexample: $(result.counterexamples[end])")
    end
end
```

### CEGISStatus

**Values**:
```julia
const cegis_success = :success
const cegis_failure = :failure
const cegis_timeout = :timeout

Union{typeof(cegis_success), typeof(cegis_failure), typeof(cegis_timeout)}
```

---

## Counterexample Type

### Counterexample

**Location**: `src/counterexample.jl`

```julia
struct Counterexample
    input::Dict{Symbol, Any}
    expected_output::Any
    actual_output::Union{Any, Nothing}
end
```

**Fields**:
- `input::Dict{Symbol, Any}` — Variable assignments causing failure
- `expected_output::Any` — What spec says output should be
- `actual_output::Union{Any, Nothing}` — What candidate actually produced

**Example**:
```julia
cex = Counterexample(
    Dict(:x1 => 3, :x2 => 5, :x3 => 1),
    8,
    10
)

println("Failed at: $(cex.input)")
println("Expected: $(cex.expected_output), got: $(cex.actual_output)")
```

### Counterexample Functions

#### minimize_counterexample()

```julia
function minimize_counterexample(
    cex::Counterexample,
    oracle::AbstractOracle
) -> ::Union{Counterexample, Nothing}
```

**Description**: Try to find smaller counterexample by reducing input values.

**Returns**: Minimized counterexample or original if already minimal

#### is_duplicate_counterexample()

```julia
function is_duplicate_counterexample(
    cex1::Counterexample,
    cex2::Counterexample
) -> ::Bool
```

**Description**: Check if two counterexamples are equivalent.

**Returns**: true if same input and expected output

---

## Grammar Building

### build_grammar_from_spec_file()

**Location**: `scripts/z3_smt_cegis.jl`

```julia
function build_grammar_from_spec_file(spec_file::String) -> ::AbstractGrammar
```

**Description**: Build Herb synthesis grammar from SyGuS spec.

**Parameters**:
- `spec_file::String` — Path to .sl file

**Returns**: `AbstractGrammar` (Herb grammar object)

**Process**:
1. Parse spec via CEXGeneration
2. Extract free variable names
3. Build @csgrammar block with:
   - Terminal constants (0, 1, 2)
   - Variables from spec
   - Operators (arithmetic, comparison, logical)
   - Composite rules (ifelse, etc.)

**Example**:
```julia
grammar = build_grammar_from_spec_file("../spec_files/findidx_problem.sl")

println("Grammar has $(length(grammar.rules)) rules")

# Use in synthesis
result, _ = synth_with_oracle(grammar, :Expr, oracle)
```

---

## Script Functions

### run_z3_cegis()

**Location**: `scripts/z3_smt_cegis.jl:200`

```julia
function run_z3_cegis(
    spec_file::String;
    max_depth::Int = 6,
    max_enumerations::Int = 50_000
) -> ::CEGISResult
```

**Description**: Main CEGIS synthesis orchestrator.

**Parameters**:
- `spec_file::String` — Path to spec file
- `max_depth::Int` (optional) — Max RuleNode depth
- `max_enumerations::Int` (optional) — Max candidates

**Returns**: `CEGISResult` with status, program, and counterexamples

**Steps**:
1. Load and parse specification
2. Build grammar from spec
3. Create Z3Oracle
4. Run synth_with_oracle()
5. Report results

**Example**:
```julia
result = run_z3_cegis(
    "../spec_files/findidx_problem.sl",
    max_depth=6,
    max_enumerations=50_000
)
```

### test_candidate_directly()

**Location**: `scripts/z3_smt_cegis.jl:120`

```julia
function test_candidate_directly(
    spec_file::String,
    candidate_str::String,
    oracle::Z3Oracle,
    current_counterexamples::Vector
) -> ::Tuple{Symbol, Union{Counterexample, Nothing}}
```

**Description**: Test a specific candidate program against spec.

**Parameters**:
- `spec_file::String` — Spec file path
- `candidate_str::String` — Candidate as infix expression string
- `oracle::Z3Oracle` — Oracle for verification
- `current_counterexamples::Vector` — Previous counterexamples to check

**Returns**: Tuple `(status, counterexample_or_nothing)`
- status: `:valid`, `:invalid`, or `:error`
- counterexample: Counterexample if invalid, nothing if valid

**Example**:
```julia
status, cex = test_candidate_directly(
    "../spec_files/findidx_problem.sl",
    "ifelse(x1 > 5, x1 + x2, x2 + x3)",
    oracle,
    []
)

if status == :valid
    println("Candidate is VALID!")
else
    println("Invalid: $cex")
end
```

---

## Module Exports

**From `src/CEGIS.jl`**:

```julia
export
    # Support modules
    CEXGeneration,

    # Core types
    CEGISResult, CEGISStatus, Counterexample,
    cegis_success, cegis_failure, cegis_timeout,
    
    # Oracles
    AbstractOracle,
    IOExampleOracle,
    Z3Oracle,

    # Main synthesis
    synth_with_oracle,
    run_cegis,
    run_ioexample_cegis,

    # Synthesizer
    synthesize, build_iterator, update_problem_with_counterexample!,

    # Verifier
    verify, extract_counterexample, oracle_from_examples, oracle_from_smt,

    # Results
    VerificationResult, VerificationStatus, verified, verification_failed,

    # Counterexample utilities
    counterexample_to_ioexample,
    minimize_counterexample,
    generalize_counterexample,
    is_duplicate_counterexample,

    # Learning
    learn_constraint,
    add_constraint_to_grammar!,
    reset_learned_constraints!,
    constraints_from_counterexamples
```

---

## Usage Examples

### Example 1: Simple Synthesis

```julia
using CEGIS, HerbCore, HerbGrammar

# Parse spec and build grammar
spec_file = "../spec_files/findidx_problem.sl"
grammar = build_grammar_from_spec_file(spec_file)

# Create oracle
oracle = Z3Oracle(spec_file, grammar)

# Run synthesis
result, _ = synth_with_oracle(grammar, :Expr, oracle; max_depth=6)

# Check result
if result.status == CEGIS.cegis_success
    expressions = rulenode2expr(result.program, grammar)
    println("Synthesized: $expressions")
end
```

### Example 2: Custom Parser

```julia
# Use SymbolicCandidateParser for mixed types
oracle = Z3Oracle(
    spec_file, grammar,
    parser=CEXGeneration.SymbolicCandidateParser()
)

result, _ = synth_with_oracle(grammar, :Expr, oracle)
```

### Example 3: Parameter Tuning

```julia
# Gradually increase search if needed
for depth in 3:6, enums in [5000, 10000, 50000]
    result, _ = synth_with_oracle(
        grammar, :Expr, oracle;
        max_depth=depth,
        max_enumerations=enums
    )
    
    if result.status == CEGIS.cegis_success
        println("Found at depth=$depth, enums=$enums")
        break
    end
end
```

---

## Error Handling

### Common Exceptions

```julia
try
    spec = CEXGeneration.parse_spec_from_file(filename)
catch ex
    if isa(ex, FileNotFoundError)
        println("Spec file not found")
    elseif isa(ex, SyntaxError)
        println("Invalid SyGuS syntax")
    else
        rethrow(ex)
    end
end
```

### Silent Failures

Most verification operations return `nothing` on error (conservative):
```julia
cex = extract_counterexample(oracle, candidate)
if cex !== nothing
    # ... handle counterexample ...
else
    # Either verified or error occurred
end
```

---

**Last Updated**: March 28, 2026
