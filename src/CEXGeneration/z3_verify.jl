"""
Z3 verification and counterexample extraction using Z3 Julia module.

Two-call approach:
  Query 1: Base query (set-logic, set-option, declarations + assertions + check-sat)
           → determine sat/unsat only, no model extraction
  Query 2: Full query (base + get-value lines), only run when Query 1 is sat
           → z3 binary handles get-value natively, returning all values including
             model-completed unconstrained variables (e.g. `y` when candidate is `z`)
"""

using Z3

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
"""
function _z3_run(query::String)::String
    tmp = tempname() * ".smt2"
    try
        write(tmp, query)
        return readchomp(`z3 $tmp`)
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
Verify an SMT-LIB2 query string using two z3 subprocess calls.

Query 1: Run base query (declarations + assertions) with check-sat only
         → determine satisfiability without model extraction overhead

Query 2: If sat, run the complete query with (get-value ...) lines
         → extract complete model with all variables forced to values via
           z3's native get-value + model completion

# Arguments
- `query::String` — SMT-LIB2 query string (set-logic, declare-const/fun, assert, check-sat, get-value)

# Returns
- `Z3Result` — Contains satisfiability status and model (if sat)
"""
function verify_query(query::String)::Z3Result
    # Split query into base (up to check-sat) and get-value lines
    lines = split(query, '\n')
    check_sat_idx = findfirst(line -> strip(line) == "(check-sat)", lines)

    if check_sat_idx === nothing
        return Z3Result(:unknown, Dict())
    end

    query_base     = join(lines[1:check_sat_idx], "\n")
    get_value_lines = lines[check_sat_idx+1:end]
    query_full     = query_base * "\n" * join(get_value_lines, "\n")

    # ─────────────────────────────────────────────────────────────────────────
    # Query 1: Just check-sat (no get-value overhead)
    # ─────────────────────────────────────────────────────────────────────────
    out1 = try
        _z3_run(query_base)
    catch e
        return Z3Result(:unknown, Dict())
    end

    first_line = strip(split(out1, '\n')[1])
    first_line == "unsat" && return Z3Result(:unsat, Dict())
    first_line != "sat"   && return Z3Result(:unknown, Dict())

    # ─────────────────────────────────────────────────────────────────────────
    # Query 2: Full query with get-value (only if Query 1 was sat)
    # ─────────────────────────────────────────────────────────────────────────
    isempty(strip(join(get_value_lines, "\n"))) && return Z3Result(:sat, Dict())

    out2 = try
        _z3_run(query_full)
    catch e
        return Z3Result(:sat, Dict())   # sat confirmed, model unavailable
    end

    lines2    = split(out2, '\n')
    model_str = join(lines2[2:end], '\n')   # skip the leading "sat" line
    model     = _parse_get_value_output(model_str)

    return Z3Result(:sat, model)
end

"""
Format Z3Result for human-readable display.

Returns formatted string summarizing the verification result.
"""
function format_result(result::Z3Result, spec::Spec)::String
    lines = String[]

    if result.status == :sat
        push!(lines, "❌ COUNTEREXAMPLE FOUND")
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
        push!(lines, "✅ VALID CANDIDATE")
        push!(lines, "The candidate satisfies all constraints.")
    elseif result.status == :unknown
        push!(lines, "⚠️  UNKNOWN")
        push!(lines, "Z3 could not determine satisfiability.")
    else
        push!(lines, "⚠️  ERROR")
        push!(lines, "Could not determine satisfiability.")
    end

    join(lines, "\n")
end