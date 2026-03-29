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
- `enum_count::Int` — Enumeration counter for debugging
- `test_candidate::Union{String,Nothing}` — Optional candidate to test at specific enumeration
- `parser::CEXGeneration.AbstractCandidateParser` — Pluggable parser for candidate→SMT-LIB2 conversion

The oracle converts candidates to Z3 expressions using the configured parser, then uses Z3's string output for SMT-LIB2.
"""
mutable struct Z3Oracle <: AbstractOracle
    spec_file::String
    spec::Any  # CEXGeneration.Spec
    grammar::AbstractGrammar
    z3_ctx::Z3.Context
    z3_vars::Dict{String,Z3.Expr}
    mod::Module
    enum_count::Int              # Track enumeration count
    test_candidate::Union{String,Nothing}  # Candidate to test at enumeration 1000
    parser::CEXGeneration.AbstractCandidateParser  # Pluggable candidate parser
end

"""
    Z3Oracle(spec_file::String, grammar::AbstractGrammar; mod::Module = Main, parser::CEXGeneration.AbstractCandidateParser = CEXGeneration.get_default_candidate_parser())

Create a Z3Oracle that uses native Z3 SMT solving for formal verification.

# Arguments
- `spec_file::String` — Path to SyGuS specification (.sl file)
- `grammar::AbstractGrammar` — Grammar for candidate generation
- `mod::Module` — Module context (default: Main)
- `parser::CEXGeneration.AbstractCandidateParser` — Candidate parser implementation (default: InfixCandidateParser)

# Returns
- `Z3Oracle` instance with parsed specification and Z3 context

# Example
```
oracle = Z3Oracle("problem.sl", grammar)
oracle2 = Z3Oracle("problem.sl", grammar, parser=SymbolicCandidateParser())
```
"""
function Z3Oracle(
    spec_file::String,
    grammar::AbstractGrammar;
    mod::Module = Main,
    parser::CEXGeneration.AbstractCandidateParser = CEXGeneration.get_default_candidate_parser()
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
    
    return Z3Oracle(spec_file, spec, grammar, z3_ctx, z3_vars, mod, 0, nothing, parser)
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
        # Increment enumeration counter
        oracle.enum_count += 1
        current_enum = oracle.enum_count
        
        # Convert RuleNode to Julia expression
        candidate_expr = HerbGrammar.rulenode2expr(candidate, oracle.grammar)
        candidate_readable = string(candidate_expr)
        
        # Parse candidate to SMT-LIB2 format using injected parser
        candidate_str = CEXGeneration.to_smt2(oracle.parser, candidate_readable)
        
        # Get the function name from the spec (assume single synthesis function)
        if isempty(oracle.spec.synth_funs)
            return nothing
        end
        func_name = oracle.spec.synth_funs[1].name
        
        # Generate counterexample query using CEXGeneration
        candidates_dict = Dict(func_name => candidate_str)
        query = CEXGeneration.generate_cex_query(oracle.spec, candidates_dict)
        
        println("\n[ORACLE_CALL #$current_enum]")
        println("  Candidate (Julia): $candidate_readable")
        println("  Candidate (SMT): $candidate_str")
        println("  [DEBUG Z3 QUERY]")
        println(query)
        println("  [END Z3 QUERY]")

        # Verify the query using Z3
        result = try
            CEXGeneration.verify_query(query)
        catch query_error
            println("  [ERROR in verify_query]: $query_error")
            # Treat verification errors as unknown status (skip this candidate)
            CEXGeneration.Z3Result(:unknown, Dict{String, Any}())
        end
        
        println("  Z3 Status: $(result.status)")
        if result.status == :sat && !isempty(result.model)
            println("  Model keys: $(keys(result.model))")
            for (k, v) in result.model
                println("    $k => $v")
            end
        end
        
        # If unsat, candidate is valid (no counterexample)
        if result.status == :unsat
            return nothing
        end
        
        # If unknown, Z3 had an error (likely type mismatch in candidate)
        # Treat this as invalid candidate - skip it
        if result.status == :unknown
            println("  [SKIPPED: Z3 had an error - likely type mismatch]")
            return nothing
        end
        
        # Extract model from Z3 result
        if result.status == :sat && !isempty(result.model)
            # Build input dictionary: map free variables to synth-fun parameter names
            # SyGuS free_vars (x1, x2, ...) are constraint variables
            # Synth-fun parameters (y1, y2, ...) are what we synthesize over
            # Z3 returns values for free_vars, but we need to map them to synth-fun parameters
            input_dict = Dict{Symbol, Any}()
            
            # Get synth-fun parameters
            if isempty(oracle.spec.synth_funs)
                return nothing
            end
            sfun = oracle.spec.synth_funs[1]
            sfun_param_names = [pname for (pname, _) in sfun.params]
            
            # Map free variables to synth-fun parameters (in order)
            for i in 1:min(length(sfun_param_names), length(oracle.spec.free_vars))
                fv = oracle.spec.free_vars[i]
                param_name = sfun_param_names[i]
                val = get(result.model, fv.name, 0)  # Default to 0 if not in model
                input_dict[Symbol(param_name)] = val
            end
            
            # Get expected output from fresh constant
            # The fresh constant represents "what the spec says is valid at this input"
            fresh_const_name = "out_$(func_name)"
            expected_output = get(result.model, fresh_const_name, nothing)
            
            # Return counterexample
            return Counterexample(input_dict, expected_output, nothing)
        end
        
        return nothing
    catch e
        println("  [ERROR in extract_counterexample]: $e")
        println("  Stacktrace:")
        showerror(stdout, e)
        println()
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
