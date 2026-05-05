# Z3 Query Construction Analysis - Search Results

## Summary

Found comprehensive Z3 query construction pipeline with type tracking and get-value command building.

---

## 1. Z3 Query Construction with (get-value ...) Commands

### Primary Files:
- **`/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl`** - Main query builder
  - **Lines 282-305**: Constructs `(get-value ...)` commands
  - **Lines 280-287**: Free variable value extraction
  - **Lines 291-305**: Candidate output and spec output extraction

### Key Construction Points:

#### Lines 282-288 (Free Variable Values):
```julia
if !isempty(spec.free_vars)
    push!(query_parts, "")
    push!(query_parts, "; Free variable values at counterexample")
    var_list = join([fv.name for fv in spec.free_vars], " ")
    push!(query_parts, "(get-value ($var_list))")
end
```

#### Lines 290-305 (Candidate and Spec Outputs):
```julia
if !isempty(spec.synth_funs)
    push!(query_parts, "")
    push!(query_parts, "; Candidate output(s)")
    for sfun in spec.synth_funs
        args = join([fv.name for fv in spec.free_vars], " ")
        push!(query_parts, "(get-value (($(sfun.name) $args)))")
    end
    
    push!(query_parts, "")
    push!(query_parts, "; Valid spec output(s) - what the spec says is correct")
    for sfun in spec.synth_funs
        fresh_name = get_fresh_const_name(sfun)
        push!(query_parts, "(get-value ($fresh_name))")
    end
end
```

---

## 2. How get-value Lines Are Constructed

### Entry Point: `generate_cex_query()`
**File**: `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/CEXGeneration.jl`
**Lines 80-88**: 
- Converts candidate expressions to SMT-LIB2 using `candidate_to_smt2()`
- Calls `generate_query(sp, smt_candidates)` to build the full query

### Query Building Function: `generate_query()`
**File**: `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl`
**Lines 179-308**:

The function constructs the query in stages:
1. **Lines 186-188**: Set logic and options
2. **Lines 191-198**: Add preamble (sorts, helpers, uninterpreted functions)
3. **Lines 201-211**: Declare free variables (inputs)
4. **Lines 213-234**: Define candidate synthesis functions with substituted parameters
5. **Lines 236-244**: Declare fresh constants representing spec outputs
6. **Lines 247-263**: Assert spec constraints using fresh constants
7. **Lines 265-277**: Assert that candidate violates at least one constraint
8. **Lines 280**: Add check-sat command
9. **Lines 282-305**: Add get-value commands (3 types):
   - Free variable values (line 287)
   - Candidate function outputs (line 296)
   - Spec output constants (line 303)

### Variable Lists Construction:

**Line 286** - Free variables:
```julia
var_list = join([fv.name for fv in spec.free_vars], " ")
push!(query_parts, "(get-value ($var_list))")
```

**Line 295** - Candidate function arguments:
```julia
args = join([fv.name for fv in spec.free_vars], " ")
push!(query_parts, "(get-value (($(sfun.name) $args)))")
```

**Line 302-303** - Spec output fresh constant:
```julia
fresh_name = get_fresh_const_name(sfun)
push!(query_parts, "(get-value ($fresh_name))")
```

### Fresh Constant Naming:
**File**: `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl`
**Lines 18-20**:
```julia
function get_fresh_const_name(sfun::SynthFun)::String
    "out_$(sfun.name)"
end
```

Example: `max3` → `out_max3`

---

## 3. Type Declarations and Conversions

### Type Tracking in Query Generation:

**File**: `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl`
**Lines 221-224** (Bool to Int conversion):
```julia
# CHECK: If target sort is Int but candidate looks like Bool, wrap it
if sfun.sort == "Int" && _looks_like_bool(candidate_subst)
    candidate_subst = _wrap_bool_to_int(candidate_subst)
end
```

**Lines 133-148** (Bool detection):
```julia
function _looks_like_bool(expr::String)::Bool
    expr = strip(expr)
    bool_ops = ["=", "<", ">", "<=", ">=", "and", "or", "not", "distinct"]
    if startswith(expr, "(")
        i = 2
        while i <= length(expr) && expr[i] != ' ' && expr[i] != ')'
            i += 1
        end
        op = expr[2:i-1]
        return op ∈ bool_ops
    end
    false
end
```

**Lines 153-158** (Bool wrapping):
```julia
function _wrap_bool_to_int(expr::String)::String
    if _looks_like_bool(expr)
        return "(ite $expr 1 0)"
    end
    expr
end
```

### Parser Type System:
**File**: `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/candidates.jl`

#### Abstract Parser Type:
**Lines 34**: 
```julia
abstract type AbstractCandidateParser end
```

#### Two Main Implementations:

