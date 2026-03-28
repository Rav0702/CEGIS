# SymbolicSMT.jl Code Analysis: Uninterpreted Function Support

## Overview
This document contains the relevant code snippets from the SymbolicSMT ecosystem showing:
1. How symbolic expressions are converted to Z3 terms
2. Where uninterpreted functions are currently failing
3. Type definitions and dispatch patterns
4. Existing error handling

---

## 1. CORE Z3 CONVERSION: `to_z3()` Function
**File**: `SymbolicSMT/src/SymbolicSMT.jl` (lines 8-70)

### Main Entry Point
```julia
function to_z3(term, ctx)
    # Julia literals
    if term isa Bool
        return BoolVal(term, ctx)
    elseif term isa Integer
        return IntVal(term, ctx)
    elseif term isa AbstractFloat
        return Float64Val(term, ctx)
    elseif term isa Rational
        return Float64Val(Float64(term), ctx)
    end

    if term isa BasicSymbolic
        return to_z3(term::BasicSymbolic, ctx)
    end

    error("Unsupported type in to_z3: $(typeof(term))")
end
```

### BasicSymbolic Dispatcher
```julia
function to_z3(x::BasicSymbolic, ctx)
    xu = try
        unwrap_const(x)
    catch
        x
    end
    if xu !== x
        return to_z3(xu, ctx)
    end

    # treat any non-call symbolic as atom
    if !iscall(x)
        t = symtype(x)
        nm = string(x)
        if t <: Bool
            return BoolVar(nm, ctx)
        elseif t <: Integer
            return IntVar(nm, ctx)
        else
            return _z3_real_var(nm, ctx)
        end
    end

    return to_z3_tree(x, ctx)
end
```

### Tree Conversion with Operation Dispatch
```julia
function to_z3_tree(term, ctx)
    # literals
    if term isa Bool || term isa Integer || term isa AbstractFloat || term isa Rational
        return to_z3(term, ctx)
    end

    # symbolic atoms MUST terminate here
    if term isa BasicSymbolic
        if !iscall(term)
            # ... atom handling ...
        end

        op = operation(term)                          # <-- GETS THE OPERATOR
        args = collect(arguments(term))               # <-- GETS THE ARGUMENTS

        # recursion guard for malformed/self-referential terms
        if isempty(args) || (length(args) == 1 && args[1] === term)
            # ... fallback to atom ...
        end

        zargs = map(a -> to_z3(a, ctx), args)        # <-- RECURSIVELY CONVERTS ARGS
        name = _opname(op)                           # <-- CONVERTS OPERATOR TO STRING

        # OPERATOR DISPATCH - Pattern for all supported operations:
        if name in ("!", "~", "not")
            return _z3_not(zargs[1], ctx)
        elseif name in ("&", "&&", "and")
            return _z3_and(ctx, zargs)
        elseif name in ("|", "||", "or")
            return _z3_or(ctx, zargs)
        elseif name in ("=>", "implies")
            return _z3_or(ctx, [_z3_not(zargs[1], ctx), zargs[2]])
        elseif name == "=="
            return _z3_eq(zargs[1], zargs[2], ctx)
        elseif name in ("!=", "distinct")
            return _z3_distinct(ctx, zargs)
        elseif name == "<"
            return _z3_lt(zargs[1], zargs[2], ctx)
        elseif name == "<="
            return _z3_le(zargs[1], zargs[2], ctx)
        elseif name == ">"
            return _z3_gt(zargs[1], zargs[2], ctx)
        elseif name == ">="
            return _z3_ge(zargs[1], zargs[2], ctx)
        elseif name == "+"
            out = zargs[1]
            for i in 2:length(zargs)
                out = out + zargs[i]
            end
            return out
        elseif name == "-"
            if length(zargs) == 1; return -zargs[1]; end
            out = zargs[1]
            for i in 2:length(zargs); out = out - zargs[i]; end
            return out
        elseif name == "*"
            out = zargs[1]
            for i in 2:length(zargs); out = out * zargs[i]; end
            return out
        elseif name == "/"
            return zargs[1] / zargs[2]
        elseif name == "^"
            return zargs[1] ^ zargs[2]
        elseif name in ("mod", "rem")
            return zargs[1] % zargs[2]
        elseif name in ("ifelse", "ite")
            return _z3_ite(zargs[1], zargs[2], zargs[3], ctx)
        end

        error("Unsupported symbolic operation in to_z3_tree: $(name)")  # <-- ERROR HERE!
    end

    error("Unsupported non-symbolic term in to_z3_tree: $(typeof(term))")
end
```

---

## 2. S-EXPRESSION PARSING: `_sexpr_to_symbolic()` Function
**File**: `CEGIS/semantic_smt_oracle.jl` (lines 62-130)

