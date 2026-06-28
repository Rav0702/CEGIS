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
- unsat_core: Vector of assertion labels that form the unsatisfiable core (when UNSAT)
- violated_constraints: 1-based indices (into `spec.constraints`) of the constraints
  the candidate violates *at the counterexample point* (only populated when SAT)
"""
struct Z3Result
    status :: Symbol  # :sat or :unsat
    model  :: Dict{String, Any}
    unsat_core :: Vector{String}
    violated_constraints :: Vector{Int}
end

# Back-compat constructor: callers that don't supply per-constraint attribution.
# Untyped args so the 4-arg converting constructor handles e.g. an empty `Dict()`.
Z3Result(status, model, unsat_core) = Z3Result(status, model, unsat_core, Int[])

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

        @debug "Z3: Subprocess completed" exit_code=proc.exitcode result_preview=first(result, min(length(result), 80))

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

# ── In-process Z3 backend ───────────────────────────────────────────────────────
#
# `Z3_eval_smtlib2_string(ctx, query)` runs the *same* SMT-LIB2 string in-process
# and returns the *same* text the `z3` binary prints — so the parsers below are
# reused verbatim. Two things matter for it to behave like the binary:
#
#   1. A no-op error handler. With the default handler, any SMT error mid-script
#      (notably `get-value` after an `unsat` `check-sat`) aborts the *process*.
#      With a no-op handler Z3 instead continues and *returns* the output, leaving
#      a harmless `(error "...")` line inline (which the parsers already skip).
#   2. A fresh context per call. Reusing a context accumulates assertions and
#      re-runs `set-logic`, which errors and corrupts results — so each query gets
#      its own context (its logic is set exactly once).
#
# Z3.jl's `Z3_set_error_handler` wrapper is mistyped (`Z3_error_handler = Cvoid`),
# so the handler pointer is installed via a raw `ccall`.

_z3_noop_error_handler(c::Z3.Libz3.Z3_context, e::UInt32)::Cvoid = nothing
const _Z3_ERR_HANDLER = @cfunction(_z3_noop_error_handler, Cvoid, (Z3.Libz3.Z3_context, UInt32))

"""
Run an SMT-LIB2 query string through Z3 in-process (no subprocess, no temp file).
Returns Z3's output text in the same format as `_z3_run`.
"""
function _z3_eval(query::String)::String
    cfg = Z3.Libz3.Z3_mk_config()
    ctx = Z3.Libz3.Z3_mk_context(cfg)
    try
        # Bypass the mistyped wrapper: pass the @cfunction pointer as Ptr{Cvoid}.
        ccall((:Z3_set_error_handler, Z3.Libz3.libz3), Cvoid,
              (Z3.Libz3.Z3_context, Ptr{Cvoid}), ctx, _Z3_ERR_HANDLER)
        # Copy into a Julia String before the context (which owns the buffer) is freed.
        return strip(unsafe_string(Z3.Libz3.Z3_eval_smtlib2_string(ctx, query)))
    finally
        Z3.Libz3.Z3_del_context(ctx)
        Z3.Libz3.Z3_del_config(cfg)
    end
end

"""
Dispatch a query to the Z3 backend: in-process (`_z3_eval`) by default, or the
`z3` subprocess (`_z3_run`) when `CEGIS_Z3_SUBPROCESS=1`. Both return Z3's output
text in the same format, so callers/parsers are backend-agnostic.
"""
_z3_solve(query::String)::String =
    get(ENV, "CEGIS_Z3_SUBPROCESS", "0") == "1" ? _z3_run(query) : _z3_eval(query)

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
Pop the per-constraint indicator entries (`cand_c_<idx>`) out of a parsed model and
return the 1-based indices of the constraints the candidate violates (indicator
`false`/`0`). Removing them keeps `model` limited to free-var / function values for
downstream consumers.
"""
function _extract_violated_constraints!(model::Dict{String,Any})::Vector{Int}
    violated = Int[]
    for key in collect(keys(model))
        m = match(r"^cand_c_(\d+)$", key)
        m === nothing && continue
        val = pop!(model, key)
        val == 0 && push!(violated, parse(Int, m[1]))
    end
    return sort!(violated)
end

"""
Parse the output of a z3 get-unsat-core call.

Z3 prints the unsat core as a list of assertion labels:
  (spec_max3_1 spec_max3_2 candidate_check)

Followed by optional error messages. Returns a Vector{String} of the label names.
"""
function _parse_unsat_core(output::String)::Vector{String}
    output = strip(output)
    
    # Remove comments
    output = replace(output, r";[^\n]*" => "")
    
    # Extract the first complete S-expression (which is the core)
    # Find matching parentheses for the first '('
    if isempty(output) || !startswith(output, "(")
        return String[]
    end
    
    paren_depth = 0
    end_pos = 0
    
    for (i, c) in enumerate(output)
        if c == '('
            paren_depth += 1
        elseif c == ')'
            paren_depth -= 1
            if paren_depth == 0
                end_pos = i
                break
            end
        end
    end
    
    if end_pos == 0
        return String[]
    end
    
    # Extract content between the matching parentheses
    core_expr = strip(output[2:end_pos-1])
    
    # Split by whitespace and filter empty strings
    labels = filter(!isempty, split(core_expr))
    return labels
end


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
    # Run the full query (check-sat + get-value + get-unsat-core) in a single Z3 call
    # Z3 will return "unsat" with unsat core or "sat" with model values
    out = _z3_solve(query)

    lines = [strip(line) for line in split(out, '\n') if !isempty(strip(line))]
    
    isempty(lines) && return Z3Result(:unknown, Dict(), String[])
    first_line = lines[1]

    # Handle unsat: Z3 returns "unsat" followed by get-unsat-core output
    if first_line == "unsat"
        unsat_core = String[]
        if length(lines) > 1
            # Parse unsat core from remaining lines
            core_str = join(lines[2:end], '\n')
            unsat_core = _parse_unsat_core(core_str)
        end
        return Z3Result(:unsat, Dict(), unsat_core)
    end
    
    if first_line != "sat"
        return Z3Result(:unknown, Dict(), String[])
    end

    # SAT: extract model from get-value output (lines after "sat")
    if length(lines) > 1
        model_str = join(lines[2:end], '\n')
        model = _parse_get_value_output(model_str)
        violated = _extract_violated_constraints!(model)
        return Z3Result(:sat, model, String[], violated)
    end

    return Z3Result(:sat, Dict(), String[], Int[])
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
        if !isempty(result.violated_constraints)
            push!(lines, "")
            push!(lines, "Constraints violated at this counterexample (1-based index):")
            for idx in result.violated_constraints
                push!(lines, "  - constraint $idx: $(spec.constraints[idx])")
            end
        end
    elseif result.status == :unsat
        push!(lines, "VALID CANDIDATE")
        push!(lines, "The candidate satisfies all constraints.")
        push!(lines, "")
        if !isempty(result.unsat_core)
            push!(lines, "Unsatisfiable Core (minimal constraints that imply validity):")
            for label in result.unsat_core
                push!(lines, "  - $label")
            end
        end
    elseif result.status == :unknown
        push!(lines, " UNKNOWN")
        push!(lines, "Z3 could not determine satisfiability.")
    else
        push!(lines, "  ERROR")
        push!(lines, "Could not determine satisfiability.")
    end

    join(lines, "\n")
end