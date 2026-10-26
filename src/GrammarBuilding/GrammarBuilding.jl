"""
    module GrammarBuilding

Grammar configuration and building for CEGIS synthesis.

Provides declarative grammar configuration system with reusable operation sets,
automatic variable extraction from specs, and meta-programming grammar construction.
"""
module GrammarBuilding

using HerbCore
using HerbGrammar

# Sibling submodule: SyGuS spec parsing (grammar sections, s-expression helpers).
using ..CEXGeneration

# Import parent modules needed by included files
include("GrammarConfig.jl")
include("SygusGrammar.jl")

# Export public API
export
    # Configuration types
    GrammarConfig,
    
    # Operation sets (reusable)
    BASE_OPERATIONS,
    LIA_OPERATIONS,
    EXTENDED_OPERATIONS,
    STRING_OPERATIONS,
    BITVECTOR_OPERATIONS,
    
    # Main functions
    build_generic_grammar,
    eval_grammar_string,
    flatten_operations,
    generate_grammar_string,
    operation_arity,
    sygus_sort_to_julia_type,
    
    # Helper functions
    is_lia_problem,
    
    # SyGuS-declared grammars (for literature-comparable runs)
    build_grammar_from_sygus,
    build_grammar_auto,
    sygus_start_symbol,
    parse_sygus_grammar,
    SYGUS_OP_MAP,

    # Convenience functions
    default_grammar_config,
    lia_grammar_config,
    extended_grammar_config,
    string_grammar_config

end # module GrammarBuilding
