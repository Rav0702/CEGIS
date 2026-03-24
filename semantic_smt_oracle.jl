"""
    semantic_smt_oracle.jl

Semantic SMT-based oracle for CEGIS synthesis using formal verification.

The oracle takes a parsed SyGuS specification (SMTSpec) and checks candidate
programs against its constraints using SMT solving. It produces counterexamples
when a candidate violates a constraint.

Requires: parse_sygus.jl, rulenode_to_symbolics.jl, and CEGIS module to be loaded first.
"""

using HerbCore
using HerbGrammar
using SymbolicSMT
using SymbolicUtils
using SymbolicUtils: BasicSymbolic, operation, arguments, istree, @syms
using Symbolics: Num, unwrap
using Z3

"""
    SemanticSMTOracle <: AbstractOracle

An oracle that verifies candidate programs using SMT solving against a SyGuS specification.

Fields:
- `spec::SMTSpec` — The parsed SyGuS specification containing constraints
- `sym_vars::Dict` — Mapping of variable symbols to SymbolicUtils objects
- `grammar::AbstractGrammar` — The grammar used to generate candidates
- `mod::Module` — Module context for evaluation

The oracle checks if a candidate program violates any constraint in the specification
by building a counterexample query and checking satisfiability with SymbolicSMT.
"""
struct SemanticSMTOracle <: CEGIS.AbstractOracle
    spec::Any  # SMTSpec type not imported, using Any to avoid dependency issues
    sym_vars::Dict
    grammar::AbstractGrammar
    mod::Module
end

function SemanticSMTOracle(
    spec,
    sym_vars::Dict,
    grammar::AbstractGrammar;
    mod::Module = Main
)
    return SemanticSMTOracle(spec, sym_vars, grammar, mod)
end

# --- SMT-LIB S-expression parsing helpers ------------------------------------

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

function _sexpr_to_symbolic(node, sym_vars::Dict{Symbol,Any})
    if node isa String
        return _atom_to_symbolic(node, sym_vars)
    end
    node isa Vector || error("Invalid S-expression node: $node")
    isempty(node) && error("Empty S-expression list")

    op = lowercase(String(node[1]))
    args = [_sexpr_to_symbolic(a, sym_vars) for a in node[2:end]]

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
    error("Unsupported SMT-LIB operator in constraint string: $op")
end

function _parse_smtlib_string(s::AbstractString, sym_vars::Dict{Symbol,Any})
    tokens = _tokenize_sexpr(s)
    node, idx = _parse_sexpr(tokens, 1)
    idx <= length(tokens) && error("Trailing tokens in S-expression: $(tokens[idx:end])")
    return _sexpr_to_symbolic(node, sym_vars)
end

function _extract_guard_rhs_from_symbolic(term, sym_vars)
    term = _to_su(term)
    if term isa SymbolicUtils.BasicSymbolic && SymbolicUtils.istree(term)
        op = string(SymbolicUtils.operation(term))
        args = SymbolicUtils.arguments(term)
        if op in ("=>", "implies") && length(args) == 2
            return _as_symbolic(args[1], sym_vars), _as_symbolic(args[2], sym_vars)
        end
    end
    return nothing
end

function _constraint_guard_rhs(constraint, sym_vars)
    # NamedTuple from parser: (lhs=..., rhs_out=...)
    if constraint isa NamedTuple
        if haskey(constraint, :lhs) && haskey(constraint, :rhs_out)
            return _as_symbolic(constraint.lhs, sym_vars), _as_symbolic(constraint.rhs_out, sym_vars)
        end
    end

    if constraint isa Pair
        return _as_symbolic(constraint.first, sym_vars), _as_symbolic(constraint.second, sym_vars)
    elseif constraint isa Tuple && length(constraint) == 2
        return _as_symbolic(constraint[1], sym_vars), _as_symbolic(constraint[2], sym_vars)
    end

    direct = _extract_guard_rhs_from_symbolic(constraint, sym_vars)
    direct !== nothing && return direct

    for (gf, rf) in (
        (:lhs_symbolic, :rhs_symbolic), (:lhs_in, :rhs_out), (:guard, :rhs),
        (:lhs, :rhs_out), (:precondition, :expected), (:condition, :out)
    )
        if hasproperty(constraint, gf) && hasproperty(constraint, rf)
            return _as_symbolic(getproperty(constraint, gf), sym_vars),
                   _as_symbolic(getproperty(constraint, rf), sym_vars)
        end
    end

    props = try collect(propertynames(constraint)) catch; Symbol[] end
    error("Constraint has no guard/rhs form. type=$(typeof(constraint)), fields=$(props), value=$(constraint)")
end

# Normalize Symbolics.Num -> SymbolicUtils expression
_to_su(x) = x isa Num ? unwrap(x) : x

# Convert various forms to symbolic terms
function _as_symbolic(x, sym_vars::Dict{Symbol,Any})
    x = _to_su(x)
    if x isa BasicSymbolic
        return x
    elseif x isa Symbol
        return get(sym_vars, x, x)
    elseif x isa Number || x isa Bool
        return x
    elseif x isa AbstractString
        s = strip(String(x))
        # SMT-LIB style expression string
        if startswith(s, "(") && endswith(s, ")")
            return _parse_smtlib_string(s, sym_vars)
        end
        # atom
        sl = lowercase(s)
        sl == "true" && return true
        sl == "false" && return false
        try return parse(Int, s) catch end
        try return parse(Float64, s) catch end
        ss = Symbol(s)
        return get(sym_vars, ss, ss)
    else
        return x
    end
