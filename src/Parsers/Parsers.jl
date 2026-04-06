"""
    module Parsers

Specification parsers for CEGIS synthesis.

Provides abstract interface and concrete implementations for parsing different
specification formats (SyGuS, JSON, YAML, custom DSLs).
"""
module Parsers

using HerbCore

# Include abstract base type and implementations
include("AbstractParser.jl")

# Export public API
export
    AbstractSpecParser,
    SyGuSParser,
    parse_spec

end # module Parsers
