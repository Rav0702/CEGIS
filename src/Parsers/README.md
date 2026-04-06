# Parsers

Specification parser interface and implementations for various specification formats.

## Overview

The Parsers module provides an abstract interface for parsing synthesis problem specifications in different formats. This enables support for multiple specification formats (SyGuS, JSON, YAML, custom DSLs) without modifying core CEGIS code or creating coupling between format-specific parsers and synthesis logic.

## Key Components

- **AbstractParser.jl** — Abstract parser interface and default SyGuS parser implementation
- **Parsers.jl** — Module aggregator and public API

## Parser Interface

All concrete parsers must subtype `AbstractSpecParser` and implement:

```julia
parse_spec(parser::AbstractSpecParser, path::String) :: Spec
```

This method takes a file path and returns a fully-populated `Spec` object from the CEXGeneration module.

### Requirements for Implementations

- Parse specification file in appropriate format
- Validate specification completeness
- Provide specific, helpful error messages
- Return `Spec` object with all required fields populated

## Main Parser Types

### SyGuSParser (Default)
- **Format**: SyGuS-v2 (.sl files)
- **Supported logics**: LIA, QF_LIA, QF_BV, Arrays, Datatypes, etc.
- **Features**:
  - Parses logic declarations
  - Extracts synthesis functions and parameters
  - Collects free variables
  - Handles constraints, define-fun, define-funs-rec
  - Supports datatype and sort declarations
- **Return**: Fully-populated `Spec` object

## Parser Extension

Users can add support for new formats by implementing custom parsers:

```julia
# Define custom parser
struct JSONSpecParser <: AbstractSpecParser end

# Implement parse_spec interface
function parse_spec(::JSONSpecParser, path::String) :: Spec
    json_data = JSON.parsefile(path)
    # Convert JSON structure to Spec fields
    return Spec(
        file_path=path,
        logic=json_data["logic"],
        synth_funs=parse_synth_funs(json_data["functions"]),
        constraints=parse_constraints(json_data["constraints"]),
        # ... other fields
    )
end

# Use in synthesis
parser = JSONSpecParser()
spec = parse_spec(parser, "problem.json")
```

## Integration with CEGIS

Parsers are typically instantiated at problem initialization:

```julia
# Default SyGuS parser
problem = CEGISProblem("spec.sl")

# Custom parser
parser = JSONSpecParser()
spec = parse_spec(parser, "spec.json")
problem = CEGISProblem(spec)
```

## Key API

- `AbstractSpecParser` — Base type for all specification parsers
- `parse_spec(parser, path)` — Parse specification file
- `SyGuSParser` — Default SyGuS-v2 format parser

## Design Notes

- **Strategy pattern** — Different parsers for different formats without code duplication
- **Extensibility** — New formats supported by adding new parser subtypes
- **Format independence** — CEGIS core logic independent of specification format
- **Error handling** — Specific parse errors with helpful diagnostic messages
- **Specification normalization** — Converts different formats to uniform `Spec` representation
