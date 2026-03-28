"""
Data structures for SyGuS specifications and synthesis problems.
"""

"""Synthesis function (synth-fun from SyGuS spec)."""
struct SynthFun
    name   :: String                                   # Function name
    params :: Vector{Tuple{String,String}}             # [(param_name, sort), ...]
    sort   :: String                                   # Return sort
end

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
end

"""Create a default empty Spec."""
Spec() = Spec("", "", SynthFun[], FreeVar[], String[])

