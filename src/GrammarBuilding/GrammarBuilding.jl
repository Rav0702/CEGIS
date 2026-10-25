"""
    module GrammarBuilding

Grammar configuration and building for CEGIS synthesis.

Provides declarative grammar configuration system with reusable operation sets,
automatic variable extraction from specs, and meta-programming grammar construction.
"""
module GrammarBuilding

using HerbCore
using HerbGrammar

# Import parent modules needed by included files
include("GrammarConfig.jl")
include("SyGuSGrammar.jl")   # per-problem grammars declared in the synth-fun body
include("RuleNodeRemap.jl")  # carrying programs between two problems' grammars

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

    # SyGuS synth-fun grammar bodies
    has_sygus_grammar,
    sygus_grammar_parts,
    sygus_grammar_to_csgrammar,
    build_grammar_from_synth_fun,

    # Cross-grammar program transfer
    remap_rulenode_by_expression,
    try_remap_rulenode,
    
    # Convenience functions
    default_grammar_config,
    lia_grammar_config,
    extended_grammar_config,
    string_grammar_config

end # module GrammarBuilding
