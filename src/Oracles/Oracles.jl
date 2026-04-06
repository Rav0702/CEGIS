"""
    Oracles.jl

Aggregator module for CEGIS oracle implementations.

This module collects all Oracle subtype implementations and exports them through
a unified interface. All concrete oracle implementations should subtype AbstractOracle
and implement the extract_counterexample method.

Included Oracle Implementations:
- AbstractOracle — Abstract base type and interface
- IOExampleOracle — Test-based oracle backed by I/O examples
- Z3Oracle — Z3 SMT solver-based oracle (requires CEXGeneration module)
"""

using HerbCore
using HerbGrammar
using HerbInterpret
using HerbSpecification

# Note: CEXGeneration should be available in parent module scope when this is included
# It's needed by Z3Oracle

# ── includes ─────────────────────────────────────────────────────────────────
include("abstract_oracle.jl")
include("ioexample_oracle.jl")
include("z3_oracle.jl")

# ── exports ──────────────────────────────────────────────────────────────────
export
    # Abstract type
    AbstractOracle,
    
    # Concrete oracle implementations
    IOExampleOracle,
    Z3Oracle,
    
    # Oracle interface
    extract_counterexample