1. **InfixCandidateParser** (Lines 220-242):
   - Strictly-typed SMT-LIB2 parsing
   - Converts infix to prefix notation
   - Cannot handle mixed bool-numeric (e.g., `(x > y) * x`)

2. **SymbolicCandidateParser** (Lines 262-452):
   - Type-aware recursive descent parser
   - Handles mixed boolean-numeric expressions
   - Automatic type coercion (Bool → Int when needed)
   - Uses typed AST: `IntExpr` and `BoolExpr` (Lines 274-280)

#### Typed AST Types:
**Lines 272-284**:
```julia
abstract type TypedExpr end

struct IntExpr <: TypedExpr
    smt::String  # SMT-LIB2 representation
end

struct BoolExpr <: TypedExpr
    smt::String  # SMT-LIB2 representation
end

"""Convert a Bool expression to Int by wrapping in (ite expr 1 0)"""
_bool_to_int(e::BoolExpr)::IntExpr = IntExpr("(ite $(e.smt) 1 0)")
_bool_to_int(e::IntExpr)::IntExpr = e
```

#### Type Coercion During Parsing:
**Lines 305-328** (Symbolic parser type-aware expression parsing):
```julia
function _symbolic_parse_expr_typed(p::_SymbolicParserImpl, min_prec::Int=0)::TypedExpr
    lhs = _symbolic_parse_unary_typed(p)
    while true
        op = _pk_sym(p)
        info = get(_SYMBOLIC_OPS, op, nothing)
        (info === nothing || info[1] <= min_prec) && break
        _nx_sym(p)
        rhs = _symbolic_parse_expr_typed(p, info[1])
        prec, smt_op, result_type = info
        
        # Type coercion: if arithmetic operator needs Int but got Bool, coerce
        lhs_int = (result_type == :int) ? _bool_to_int(lhs) : lhs
        rhs_int = (result_type == :int) ? _bool_to_int(rhs) : rhs
        
        if result_type == :bool
            smt = "($(smt_op) $(lhs_int.smt) $(rhs_int.smt))"
            lhs = BoolExpr(smt)
        else
            smt = "($(smt_op) $(lhs_int.smt) $(rhs_int.smt))"
            lhs = IntExpr(smt)
        end
    end
    lhs
end
```

#### Operator Type Info:
**Lines 296-302** (Type tags for each operator):
```julia
const _SYMBOLIC_OPS = Dict(
    "or"  => (1, "or", :bool),    "and" => (2, "and", :bool),
    "="   => (3, "=", :bool),     "!="  => (3, "distinct", :bool),
    "<"   => (3, "<", :bool),     "<="  => (3, "<=", :bool),
    ">"   => (3, ">", :bool),     ">="  => (3, ">=", :bool),
    "+"   => (4, "+", :int),      "-"   => (4, "-", :int),    "*" => (5, "*", :int),
)
```

---

## 4. "Z3 Status:" Message Location

**File**: `/Users/howie/.julia/dev/CEGIS/src/Oracles/z3_oracle.jl`
**Line 151**:
```julia
println("  Z3 Status: $(result.status)")
```

### Context (Lines 143-157):
```julia
result = try
    CEXGeneration.verify_query(query)
catch query_error
    println("  [ERROR in verify_query]: $query_error")
    CEXGeneration.Z3Result(:unknown, Dict{String, Any}())
end

println("  Z3 Status: $(result.status)")
if result.status == :sat && !isempty(result.model)
    println("  Model keys: $(keys(result.model))")
    for (k, v) in result.model
        println("    $k => $v")
    end
end
```

### Status Handling (Lines 160-169):
```julia
# If unsat, candidate is valid (no counterexample)
if result.status == :unsat
    return nothing
end

# If unknown, Z3 had an error (likely type mismatch in candidate)
if result.status == :unknown
    println("  [SKIPPED: Z3 had an error - likely type mismatch]")
    return nothing
end
```

### Z3Result Type Definition:
**File**: `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/z3_verify.jl`
**Lines 20-23**:
```julia
struct Z3Result
    status :: Symbol  # :sat or :unsat
    model  :: Dict{String, Any}
end
```

---

## 5. Full SMT-LIB2 Query Building Function

### Main Entry Point: `generate_cex_query()`
**File**: `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/CEXGeneration.jl`
**Lines 80-88**:
```julia
function generate_cex_query(sp::Spec, candidates::Dict{String,String})::String
    # Convert any infix expressions to SMT-LIB2 prefix
    smt_candidates = Dict{String,String}()
    for (name, expr) in candidates
        smt_candidates[name] = candidate_to_smt2(expr)
    end

    generate_query(sp, smt_candidates)
end
```

