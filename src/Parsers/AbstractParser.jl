"""
    Parsers/AbstractParser.jl

Abstract interface for specification parser plugins. Enables support for multiple spec
formats (SyGuS, JSON, YAML, custom DSLs) without modifying core CEGIS code.

## Usage

```julia
# Default SyGuS parser
parser = SyGuSParser()
spec = parse_spec(parser, "benchmark.sl")

# User extension: JSON parser
struct JSONSpecParser <: AbstractSpecParser end

function parse_spec(::JSONSpecParser, path::String) :: Spec
    json_data = JSON.parsefile(path)
    # Convert JSON to Spec type
    return Spec(...)
end

# Use it
problem = CEGISProblem("spec.json"; spec_parser=JSONSpecParser())
```
"""

using CEGIS.CEXGeneration: Spec

# ─────────────────────────────────────────────────────────────────────────────
# Abstract interface
# ─────────────────────────────────────────────────────────────────────────────

"""
    abstract type AbstractSpecParser

Base type for specification format parsers. A parser converts a specification file
(in any format) into a CEGIS `Spec` object.

Subtypes must implement:
- `parse_spec(parser::YourParser, path::String)::Spec`

## Design rationale

- **Single responsibility**: Each parser handles exactly one format
- **Extensibility**: Users extend by creating new subtypes, not modifying existing code
- **Type safety**: Dispatch on parser type ensures correct parsing logic
"""
abstract type AbstractSpecParser end

"""
    parse_spec(parser::AbstractSpecParser, path::String) :: Spec

Parse a specification file in the format handled by `parser`.

**Arguments**:
- `parser`: Instance of a concrete `AbstractSpecParser` subtype
- `path`: Path to specification file

**Returns**:
- `Spec`: A fully-populated CEGIS specification object (from `CEXGeneration` module)

**Throws**:
- `IOError` if file cannot be read
- `ParseError` if file format is invalid or specification is incomplete

**Implementation notes**:
- Parser should validate the spec before returning (check for required fields)
- Error messages should be specific (e.g., "Missing logic declaration" not "Parse failed")
"""
function parse_spec(parser::AbstractSpecParser, path::String)
    error("parse_spec not implemented for $(typeof(parser))")
end

# ─────────────────────────────────────────────────────────────────────────────
# SyGuS Format Parser (default)
# ─────────────────────────────────────────────────────────────────────────────

"""
    struct SyGuSParser <: AbstractSpecParser

Parser for SyGuS-v2 format specifications (`.sl` files).

Delegates to `CEGIS.CEXGeneration.parse_spec_from_file()` for actual parsing.

**Supported features**:
- All SyGuS-v2 commands: `set-logic`, `declare-var`, `synth-fun`, `constraint`
- Logics: LIA, NIA, BV, SLIA (where CEXGeneration provides support)
- Recursive grammars in `synth-fun` bodies

**Example**:
```julia
parser = SyGuSParser()
spec = parse_spec(parser, "max.sl")
```
"""
struct SyGuSParser <: AbstractSpecParser end

"""
    parse_spec(parser::SyGuSParser, path::String) :: Spec

Parse a SyGuS specification file using CEXGeneration's parser.

**Arguments**:
- `path`: Path to `.sl` file (SyGuS-v2 format)

**Returns**:
- `Spec` with populated logic, synth_funs, free_vars, and constraints

**Example**:
```julia
spec = parse_spec(SyGuSParser(), "benchmarks/max.sl")
# Returns: Spec("LIA", [SynthFun("max", ...)], [FreeVar("x", "Int"), ...], [...])
```
"""
function parse_spec(::SyGuSParser, path::String)
    # Delegate to CEXGeneration's existing SyGuS parser
    # Access CEXGeneration through Main which has the fully constructed CEGIS module
    cexgen = getfield(Main, :CEGIS) |> m -> getfield(m, :CEXGeneration)
    return cexgen.parse_spec_from_file(path)
end
