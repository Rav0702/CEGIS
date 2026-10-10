"""
Data structures for SyGuS specifications and synthesis problems.
"""

"""
Synthesis function (synth-fun from SyGuS spec).

`grammar_sexp` holds the optional grammar body of the `synth-fun` command — the raw
s-expression `(<nonterminal-decls> <production-groups>)`, as read by `read_sexprs`.
It is empty for the (common) grammar-free form `(synth-fun f ((x Int)) Int)`, in which
case the search grammar is derived from the logic by `GrammarBuilding.GrammarConfig`.
See `GrammarBuilding.sygus_grammar_to_csgrammar` for the translation.
"""
struct SynthFun
    name   :: String                                   # Function name
    params :: Vector{Tuple{String,String}}             # [(param_name, sort), ...]
    sort   :: String                                   # Return sort
    grammar_sexp :: Vector{Any}                        # Grammar body, or empty if none
end

SynthFun(name, params, sort) = SynthFun(name, params, sort, Any[])

"""Free variable or input parameter (declare-var)."""
struct FreeVar
    name :: String
    sort :: String
end

"""Complete parsed SyGuS specification."""
mutable struct Spec
    file_path   :: String                              # Path to the .sl file
    logic       :: String                              # "LIA", "QF_LIA", etc.
    synth_funs  :: Vector{SynthFun}                    # Functions to synthesize
    free_vars   :: Vector{FreeVar}                     # Free variables (declare-var)
    constraints :: Vector{String}                      # Constraints as SMT-LIB2 strings
    define_funs :: Vector{String}                      # Helper functions (define-fun statements)
    define_funs_rec :: Vector{String}                  # Recursive functions (define-funs-rec statements)
    fun_decls   :: Vector{String}                      # Uninterpreted functions (declare-fun with arity > 0)
    sort_decls  :: Vector{String}                      # Sort declarations (declare-sort, define-sort)
    datatypes   :: Vector{String}                      # Datatype declarations (declare-datatypes, declare-datatype)
    ordered_preamble :: Vector{String}                 # All preamble items in source order (for Z3 query generation)
end

"""Create a default empty Spec."""
Spec() = Spec("", "", SynthFun[], FreeVar[], String[], String[], String[], String[], String[], String[], String[])

