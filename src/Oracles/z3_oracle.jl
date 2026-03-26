"""
    z3_oracle.jl

Z3-based oracle for CEGIS synthesis using the CEXGeneration module.

The oracle uses:
- CEXGeneration.parse_spec_from_file to parse SyGuS specifications
- CEXGeneration.generate_cex_query to create SMT-LIB2 queries
- CEXGeneration.verify_query to run Z3 directly with native SMT-LIB2 parser

No intermediate files or subprocess calls.

Note: CEXGeneration module is expected to be available in the parent CEGIS module scope.
"""

using HerbCore
using HerbGrammar
using Z3

"""
    Z3Oracle <: AbstractOracle

An oracle that verifies candidate programs using native Z3 SMT solving via the CEXGeneration module.

Uses Z3 API to convert candidates to SMT-LIB2 format, avoiding manual string parsing.

Fields:
- `spec_file::String` — Path to the .sl SyGuS specification file
- `spec::Any` — Parsed specification (CEXGeneration.Spec)
- `grammar::AbstractGrammar` — The grammar used to generate candidates
- `z3_ctx::Z3.Context` — Z3 context for expression building
- `z3_vars::Dict{String,Z3.Expr}` — Cached Z3 variables for free variables
- `mod::Module` — Module context for evaluation

The oracle converts candidates to Z3 expressions, then uses Z3's string output for SMT-LIB2.
"""
struct Z3Oracle <: AbstractOracle
    spec_file::String
    spec::Any  # CEXGeneration.Spec
    grammar::AbstractGrammar
    z3_ctx::Z3.Context
    z3_vars::Dict{String,Z3.Expr}
    mod::Module
end

"""
    Z3Oracle(spec_file::String, grammar::AbstractGrammar; mod::Module = Main)

Create a Z3Oracle that uses native Z3 SMT solving for formal verification.

# Arguments
- `spec_file::String` — Path to SyGuS specification (.sl file)
- `grammar::AbstractGrammar` — Grammar for candidate generation
- `mod::Module` — Module context (default: Main)

# Returns
- `Z3Oracle` instance with parsed specification and Z3 context

# Example
```
oracle = Z3Oracle("problem.sl", grammar)
```
"""
function Z3Oracle(
    spec_file::String,
    grammar::AbstractGrammar;
    mod::Module = Main
)
    # CEXGeneration is included in parent CEGIS module before this file is included
    spec = try
        CEXGeneration.parse_spec_from_file(spec_file)
    catch
        error("CEXGeneration module not found. Make sure it's loaded before Z3Oracle is used.")
    end
    
    # Create Z3 context
    z3_ctx = Z3.Context()
    
    # Create Z3 variables for all free variables
    z3_vars = Dict{String,Z3.Expr}()
    for fv in spec.free_vars
        if fv.sort == "Int"
            z3_vars[fv.name] = Z3.IntVar(fv.name, z3_ctx)
        elseif fv.sort == "Bool"
            z3_vars[fv.name] = Z3.BoolVar(fv.name, z3_ctx)
        end
    end
    
    return Z3Oracle(spec_file, spec, grammar, z3_ctx, z3_vars, mod)
end

