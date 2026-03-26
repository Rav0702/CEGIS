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

"""
    Z3Oracle <: AbstractOracle

An oracle that verifies candidate programs using native Z3 SMT solving via the CEXGeneration module.

Fields:
- `spec_file::String` — Path to the .sl SyGuS specification file
- `spec::Any` — Parsed specification (CEXGeneration.Spec)
- `grammar::AbstractGrammar` — The grammar used to generate candidates
- `mod::Module` — Module context for evaluation

The oracle generates counterexample queries in SMT-LIB2 format and verifies them
using Z3's native parser via the CEXGeneration module.
"""
struct Z3Oracle <: AbstractOracle
    spec_file::String
    spec::Any  # CEXGeneration.Spec
    grammar::AbstractGrammar
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
- `Z3Oracle` instance with parsed specification

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
    # so it will be available in module scope as `CEXGeneration`
    spec = try
        CEXGeneration.parse_spec_from_file(spec_file)
    catch
        error("CEXGeneration module not found. Make sure it's loaded before Z3Oracle is used.")
    end
    return Z3Oracle(spec_file, spec, grammar, mod)
end

"""
    extract_counterexample(oracle::Z3Oracle, problem, candidate::RuleNode)

Extract a counterexample by converting the candidate to SMT-LIB2 and checking with Z3.

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
        
        # Convert expression to infix string notation
        candidate_str = _expr_to_candidate_string(candidate_expr)
        
        # Get the function name from the spec (assume single synthesis function)
        if isempty(oracle.spec.synth_funs)
            return nothing
        end
        func_name = oracle.spec.synth_funs[1].name
        
        # Generate counterexample query using CEXGeneration
        # CEXGeneration is available in module scope
        candidates_dict = Dict(func_name => candidate_str)
        query = CEXGeneration.generate_cex_query(oracle.spec, candidates_dict)
        
        # Verify the query using Z3
        result = CEXGeneration.verify_query(query)
        
        # If unsat, candidate is valid (no counterexample)
        if result.status == :unsat
            return nothing
        end
        
        # Extract model from Z3 result
        if result.status == :sat && !isempty(result.model)
            # Build input dictionary from free variables
            input_dict = Dict{Symbol, Any}()
            for fv in oracle.spec.free_vars
                val = get(result.model, fv.name, nothing)
                if val !== nothing
                    input_dict[Symbol(fv.name)] = val
                end
            end
            
            # Get expected output from model (if available)
            func_key = "$(func_name)_result"
            expected_output = get(result.model, func_key, nothing)
            
            # Return counterexample
            return Counterexample(input_dict, expected_output, nothing)
        end
        
        return nothing
    catch e
        println("Error in Z3Oracle.extract_counterexample: $e")
        println("  Backtrace:")
        Base.showerror(stderr, e)
        return nothing
    end
end

"""
    _expr_to_candidate_string(expr::Expr)::String

Convert a Julia expression to an infix string suitable for CEXGeneration.

Handles basic arithmetic, comparisons, and control flow operators.
"""
function _expr_to_candidate_string(expr::Expr)::String
    if expr.head == :call
        op = expr.args[1]
        args = expr.args[2:end]
        
        # Binary operators
        if length(args) == 2
            left = _expr_to_string_value(args[1])
            right = _expr_to_string_value(args[2])
            
            if op in (:+, :-, :*, :/, :%, :^, :<, :<=, :>, :>=, :(==), :(!=), :&, :|)
                return "($left $op $right)"
            end
        end
        
        # Unary operators
        if length(args) == 1 && op in (:-, :!)
            arg = _expr_to_string_value(args[1])
            return "($op $arg)"
        end
        
        # if-then-else
        if op == :ifelse && length(args) == 3
            cond = _expr_to_string_value(args[1])
            true_val = _expr_to_string_value(args[2])
            false_val = _expr_to_string_value(args[3])
            return "(if $cond then $true_val else $false_val)"
        end
    end
    
    # Fallback: try to convert to string
    return string(expr)
end

"""
    _expr_to_string_value(val::Any)::String

Convert a value to its string representation for SMT-LIB2.
"""
function _expr_to_string_value(val::Any)::String
    if val isa Expr
        return _expr_to_candidate_string(val)
    elseif val isa Symbol
        return string(val)
    else
        return string(val)
    end
end