### Helper Functions (Tokenization & Parsing)
```julia
function _tokenize_sexpr(s::AbstractString)
    t = replace(s, "(" => " ( ", ")" => " ) ")
    return String.(split(t))
end

function _parse_sexpr(tokens::AbstractVector{<:AbstractString}, i::Int=1)
    i > length(tokens) && error("Unexpected end of S-expression")
    tok = String(tokens[i])
    if tok == "("
        items = Any[]
        i += 1
        while i <= length(tokens) && String(tokens[i]) != ")"
            node, i = _parse_sexpr(tokens, i)
            push!(items, node)
        end
        i > length(tokens) && error("Missing ')' in S-expression")
        return items, i + 1
    elseif tok == ")"
        error("Unexpected ')' in S-expression")
    else
        return tok, i + 1
    end
end

function _atom_to_symbolic(tok::String, sym_vars::Dict{Symbol,Any})
    t = strip(tok)
    tl = lowercase(t)
    tl == "true" && return true
    tl == "false" && return false
    try return parse(Int, t) catch end
    try return parse(Float64, t) catch end
    s = Symbol(t)
    return get(sym_vars, s, s)
end
```

### Main S-Expression to Symbolic Conversion
```julia
function _sexpr_to_symbolic(node, sym_vars::Dict{Symbol,Any})
    if node isa String
        return _atom_to_symbolic(node, sym_vars)
    end
    node isa Vector || error("Invalid S-expression node: $node")
    isempty(node) && error("Empty S-expression list")

    op = lowercase(String(node[1]))                    # <-- EXTRACT OPERATOR
    args = [_sexpr_to_symbolic(a, sym_vars) for a in node[2:end]]  # <-- RECURSIVE

    # OPERATOR DISPATCH - Pattern for ALL supported SMT-LIB operators:
    if op == "and"
        out = args[1]; for i in 2:length(args); out = out & args[i]; end; return out
    elseif op == "or"
        out = args[1]; for i in 2:length(args); out = out | args[i]; end; return out
    elseif op == "not"
        return !args[1]
    elseif op in ("=>", "implies")
        return (!args[1]) | args[2]
    elseif op in ("=", "==")
        return args[1] == args[2]
    elseif op in ("distinct", "!=")
        return args[1] != args[2]
    elseif op == "<"
        return args[1] < args[2]
    elseif op == "<="
        return args[1] <= args[2]
    elseif op == ">"
        return args[1] > args[2]
    elseif op == ">="
        return args[1] >= args[2]
    elseif op == "+"
        out = args[1]; for i in 2:length(args); out = out + args[i]; end; return out
    elseif op == "-"
        if length(args) == 1; return -args[1]; end
        out = args[1]; for i in 2:length(args); out = out - args[i]; end; return out
    elseif op == "*"
        out = args[1]; for i in 2:length(args); out = out * args[i]; end; return out
    elseif op == "/"
        return args[1] / args[2]
    elseif op == "ite"
        return ifelse(args[1], args[2], args[3])
    end
    error("Unsupported SMT-LIB operator in constraint string: $op")  # <-- ERROR!
end

function _parse_smtlib_string(s::AbstractString, sym_vars::Dict{Symbol,Any})
    tokens = _tokenize_sexpr(s)
    node, idx = _parse_sexpr(tokens, 1)
    idx <= length(tokens) && error("Trailing tokens in S-expression: $(tokens[idx:end])")
    return _sexpr_to_symbolic(node, sym_vars)
end
```

---

## 3. UNINTERPRETED FUNCTION SUPPORT (Partial Implementation)
**File**: `CEGIS/semantic_smt_oracle_declared_fun.jl` (lines 22-80)

### Extended Parser with Declared Functions
```julia
# Override the _sexpr_to_symbolic function to handle declared functions
function _sexpr_to_symbolic_with_declared(
    node, 
    sym_vars::Dict{Symbol,Any}, 
    declared_funs::Dict{String,Any}=Dict()
)
    if node isa String
        return _atom_to_symbolic(node, sym_vars)
    end
    node isa Vector || error("Invalid S-expression node: $node")
    isempty(node) && error("Empty S-expression list")

    op = lowercase(String(node[1]))
    args = [_sexpr_to_symbolic_with_declared(a, sym_vars, declared_funs) for a in node[2:end]]

    # ... (all standard operators handled same as before) ...

    elseif haskey(declared_funs, op)
        # Handle uninterpreted function - return a symbolic term
        # We'll represent it as a function call: op(arg1, arg2, ...)
        # For Z3 interaction, this will be passed as-is
        return build_symbolic_call(Symbol(op), args)
    end
    error("Unsupported SMT-LIB operator in constraint string: $op")
end

function _parse_smtlib_string_with_declared(
    s::AbstractString, 
    sym_vars::Dict{Symbol,Any}, 
    declared_funs::Dict{String,Any}
)
    tokens = _tokenize_sexpr(s)
    node, idx = _parse_sexpr(tokens, 1)
    idx <= length(tokens) && error("Trailing tokens in S-expression: $(tokens[idx:end])")
    return _sexpr_to_symbolic_with_declared(node, sym_vars, declared_funs)
end

function build_symbolic_call(func_symbol::Symbol, args::Vector)
    if isempty(args)
        return func_symbol
    end
    # Use SymbolicUtils to create a function call
    return func_symbol(args...)
end
```

