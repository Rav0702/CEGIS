"""
Z3 verification and counterexample extraction using Z3 Julia module.

Single-call approach:
  Query: Base query (set-logic, set-option, declarations + assertions + check-sat + get-value)
         → Single Z3 subprocess call that handles both sat/unsat checks and model extraction
         → For SAT: returns "sat" followed by model values
         → For UNSAT: returns "unsat" only (get-value output is ignored)
  
  This is more efficient than the previous two-call approach as Z3 only executes once.
"""

using Z3
using Logging

"""
Result of Z3 verification.
- status: :sat (counterexample found) or :unsat (valid)
- model: Dict mapping variable names to values
"""
struct Z3Result
    status :: Symbol  # :sat or :unsat
    model  :: Dict{String, Any}
end

"""
Run z3 binary on a query string, return stdout as a String.
Writes to a temp file to avoid shell quoting issues on Windows.
On error, returns "unsat" status to allow execution to continue.
"""
function _z3_run(query::String)::String
    tmp = tempname() * ".smt2"
    try
        @debug "Z3: Writing query to temp file" tmp
        write(tmp, query)
        @debug "Z3: Executing z3 subprocess"

        out = IOBuffer()
        err = IOBuffer()
        # ignorestatus: don't throw on non-zero exit code (Z3 exits 1 for unsat)
        proc = run(pipeline(ignorestatus(`z3 $tmp`); stdout=out, stderr=err); wait=true)
        result = strip(String(take!(out)))

        @debug "Z3: Subprocess completed" exit_code=proc.exitcode result_preview=first(result, 80)

        # Check result first—if it starts with unsat or sat, it's valid regardless of exit code
        if startswith(result, "unsat") || startswith(result, "sat")
            return result
        end

        # If exit code is non-zero and result doesn't start with unsat/sat, it's a real error
        if proc.exitcode != 0
            err_msg = strip(String(take!(err)))
            error("Z3 failed with exit code $(proc.exitcode):\n$err_msg\nStdout: $result")
        end

        return result
    catch e
        @debug "Z3: Unexpected Julia-level exception" exception=e
        rethrow()
    finally
        isfile(tmp) && rm(tmp)
    end
end

"""
Parse the output of a z3 get-value call into a Dict.

z3 prints one response block per (get-value ...) command:
  ((x 1)
   (y 0)
   (z 0))
  (((guard_fn x y z) 0))
  ((out_guard_fn 1))

Walks the output as nested s-expressions and collects every (key value) pair.
Keys are normalised strings so callers can look up "x" and "(guard_fn x y z)".
"""
function _parse_get_value_output(output::String)::Dict{String,Any}
    model = Dict{String,Any}()
    text  = replace(output, r";[^\n]*" => "")

    # Tokenise
    tokens = String[]
    i = 1; n = length(text)
    while i <= n
        c = text[i]
        if isspace(c); i += 1
        elseif c ∈ ('(', ')'); push!(tokens, string(c)); i += 1
        else
            j = i
            while j <= n && !isspace(text[j]) && text[j] ∉ ('(', ')'); j += 1; end
            push!(tokens, text[i:j-1]); i = j
        end
    end

    pos = Ref(1)
    while pos[] <= length(tokens)
        _collect_kv_pairs!(model, tokens, pos)
    end
    model
end

function _read_sexp_str(toks::Vector{String}, pos::Ref{Int})::String
    pos[] > length(toks) && return ""
    t = toks[pos[]]; pos[] += 1
    t != "(" && return t
    parts = String[]
    while pos[] <= length(toks) && toks[pos[]] != ")"
        push!(parts, _read_sexp_str(toks, pos))
    end
    pos[] <= length(toks) && (pos[] += 1)
    "(" * join(parts, " ") * ")"
end

