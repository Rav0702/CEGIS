"""
    constraint_pointwise.jl

Concrete-input ("pointwise") evaluation of SyGuS constraints — the interpreter
counterpart to the solver's ∀-quantified `check-sat-assuming`.

Given a constraint s-expression, a binding for the spec's free variables, and a
callback that applies the *candidate* program to concrete arguments, this
decides whether the constraint holds **at that one input**. No Z3 involved.

Why this exists: a per-constraint ∀-check yields one bit and (on violation) one
witness input. Re-checking that same witness against later candidates is the
cheap, graded signal the bit cannot give — a candidate can fix 3 of a
constraint's 5 known witnesses and be rewarded for it. Solver time is then
spent only on *discovering* witnesses and on final certification.

Every synth-fun application in the constraint is dispatched through `apply`, so
constraints that invoke `f` more than once (or at non-trivial argument
expressions, e.g. `(= (f x y) (f y x))`) evaluate correctly here — a case the
in-process ∀-solvers deliberately reject.

Unsupported syntax raises `PointwiseError`; callers treat that as "no signal"
rather than as a verdict.
"""

struct PointwiseError <: Exception
    msg::String
end
Base.showerror(io::IO, e::PointwiseError) = print(io, "PointwiseError: ", e.msg)

"""SMT-LIB `div`/`mod`: Euclidean, i.e. the remainder is always in `[0, |d|)`."""
function _pw_div(a::Integer, b::Integer)
    b == 0 && throw(PointwiseError("division by zero"))
    q = div(a, b)
    r = a - q * b
    return r < 0 ? (b > 0 ? q - 1 : q + 1) : q
end
_pw_mod(a::Integer, b::Integer) = a - _pw_div(a, b) * b

_pw_int(v) = v isa Integer ? v : throw(PointwiseError("expected Int, got $(typeof(v))"))
_pw_bool(v) = v isa Bool ? v : throw(PointwiseError("expected Bool, got $(typeof(v))"))

"""Resolve an atom: literal, `true`/`false`, or a bound variable."""
function _pw_atom(tok::AbstractString, vars::AbstractDict)
    tok == "true" && return true
    tok == "false" && return false
    n = tryparse(Int, tok)
    n === nothing || return n
    haskey(vars, tok) && return vars[tok]
    throw(PointwiseError("unbound symbol `$tok`"))
end

"""
    eval_constraint_pointwise(sexpr, synth_name, vars, apply) -> Bool

Evaluate `sexpr` (a parsed constraint, see `read_sexprs`) with the free
variables bound by `vars` (name → `Int`/`Bool`). Applications of `synth_name`
are delegated to `apply(argvalues::Vector{Any})`.

Throws `PointwiseError` on unsupported operators, arity errors, unbound
symbols, or a non-Boolean result.
"""
function eval_constraint_pointwise(sexpr, synth_name::AbstractString,
                                   vars::AbstractDict, apply)::Bool
    return _pw_bool(_pw_eval(sexpr, synth_name, vars, apply))
end

function _pw_eval(s, fname::AbstractString, vars::AbstractDict, apply)
    s isa AbstractString && return _pw_atom(s, vars)
    s isa Vector || throw(PointwiseError("malformed s-expression node $(typeof(s))"))
    isempty(s) && throw(PointwiseError("empty s-expression"))

    head = s[1]
    head isa AbstractString ||
        throw(PointwiseError("non-atomic operator position"))
    args = @view s[2:end]

    # Candidate application — evaluate arguments, then hand off.
    if head == fname
        return apply(Any[_pw_eval(a, fname, vars, apply) for a in args])
    end

    # `let` introduces shadowing bindings evaluated in the outer scope.
    if head == "let"
        length(args) == 2 || throw(PointwiseError("let expects bindings and a body"))
        binds = args[1]
        binds isa Vector || throw(PointwiseError("malformed let bindings"))
        inner = Dict{String,Any}(vars)
        for b in binds
            (b isa Vector && length(b) == 2 && b[1] isa AbstractString) ||
                throw(PointwiseError("malformed let binding"))
            inner[b[1]] = _pw_eval(b[2], fname, vars, apply)
        end
        return _pw_eval(args[2], fname, inner, apply)
    end

    ev(i) = _pw_eval(args[i], fname, vars, apply)
    n = length(args)

    # Short-circuiting connectives (also keeps guarded division safe).
    if head == "and"
        for i in 1:n; _pw_bool(ev(i)) || return false; end
        return true
    elseif head == "or"
        for i in 1:n; _pw_bool(ev(i)) && return true; end
        return false
    elseif head == "=>"
        n == 0 && throw(PointwiseError("=> needs arguments"))
        for i in 1:(n-1); _pw_bool(ev(i)) || return true; end
        return _pw_bool(ev(n))
    elseif head == "not"
        n == 1 || throw(PointwiseError("not/1 expected"))
        return !_pw_bool(ev(1))
    elseif head == "ite"
        n == 3 || throw(PointwiseError("ite/3 expected"))
        return _pw_bool(ev(1)) ? ev(2) : ev(3)
    end

    vals = Any[ev(i) for i in 1:n]

    if head == "-"
        n == 0 && throw(PointwiseError("-/0"))
        n == 1 && return -_pw_int(vals[1])
        return foldl((a, b) -> _pw_int(a) - _pw_int(b), vals)
    elseif head == "+"
        return foldl((a, b) -> _pw_int(a) + _pw_int(b), vals; init=0)
    elseif head == "*"
        return foldl((a, b) -> _pw_int(a) * _pw_int(b), vals; init=1)
    elseif head == "div"
        n == 2 || throw(PointwiseError("div/2 expected"))
        return _pw_div(_pw_int(vals[1]), _pw_int(vals[2]))
    elseif head == "mod"
        n == 2 || throw(PointwiseError("mod/2 expected"))
        return _pw_mod(_pw_int(vals[1]), _pw_int(vals[2]))
    elseif head == "abs"
        n == 1 || throw(PointwiseError("abs/1 expected"))
        return abs(_pw_int(vals[1]))
    elseif head == "="
        return all(v -> v == vals[1], vals)
    elseif head == "distinct"
        return allunique(vals)
    elseif head in ("<", "<=", ">", ">=")
        cmp = head == "<"  ? (<) : head == "<=" ? (<=) :
              head == ">"  ? (>) : (>=)
        for i in 1:(n-1)
            cmp(_pw_int(vals[i]), _pw_int(vals[i+1])) || return false
        end
        return true
    elseif head == "xor"
        return foldl((a, b) -> xor(_pw_bool(a), _pw_bool(b)), vals)
    end

    throw(PointwiseError("unsupported operator `$head`"))
end