### Complete Query Builder: `generate_query()`
**File**: `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl`
**Lines 179-308**:

Full structure:
1. **Set logic** (Line 187)
2. **Set options** (Line 188)
3. **Add preamble** with declarations (Lines 191-198)
4. **Declare free variables** (Lines 201-207)
5. **Define synthesis functions** with parameter substitution (Lines 213-230):
   - Reads candidate expression
   - Substitutes parameters using `substitute_params()` (Lines 107-125)
   - Checks and converts Bool→Int if needed (Lines 221-224)
   - Outputs `(define-fun ...)` command
6. **Declare fresh constants** representing spec outputs (Lines 236-241)
7. **Assert spec constraints** with fresh constants substituted (Lines 247-263):
   - Calls `substitute_synth_calls()` (Lines 40-90) to replace function calls with fresh constants
   - For each function, outputs `(assert ...)` commands
8. **Assert that candidate violates at least one constraint** (Lines 267-277):
   - Wraps all constraints in `(assert (not (and ...)))`
9. **Add check-sat command** (Line 280)
10. **Add get-value commands** for counterexample extraction (Lines 282-305)

### Query Verification: `verify_query()`
**File**: `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/z3_verify.jl`
**Lines 161-194**:
```julia
function verify_query(query::String)::Z3Result
    # Ensure query has check-sat
    lines = split(query, '\n')
    check_sat_idx = findfirst(line -> strip(line) == "(check-sat)", lines)

    if check_sat_idx === nothing
        return Z3Result(:unknown, Dict())
    end

    # Single Z3 call with full query (check-sat + get-value)
    out = try
        _z3_run(query)
    catch e
        return Z3Result(:unknown, Dict())
    end

    # Parse response
    response_lines = split(out, '\n')
    first_line = strip(response_lines[1])
    
    first_line == "unsat" && return Z3Result(:unsat, Dict())
    first_line != "sat"   && return Z3Result(:unknown, Dict())

    # Extract model from remaining lines
    if length(response_lines) <= 1
        return Z3Result(:sat, Dict())
    end

    model_str = join(response_lines[2:end], '\n')
    model     = _parse_get_value_output(model_str)

    return Z3Result(:sat, model)
end
```

### Model Parsing: `_parse_get_value_output()`
**File**: `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/z3_verify.jl`
**Lines 52-75**:
```julia
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
```

---

## Complete File Paths and Line Numbers Summary

| Component | File | Lines | Description |
|-----------|------|-------|-------------|
| **Query generation entry** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/CEXGeneration.jl` | 80-88 | `generate_cex_query()` - main entry point |
| **Full SMT-LIB2 query builder** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl` | 179-308 | `generate_query()` - constructs complete query |
| **Get-value free vars** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl` | 282-288 | Free variable value extraction |
| **Get-value candidate output** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl` | 290-297 | Candidate function call values |
| **Get-value spec output** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl` | 299-305 | Fresh constant spec outputs |
| **Fresh constant naming** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl` | 18-20 | `get_fresh_const_name()` |
| **Bool detection** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl` | 133-148 | `_looks_like_bool()` |
| **Bool to Int wrapping** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl` | 153-158 | `_wrap_bool_to_int()` |
| **Parameter substitution** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl` | 107-125 | `substitute_params()` |
| **Function call substitution** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/query.jl` | 40-90 | `substitute_synth_calls()` |
| **Candidate to SMT-LIB2** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/candidates.jl` | 500-502 | `candidate_to_smt2()` entry point |
| **Infix parser** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/candidates.jl` | 220-242 | `InfixCandidateParser` implementation |
| **Symbolic parser** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/candidates.jl` | 262-452 | `SymbolicCandidateParser` with type tracking |
| **Typed AST types** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/candidates.jl` | 272-284 | `IntExpr` and `BoolExpr` types |
| **Type coercion** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/candidates.jl` | 305-328 | Type-aware expression parsing |
| **Operator type info** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/candidates.jl` | 296-302 | Operator precedence and type tags |
| **Query verification** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/z3_verify.jl` | 161-194 | `verify_query()` - runs Z3 |
| **Model parsing** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/z3_verify.jl` | 52-75 | `_parse_get_value_output()` |
| **Z3 Result type** | `/Users/howie/.julia/dev/CEGIS/src/CEXGeneration/z3_verify.jl` | 20-23 | `Z3Result` struct |
| **Z3 Status print** | `/Users/howie/.julia/dev/CEGIS/src/Oracles/z3_oracle.jl` | 151 | Print "Z3 Status: ..." |
| **Counterexample extraction** | `/Users/howie/.julia/dev/CEGIS/src/Oracles/z3_oracle.jl` | 108-211 | `extract_counterexample()` - oracle entry point |