---

## 4. TYPE DEFINITIONS: `SMTSpec` Structure
**File**: `CEGIS/parse_sygus.jl` (lines 1-28)

```julia
"""
    SMTSpec

Represents a parsed SyGuS specification.

Fields:
- vars::Vector{Symbol}: Declared variables
- constraints::Vector{NamedTuple}: Each constraint has:
  - lhs: Left-hand side of implication (the precondition)
  - rhs_out: Expected output value (can be integer or S-expression string)
- functions::Dict{String, NamedTuple}: Defined functions (define-fun); each has:
  - params::Vector{Symbol}: Parameter names
  - param_types::Vector{String}: Parameter types
  - return_type::String: Return type
  - body::String: Function body as S-expression string
- declared_functions::Dict{String, NamedTuple}: Declared functions (declare-fun); each has:
  - param_types::Vector{String}: Parameter types
  - return_type::String: Return type
  - body::String: Empty string (uninterpreted)
"""
struct SMTSpec
    vars::Vector{Symbol}
    constraints::Vector{NamedTuple}
    functions::Dict{String, NamedTuple}
    declared_functions::Dict{String, NamedTuple}
end
```

### Parsing Declared Functions
```julia
"""
    extract_declare_fun(content::String)

Extract all (declare-fun ...) declarations from SyGuS file content.

Returns a Dict mapping function names to their signatures.
Each signature is a NamedTuple with:
- param_types::Vector{String}: Parameter types
- return_type::String: Return type
- body::String: Empty string (uninterpreted)
"""
function extract_declare_fun(content::String)
    declared = Dict{String, NamedTuple}()
    
    # Pattern: (declare-fun name (Type1 Type2 ...) ReturnType)
    # Note: declare-fun does NOT have parameter names, just types
    
    lines = split(content, "\n")
    for line in lines
        line = strip(line)
        
        if startswith(line, "(declare-fun")
            try
                parse_declare_fun_line(String(line), declared)
            catch e
                # Silently skip malformed declare-fun lines
                @warn "Skipped malformed declare-fun declaration"
            end
        end
    end
    
    return declared
end

"""
    parse_declare_fun_line(line::String, declared::Dict)

Parse a single (declare-fun ...) declaration and add to declared dict.
"""
function parse_declare_fun_line(line::String, declared::Dict)
    # Pattern: (declare-fun name (Type1 Type2 ...) ReturnType)
    
    # Extract name
    name_match = match(r"\(declare-fun\s+(\w+)\s+", line)
    if name_match === nothing
        return
    end
    name = name_match.captures[1]
    
    # Find the parameter types section: (Type1 Type2 ...)
    offset_after_name = name_match.offset + length(name_match.match)
    next_paren_range = findnext("(", line, offset_after_name)
    if next_paren_range === nothing
        return
    end
    
    start_pos = next_paren_range[1]
    
    # Find matching closing paren
    paren_count = 0
    end_pos = start_pos
    
    while end_pos <= length(line)
        if line[end_pos] == '('
            paren_count += 1
        elseif line[end_pos] == ')'
            paren_count -= 1
            if paren_count == 0
                break
            end
        end
        end_pos += 1
    end
    
    # Extract parameter types: everything between ( and )
    params_section = line[start_pos+1:end_pos-1]
    
    # Parse parameter types (space-separated)
    param_types = String[]
    if !isempty(strip(params_section))
        param_types = String.(split(strip(params_section)))
    end
    
    # Find return type: it comes right after ) Type)
    rest_after_params = line[end_pos+1:end]
    return_type_match = match(r"^\s+(\w+)\s*\)", rest_after_params)
    if return_type_match === nothing
        return
    end
    return_type = return_type_match.captures[1]
    
    # Store the function declaration (no body for uninterpreted functions)
    declared[name] = (
        param_types=param_types,
        return_type=return_type,
        body=""
    )
end
```

---

## 5. DISPATCH PATTERNS & ARCHITECTURE

### Current Pattern for Standard Operations
The code follows a consistent pattern across both `to_z3()` and `_sexpr_to_symbolic()`:

```julia
# Step 1: Extract operator name (string form)
name = _opname(op)  # or: op = lowercase(String(node[1]))

# Step 2: Recursively convert arguments
zargs = map(a -> to_z3(a, ctx), args)  # or: args = [_sexpr_to_symbolic(...) for a in ...]

# Step 3: Operator-based dispatch using if-elseif chains
if name in ("!", "~", "not")
    # Handle operation
elseif name in ("&", "&&", "and")
    # Handle operation
# ... many more patterns ...
else
    error("Unsupported operator: $op")  # <-- ERROR POINT
end
```

### Key Traits
1. **Operator Dispatch**: Both functions use string-based if-elseif chains
2. **Recursive Conversion**: Arguments are converted first, then combined
3. **Group Variations**: Multiple operator names map to same semantics (e.g., "!" ≈ "~" ≈ "not")
4. **Error Handling**: Explicit `error()` call when operator is unknown
5. **Type Handling**: Distinguishes between literals, atoms, and tree structures

---

## 6. Z3 HELPER FUNCTIONS
**File**: `SymbolicSMT/src/SymbolicSMT.jl` (lines 188-242)

```julia
# Low-level Z3 C API wrappers
function _z3_not(arg, ctx)
    res = Z3.Libz3.Z3_mk_not(ctx.ctx, arg.expr)
    return Z3.Expr(ctx, res)
end

function _z3_and(ctx, args)
    expr_ptrs = [arg.expr for arg in args]
    res = Z3.Libz3.Z3_mk_and(ctx.ctx, length(expr_ptrs), expr_ptrs)
    return Z3.Expr(ctx, res)
end

function _z3_or(ctx, args)
    expr_ptrs = [arg.expr for arg in args]
    res = Z3.Libz3.Z3_mk_or(ctx.ctx, length(expr_ptrs), expr_ptrs)
    return Z3.Expr(ctx, res)
end

function _z3_eq(a, b, ctx)
    res = Z3.Libz3.Z3_mk_eq(ctx.ctx, a.expr, b.expr)
    return Z3.Expr(ctx, res)
end

function _z3_lt(a, b, ctx)
    res = Z3.Libz3.Z3_mk_lt(ctx.ctx, a.expr, b.expr)
    return Z3.Expr(ctx, res)
end

function _z3_le(a, b, ctx)
    res = Z3.Libz3.Z3_mk_le(ctx.ctx, a.expr, b.expr)
    return Z3.Expr(ctx, res)
end

function _z3_gt(a, b, ctx)
    res = Z3.Libz3.Z3_mk_gt(ctx.ctx, a.expr, b.expr)
    return Z3.Expr(ctx, res)
end

function _z3_ge(a, b, ctx)
    res = Z3.Libz3.Z3_mk_ge(ctx.ctx, a.expr, b.expr)
    return Z3.Expr(ctx, res)
end

function _z3_ite(c, t, e, ctx)
    res = Z3.Libz3.Z3_mk_ite(ctx.ctx, c.expr, t.expr, e.expr)
    return Z3.Expr(ctx, res)
end

function _z3_distinct(ctx, args)
    expr_ptrs = [arg.expr for arg in args]
    res = Z3.Libz3.Z3_mk_distinct(ctx.ctx, length(expr_ptrs), expr_ptrs)
    return Z3.Expr(ctx, res)
end
```

---

## 7. CONSTRAINTS DATA STRUCTURE

```julia
struct Constraints
    constraints::Vector
    solver::Z3.Solver
    context::Z3.Context
    labels::Vector{Z3.Expr}

    function Constraints(cs::Vector, solvertype = "QF_NRA")
        ctx = Context()
        s = Solver(ctx)

        labels = Z3.Expr[]
        for (i, c) in enumerate(cs)
            label = BoolVar("constraint_$i", ctx)
            push!(labels, label)
            z3_expr = to_z3(c, ctx)  # <-- Converts constraint to Z3
            Z3.Libz3.Z3_solver_assert_and_track(ctx.ctx, s.solver, z3_expr.expr, label.expr)
        end

        return new(cs, s, ctx, labels)
    end
end
```

---

## Summary: Key Integration Points

| Component | File | Purpose |
|-----------|------|---------|
| `to_z3()` | SymbolicSMT.jl | Entry point: converts SymbolicUtils → Z3 |
| `to_z3_tree()` | SymbolicSMT.jl | Tree dispatcher: handles operations recursively |
| `_sexpr_to_symbolic()` | semantic_smt_oracle.jl | Parser: converts SMT-LIB S-expressions → SymbolicUtils |
| `_sexpr_to_symbolic_with_declared()` | semantic_smt_oracle_declared_fun.jl | Extended parser: adds uninterpreted function stubs |
| `build_symbolic_call()` | semantic_smt_oracle_declared_fun.jl | Creates symbolic terms for undeclared functions |
| **Error Points** | Both files | Line 110 (semantic_smt_oracle.jl) & Line 160 (SymbolicSMT.jl) |

