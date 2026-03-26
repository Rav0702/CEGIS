"""
CEXGeneration: Production-ready counterexample query generation for SyGuS specifications.

Converts SyGuS-v2 specifications and candidate solutions to SMT-LIB2 queries for verification.

# Main API
- `parse_spec_from_file(filename::String)::Spec` — Parse .sl file to specification object
- `generate_cex_query(spec::Spec, candidates::Dict{String,String})::String` — Generate SMT-LIB2 query
- `candidate_to_smt2(src::String)::String` — Convert infix candidate expr to SMT-LIB2 prefix

# Example Usage
    spec = parse_spec_from_file("problem.sl")
    query = generate_cex_query(spec, Dict("f" => "x"))
    write("/tmp/query.smt2", query)

# File Structure
- `types.jl` — Core data structures (Spec, SynthFun, FreeVar)
- `sexp.jl` — S-expression lexing, parsing, serialization
- `parser.jl` — SyGuS-v2 specification parser
- `candidates.jl` — Infix-to-prefix candidate expression parser
- `query.jl` — SMT-LIB2 query generation and variable substitution
"""

module CEXGeneration

export Spec, SynthFun, FreeVar, parse_spec_from_file, generate_cex_query,
       candidate_to_smt2, serialize_spec, deserialize_spec,
       verify_query, Z3Result, format_result

using Serialization, Z3

include("types.jl")
include("sexp.jl")
include("parser.jl")
include("candidates.jl")
include("query.jl")
include("z3_verify.jl")

"""
Parse a SyGuS-v2 specification file (.sl) to a Spec object.

Handles logical context, options, declarations, constraints, and synthesis targets.
Automatically expands inv-constraints to pre/trans/post safety properties.

# Arguments
- `filename::String` — Path to .sl specification file

# Returns
- `Spec` — Parsed specification with free variables, synthesis targets, and constraints
"""
parse_spec_from_file(filename::String)::Spec = parse_sl(filename)

"""
Generate a counterexample query for candidate solutions.

Substitutes candidate expressions for synthesis targets and builds an SMT-LIB2 query
to check satisfiability. Used for verification or counterexample discovery.

# Arguments
- `spec::Spec` — Specification from `parse_spec_from_file()`
- `candidates::Dict{String,String}` — Function name → candidate expression mapping.
  Candidates can be in infix or raw SMT-LIB2 syntax.

# Returns
- `String` — Complete SMT-LIB2 query (check-sat, get-model)

# Example
    candidates = Dict(
        "f" => "if x = 0 then 1 else x",
        "g" => "(+ x 1)"
    )
    query = generate_cex_query(spec, candidates)
"""
function generate_cex_query(sp::Spec, candidates::Dict{String,String})::String
    # Convert any infix expressions to SMT-LIB2 prefix
    smt_candidates = Dict{String,String}()
    for (name, expr) in candidates
        smt_candidates[name] = candidate_to_smt2(expr)
    end

    generate_query(sp, smt_candidates)
end

"""
Serialize a Spec object to a binary file.

# Arguments
- `spec::Spec` — Specification to serialize
- `filename::String` — Output file path
"""
serialize_spec(spec::Spec, filename::String) =
    open(io -> serialize(io, spec), filename, "w")

"""
Deserialize a Spec object from a binary file.

# Arguments
- `filename::String` — Input file path

# Returns
- `Spec` — Deserialized specification
"""
deserialize_spec(filename::String)::Spec =
    open(io -> deserialize(io), filename, "r")

end # module
