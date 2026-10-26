"""
Data structures for SyGuS specifications and synthesis problems.
"""

"""
Synthesis function (synth-fun from SyGuS spec).

`grammar` holds the optional SyGuS grammar section — the s-expression list of
non-terminal definitions `((Start Int (…)) (StartBool Bool (…)))` — exactly as
parsed, or `nothing` when the spec declares no grammar (in which case the
search space is unconstrained and callers fall back to
`build_grammar_from_spec`, which synthesizes one).

Keeping the raw form matters for literature comparison: the official SyGuS
benchmarks ship a *restricted* grammar (max4, for instance, allows only
`+ - ite` over `{x,y,z,w,0,1}` — no multiplication, no Bool→Int coercion), and
synthesizing our own instead changes the search problem.
"""
struct SynthFun
    name    :: String                                  # Function name
    params  :: Vector{Tuple{String,String}}            # [(param_name, sort), ...]
    sort    :: String                                  # Return sort
    grammar :: Union{Vector{Any},Nothing}              # SyGuS grammar section, if any
end

SynthFun(name::String, params::Vector{Tuple{String,String}}, sort::String) =
    SynthFun(name, params, sort, nothing)

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