"""
    extract_counterexample(oracle::Z3Oracle, problem, candidate::RuleNode)

Extract a counterexample by converting the candidate to Z3 and checking with Z3.

Returns a `Counterexample` if the candidate is invalid, or `nothing` if no counterexample found.
"""
function extract_counterexample(
    oracle::Z3Oracle,
    problem,
    candidate::RuleNode
)::Union{Counterexample, Nothing}
    try
        # Convert RuleNode to Julia expression using HerbGrammar
        candidate_expr = HerbGrammar.rulenode2expr(candidate, oracle.grammar)
        
        # DEBUG: Print candidate expression
        println("[Z3Oracle] Candidate expression: $(candidate_expr)")
        
        # Convert Julia expression to Z3 expression
        candidate_z3 = _expr_to_z3(candidate_expr, oracle.z3_ctx, oracle.z3_vars)
        
        # DEBUG: Print Z3 expression
        println("[Z3Oracle] Z3 expression: $(candidate_z3)")
        
        # Convert Z3 expression to SMT-LIB2 string representation
        candidate_str = string(candidate_z3)
        
        # DEBUG: Print candidate SMT-LIB2 string
        println("[Z3Oracle] Candidate SMT-LIB2: $(candidate_str)")
        
        # Get the function name from the spec (assume single synthesis function)
        if isempty(oracle.spec.synth_funs)
            return nothing
        end
        func_name = oracle.spec.synth_funs[1].name
        
        # DEBUG: Print function name
        println("[Z3Oracle] Function name: $(func_name)")
        println("[Z3Oracle] Original spec constraints count: $(length(oracle.spec.constraints))")
        
        # Generate counterexample query using CEXGeneration
        candidates_dict = Dict(func_name => candidate_str)
        query = CEXGeneration.generate_cex_query(oracle.spec, candidates_dict)
        
        # DEBUG: Print query
        println("[Z3Oracle] ============ SMT-LIB2 Query ============")
        println(query)
        println("[Z3Oracle] ============ End Query ============")
        
        # Verify the query using Z3
        result = CEXGeneration.verify_query(query)
        
        # DEBUG: Print Z3 result status
        println("[Z3Oracle] Z3 result status: $(result.status)")
        println("[Z3Oracle] Z3 model: $(result.model)")
        
        # If unsat, candidate is valid (no counterexample)
        if result.status == :unsat
            println("[Z3Oracle] Result: UNSAT (candidate passes Z3 verification)")
            return nothing
        end
        
        # Extract model from Z3 result
        if result.status == :sat && !isempty(result.model)
            # Build input dictionary from free variables
            # Z3 may not include all variables in the model, so provide defaults
            input_dict = Dict{Symbol, Any}()
            for fv in oracle.spec.free_vars
                val = get(result.model, fv.name, 0)  # Default to 0 if not in model
                input_dict[Symbol(fv.name)] = val
            end
            
            # Get expected output from model (if available)
            func_key = "$(func_name)_result"
            expected_output = get(result.model, func_key, nothing)
            
            # DEBUG: Print counterexample found
            println("[Z3Oracle] Result: SAT - Counterexample found")
            println("[Z3Oracle] Input: $(input_dict)")
            println("[Z3Oracle] Expected output: $(expected_output)")
            
            # Return counterexample
            return Counterexample(input_dict, expected_output, nothing)
        end
        
        println("[Z3Oracle] Result: No counterexample extracted")
        return nothing
    catch e
        println("[Z3Oracle] Exception caught: $(e)")
        return nothing
    end
end

"""
    _expr_to_z3(val::Any, ctx::Z3.Context, vars::Dict{String,Z3.Expr})::Z3.Expr

Convert a Julia value or expression to a Z3 expression using the Z3 API.

Handles:
- Literal numbers and booleans
- Symbols (variable references)
- Call expressions (operators)
- Binary and unary operators
- if-then-else expressions
"""
function _expr_to_z3(
    val::Any,
    ctx::Z3.Context,
    vars::Dict{String,Z3.Expr}
)::Z3.Expr
    # Handle literals
    if val isa Integer
        return Z3.IntVal(val, ctx)
    elseif val isa Bool
        return Z3.BoolVal(val, ctx)
    elseif val isa Symbol
        # Look up variable in vars dict
        var_name = string(val)
        if haskey(vars, var_name)
            return vars[var_name]
        else
            error("Variable not found in Z3 context: $var_name")
        end
    elseif val isa Expr && val.head == :call
        op = val.args[1]
        args = val.args[2:end]
        
        # Binary operators
        if length(args) == 2
            left = _expr_to_z3(args[1], ctx, vars)
            right = _expr_to_z3(args[2], ctx, vars)
            
            if op == :+
                return left + right
            elseif op == :-
                return left - right
            elseif op == :*
                return left * right
            elseif op == :/
                return left / right
            elseif op == :^
                return left ^ right
            # Comparisons
            elseif op == :<
                return left < right
            elseif op == :<=
                return left <= right
            elseif op == :>
                return left > right
            elseif op == :>=
                return left >= right
            elseif op == :(==)
                return left == right
            elseif op == :(!=)
                return left != right
            end
        end
        
        # Unary operators
        if length(args) == 1
            arg = _expr_to_z3(args[1], ctx, vars)
            if op == :-
                return -arg
            elseif op == :!
                return Z3.Not(arg)
            end
        end
        
        # if-then-else (ternary)
        if op == :ifelse && length(args) == 3
            cond = _expr_to_z3(args[1], ctx, vars)
            then_val = _expr_to_z3(args[2], ctx, vars)
            else_val = _expr_to_z3(args[3], ctx, vars)
            return Z3.If(cond, then_val, else_val)
        end
    end
    
    error("Cannot convert to Z3 expression: $val (type: $(typeof(val)))")
end