end

function build_cex_query_with_expected(oracle, candidate_symbolic)
    candidate_symbolic = _to_su(candidate_symbolic)
    @syms y_expected::Int

    println("\n=== DEBUG: Build CEX Query ===")
    println("Number of constraints: $(length(oracle.spec.constraints))")

    disjuncts = Any[]
    for (idx, c) in enumerate(oracle.spec.constraints)
        println("\nConstraint $idx:")
        println("  Raw constraint: $c")
        guard_i, rhs_i = _constraint_guard_rhs(c, oracle.sym_vars)
        println("  Guard: $guard_i")
        println("  RHS: $rhs_i")
        guard_i = _to_su(guard_i)
        rhs_i   = _to_su(rhs_i)
        disjunct = guard_i & (y_expected == rhs_i) & (candidate_symbolic != y_expected)
        println("  Disjunct: $disjunct")
        push!(disjuncts, disjunct)
    end

    isempty(disjuncts) && return false, y_expected
    q = disjuncts[1]
    for i in 2:length(disjuncts)
        q = q | disjuncts[i]
    end
    println("\nFinal query: $q")
    return q, y_expected
end

function _solver_assert_local!(cs::Constraints, z3_expr)
    if isdefined(Z3, :assert!)
        return getfield(Z3, :assert!)(cs.solver, z3_expr)
    elseif isdefined(Z3, :assert)
        return getfield(Z3, :assert)(cs.solver, z3_expr)
    else
        return Z3.Libz3.Z3_solver_assert(cs.context.ctx, cs.solver.solver, z3_expr.expr)
    end
end

# keep your existing evaluate_in_z3_model(...)

# Evaluate a symbolic expression in a Z3 model
function evaluate_in_z3_model(expr, cs::Constraints, ctx, model_ptr)
    expr_su = _to_su(expr)
    expr_z3 = SymbolicSMT.to_z3(expr_su, ctx)
    
    result_ptr = Ref{Z3.Libz3.Z3_ast}()
    success = Z3.Libz3.Z3_model_eval(
        ctx.ctx,
        model_ptr,
        expr_z3.expr,
        true,
        result_ptr
    )
    
    if success == 0
        return nothing
    end
    
    result_ast = result_ptr[]
    result_str = unsafe_string(Z3.Libz3.Z3_ast_to_string(ctx.ctx, result_ast))
    
    # Parse result string
    result_lower = lowercase(result_str)
    result_lower == "true" && return true
    result_lower == "false" && return false
    
    try
        return parse(Int, result_str)
    catch
    end
    
    try
        return parse(Float64, result_str)
    catch
    end
    
    return result_str
end

function CEGIS.extract_counterexample(oracle::SemanticSMTOracle, problem, candidate::RuleNode)
    cs = Constraints([])
    pushed = false
    try
        candidate_symbolic = _to_su(rulenode_to_symbolic(candidate, oracle.grammar, oracle.sym_vars))
        cex_query, y_expected = build_cex_query_with_expected(oracle, candidate_symbolic)

        println("\n=== DEBUG: Extract Counterexample ===")
        println("Candidate: $candidate")
        println("Candidate Symbolic: $candidate_symbolic")
        println("CEX Query (symbolic): $cex_query")
        println("Y expected: $y_expected")

        # Skip the symbolic check, go directly to Z3
        Z3.push(cs.solver); pushed = true
        cex_query_z3 = SymbolicSMT.to_z3(_to_su(cex_query), cs.context)
        println("CEX Query (Z3 form): $cex_query_z3")
        
        _solver_assert_local!(cs, cex_query_z3)

        chk = Z3.check(cs.solver)
        println("Z3 Check result: $chk")
        println("  Type: $(typeof(chk))")
        println("  string(chk): $(string(chk))")
        
        # CheckResult is a custom type, compare by string representation
        is_sat = (string(chk) == "sat")
        if !is_sat
            Z3.pop(cs.solver); pushed = false
            println("Z3 result is not SAT (result was $chk), returning nothing")
            return nothing
        end

        # Z3 found a model
        println("Z3 found a satisfying assignment!")
        model_ptr = Z3.Libz3.Z3_solver_get_model(cs.context.ctx, cs.solver.solver)
        input_dict = Dict{Symbol, Any}()
        for v in oracle.spec.vars
            SymbolicSMT._eval_var_from_model(v, model_ptr, cs.context, input_dict)
        end
        println("Input dict from model: $input_dict")

        expected_output = evaluate_in_z3_model(y_expected, cs, cs.context, model_ptr)
        actual_output = evaluate_in_z3_model(candidate_symbolic, cs, cs.context, model_ptr)

        println("Expected output: $expected_output")
        println("Actual output: $actual_output")

        Z3.pop(cs.solver); pushed = false
        cex = CEGIS.Counterexample(input_dict, expected_output, actual_output)
        println("Returning counterexample: $cex")
        return cex
    catch e
        println("Error in extract_counterexample: $e")
        if pushed
            try Z3.pop(cs.solver) catch end
        end
        rethrow()
    end
end