function _collect_kv_pairs!(model::Dict{String,Any}, toks::Vector{String}, pos::Ref{Int})
    pos[] > length(toks) && return
    toks[pos[]] != "(" && (pos[] += 1; return)
    pos[] += 1  # consume '('

    children = String[]
    while pos[] <= length(toks) && toks[pos[]] != ")"
        push!(children, _read_sexp_str(toks, pos))
    end
    pos[] <= length(toks) && (pos[] += 1)  # consume ')'

    if length(children) == 2
        v = _parse_z3_numeral(children[2])
        if v !== nothing
            model[_norm_key(children[1])] = v
            return
        end
    end

    # Not a (key value) pair — recurse into child lists
    for child in children
        startswith(child, "(") || continue
        child_toks = _retokenise_str(child)
        child_pos  = Ref(1)
        !isempty(child_toks) && child_toks[1] == "(" &&
            _collect_kv_pairs!(model, child_toks, child_pos)
    end
end

function _retokenise_str(s::String)::Vector{String}
    toks = String[]
    i = 1; n = length(s)
    while i <= n
        c = s[i]
        if isspace(c); i += 1
        elseif c ∈ ('(', ')'); push!(toks, string(c)); i += 1
        else
            j = i
            while j <= n && !isspace(s[j]) && s[j] ∉ ('(', ')'); j += 1; end
            push!(toks, s[i:j-1]); i = j
        end
    end
    toks
end

function _parse_z3_numeral(s::String)::Union{Int,Nothing}
    s = strip(s)
    match(r"^-?\d+$", s) !== nothing && return parse(Int, s)
    m = match(r"^\(\s*-\s+(\d+)\s*\)$", s)
    m !== nothing && return -parse(Int, m[1])
    s == "true"  && return 1
    s == "false" && return 0
    nothing
end

_norm_key(s::String) = join(split(strip(s)), " ")

"""
Verify an SMT-LIB2 query string using a single z3 subprocess call.

Runs the complete query including check-sat and get-value in one call:
  - For SAT: returns "sat" followed by model values
  - For UNSAT: returns "unsat" only (get-value output is safely ignored by Z3)
  
Single Z3 call handles both satisfiability check and model extraction.

# Arguments
- `query::String` — SMT-LIB2 query string (set-logic, declare-const/fun, assert, check-sat, get-value)

# Returns
- `Z3Result` — Contains satisfiability status and model (if sat)
"""
function verify_query(query::String)::Z3Result
    # Run the full query (check-sat + get-value) in a single Z3 call
    # Z3 will return "unsat" (ignoring get-value) or "sat" with model values
    out = _z3_run(query)

    lines = [strip(line) for line in split(out, '\n') if !isempty(strip(line))]
    
    isempty(lines) && return Z3Result(:unknown, Dict())
    first_line = lines[1]

    # Handle unsat: Z3 just returns "unsat" and ignores get-value calls
    first_line == "unsat" && return Z3Result(:unsat, Dict())
    first_line != "sat"   && return Z3Result(:unknown, Dict())

    # SAT: extract model from get-value output (lines after "sat")
    if length(lines) > 1
        model_str = join(lines[2:end], '\n')
        model = _parse_get_value_output(model_str)
        return Z3Result(:sat, model)
    end

    return Z3Result(:sat, Dict())
end

"""
Format Z3Result for human-readable display.

Returns formatted string summarizing the verification result.
"""
function format_result(result::Z3Result, spec::Spec)::String
    lines = String[]

    if result.status == :sat
        push!(lines, " COUNTEREXAMPLE FOUND")
        push!(lines, "")
        push!(lines, "Free variable assignments:")
        for fv in spec.free_vars
            val = get(result.model, fv.name, "?")
            push!(lines, "  $(fv.name) = $val")
        end
        push!(lines, "")
        push!(lines, "Function values at counterexample:")
        for sfun in spec.synth_funs
            args = join([fv.name for fv in spec.free_vars], " ")
            key  = _norm_key("($(sfun.name) $args)")
            val  = get(result.model, key, "?")
            push!(lines, "  $(sfun.name)(...) = $val")
        end
    elseif result.status == :unsat
        push!(lines, "VALID CANDIDATE")
        push!(lines, "The candidate satisfies all constraints.")
    elseif result.status == :unknown
        push!(lines, " UNKNOWN")
        push!(lines, "Z3 could not determine satisfiability.")
    else
        push!(lines, "  ERROR")
        push!(lines, "Could not determine satisfiability.")
    end

    join(lines, "\n")
end