# parse_sygus.jl
# Parser for SyGuS (.sl) files into an SMTSpec object

using Symbolics

"""
    SMTSpec

Represents a parsed SyGuS specification.

Fields:
- vars::Vector{Symbol}: Declared variables
- constraints::Vector{NamedTuple}: Each constraint has:
  - lhs: Left-hand side of implication (the precondition)
  - rhs_out: Expected output value (can be integer or S-expression string)
"""
struct SMTSpec
    vars::Vector{Symbol}
    constraints::Vector{NamedTuple}
end

"""
    parse_sygus(filepath::String)

Parse a SyGuS (.sl) file and return an SMTSpec object.

Extracts:
- Variable declarations: (declare-var name Type)
- Constraints: (constraint (=> condition (= (func ...) output)))
"""
function parse_sygus(filepath::String)
    content = read(filepath, String)
    
    # Extract variables
    vars = Symbol[]
    var_pattern = r"\(declare-var\s+(\w+)\s+\w+\)"
    for match in eachmatch(var_pattern, content)
        push!(vars, Symbol(match.captures[1]))
    end
    
    # Extract constraints
    constraints = []
    
    # Extract constraints by parsing line by line
    # Pattern: (constraint (=> ANTECEDENT (= (FUNC ARGS) OUTPUT)))
    lines = split(content, "\n")
    
    for line in lines
        if startswith(strip(line), "(constraint")
            # Extract the constraint content using a more robust approach
            # Find the => and extract LHS
            m_arrow = match(r"\(constraint\s+\(=>\s+(.+?)\s+\(=\s+", line)
            
            if m_arrow !== nothing
                antecedent_str = strip(m_arrow.captures[1])
                
                # Now find what comes after (= (FUNC ARGS)
                # Find the position after (= (
                eq_pos = findfirst(r"\(=\s+\(", line)
                if eq_pos !== nothing
                    # Skip to find the end of function args (skip one closing paren)
                    start_idx = eq_pos[end] + 1
                    paren_count = 0
                    idx = start_idx
                    
                    # Skip to the closing paren of FUNC application
                    while idx <= length(line)
                        if line[idx] == '('
                            paren_count += 1
                        elseif line[idx] == ')'
                            if paren_count == 0
                                break
                            end
                            paren_count -= 1
                        end
                        idx += 1
                    end
                    
                    # Now extract the output value
                    # The output starts after the closing paren of FUNC and space
                    output_start = idx + 1
                    while output_start <= length(line) && isspace(line[output_start])
                        output_start += 1
                    end
                    
                    # Find the end: should be ))
                    output_end = output_start
                    paren_depth = 0
                    while output_end <= length(line)
                        if line[output_end] == '('
                            paren_depth += 1
                        elseif line[output_end] == ')'
                            if paren_depth == 0
                                break
                            end
                            paren_depth -= 1
                        end
                        output_end += 1
                    end
                    
                    output_str = strip(line[output_start:output_end-1])
                    
                    # Try to parse as integer, otherwise keep as string expression
                    output_val = output_str
                    try
                        output_val = parse(Int, output_str)
                    catch
                        # Keep as string expression
                        output_val = output_str
                    end
                    
                    push!(constraints, (lhs=antecedent_str, rhs_out=output_val))
                end
            end
        end
    end
    
    return SMTSpec(vars, constraints)
end

"""
    parse_sygus_to_symbolics(filepath::String)

Parse a SyGuS file and convert constraints to Symbolics expressions.

Returns (spec::SMTSpec, sym_vars::Dict{Symbol, Sym}, constraints_sym::Vector)
"""
function parse_sygus_to_symbolics(filepath::String)
    spec = parse_sygus(filepath)
    
    # Create symbolic variables using Symbolics.jl
    sym_vars = Dict{Symbol, Symbolics.BasicSymbolic}()
    for var in spec.vars
        sym_vars[var] = only(@variables $var)
    end
    
    # Convert constraint strings to symbolic expressions
    # For now, just return the parsed spec and symbol map
    # The actual conversion would need more sophisticated parsing
    
    return spec, sym_vars
end

"""
    sexpression_to_julia(expr::String)

Convert S-expression (prefix notation) to Julia syntax.

Examples:
- "(< x0 x1)" → "x0 < x1"
- "(and (< x0 x1) (< x1 x2))" → "(x0 < x1) && (x1 < x2)"
- "(> k x0)" → "k > x0"
"""
function sexpression_to_julia(expr::AbstractString)
    expr = String(expr)  # Convert SubString to String if needed
    expr = strip(expr)
    
    # Base case: if it doesn't start with '(', it's a variable/number
    if !startswith(expr, "(")
        return expr
    end
    
    # Remove outer parentheses
    expr = expr[2:end-1]
    
    # Find the operator (first token before whitespace or '(')
    idx = findfirst(x -> isspace(x) || x == '(', expr)
    if idx === nothing
        return expr  # Single token
    end
    
    op = expr[1:idx-1]
    rest = strip(expr[idx:end])
    
    # Handle logical operators (and, or)
    if op == "and"
        operands = split_sexpressions(rest)
        julia_operands = [sexpression_to_julia(op) for op in operands]
        return "(" * join(julia_operands, ") & (") * ")"
    elseif op == "or"
        operands = split_sexpressions(rest)
        julia_operands = [sexpression_to_julia(op) for op in operands]
        return "(" * join(julia_operands, ") | (") * ")"
    end
    
    # Handle comparison operators (< > <= >= = !=)
    if op in ["<", ">", "<=", ">=", "=", "!="]
        operands = split_sexpressions(rest)
        if length(operands) == 2
            left = sexpression_to_julia(strip(operands[1]))
            right = sexpression_to_julia(strip(operands[2]))
            # Convert '=' to '==' for Julia
            julia_op = op == "=" ? "==" : op
            return "$left $julia_op $right"
        end
    end
    
    # Handle arithmetic operators (+ - * / mod abs)
    if op == "+"
        operands = split_sexpressions(rest)
        julia_operands = [sexpression_to_julia(op) for op in operands]
        return join(julia_operands, " + ")
    elseif op == "-"
        operands = split_sexpressions(rest)
        if length(operands) == 1
            # Unary minus
            return "-$(sexpression_to_julia(operands[1]))"
        else
            # Binary minus
            julia_operands = [sexpression_to_julia(op) for op in operands]
            return join(julia_operands, " - ")
        end
    elseif op == "*"
        operands = split_sexpressions(rest)
        julia_operands = [sexpression_to_julia(op) for op in operands]
        return join(julia_operands, " * ")
    elseif op == "/"
        operands = split_sexpressions(rest)
        julia_operands = [sexpression_to_julia(op) for op in operands]
        return join(julia_operands, " / ")
    elseif op == "mod"
        operands = split_sexpressions(rest)
        if length(operands) == 2
            left = sexpression_to_julia(strip(operands[1]))
            right = sexpression_to_julia(strip(operands[2]))
            return "($left % $right)"
        end
    elseif op == "abs"
        operands = split_sexpressions(rest)
        if length(operands) == 1
            arg = sexpression_to_julia(strip(operands[1]))
            return "abs($arg)"
        end
    elseif op == "ite"  # if-then-else: (ite cond then else)
        operands = split_sexpressions(rest)
        if length(operands) == 3
            cond = sexpression_to_julia(strip(operands[1]))
            then_expr = sexpression_to_julia(strip(operands[2]))
            else_expr = sexpression_to_julia(strip(operands[3]))
            # Return as ternary-like expression (cond ? then_expr : else_expr)
            return "($cond ? $then_expr : $else_expr)"
        end
    end
    
    # Default: return original
    return expr
end

"""
    split_sexpressions(s::AbstractString)

Split S-expressions by top-level spaces/commas, respecting parentheses.
"""
function split_sexpressions(s::AbstractString)
    s = String(s)  # Convert SubString to String if needed
    result = String[]
    current = ""
    paren_depth = 0
    
    for char in s
        if char == '('
            paren_depth += 1
            current *= char
        elseif char == ')'
            paren_depth -= 1
            current *= char
        elseif isspace(char) && paren_depth == 0
            if !isempty(strip(current))
                push!(result, current)
            end
            current = ""
        else
            current *= char
        end
    end
    
    if !isempty(strip(current))
        push!(result, current)
    end
    
    return result
end

"""
    show(io::IO, spec::SMTSpec)

Pretty-print an SMTSpec object.
"""
function Base.show(io::IO, spec::SMTSpec)
    println(io, "SMTSpec")
    println(io, "Variables: $(spec.vars)")
    println(io, "Constraints ($(length(spec.constraints))):")
    for (i, c) in enumerate(spec.constraints)
        julia_lhs = sexpression_to_julia(c.lhs)
        println(io, "  [$i] Julia: $julia_lhs => $(c.rhs_out)")
    end
end

"""
    build_cex_query(spec::SMTSpec, candidate, sym_dict::Dict)

Build a counterexample query from an SMTSpec and a candidate expression.

Arguments:
- spec::SMTSpec: Parsed specification with constraints
- candidate: The candidate symbolic expression to test
- sym_dict::Dict: Dictionary mapping symbol names (as Symbols) to their symbolic variable objects
  
For each constraint in spec:
  violation_i = (LHS_i) ∧ (candidate ≠ RHS_out_i)

Returns: violation_0 ∨ violation_1 ∨ ... ∨ violation_n

This query is satisfiable iff the candidate fails at least one constraint.

Example:
  using SymbolicUtils
  @syms x0 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14 x15 x16 x17 k
  spec = parse_sygus("findidx_problem.sl")
  candidate = 3 + 0*x0
  sym_dict = Dict(:x0 => x0, :x1 => x1, ..., :k => k)
  cex_query = build_cex_query(spec, candidate, sym_dict)
"""
function build_cex_query(spec::SMTSpec, candidate, sym_dict::Dict)
    if isempty(spec.constraints)
        return false
    end
    
    violations = []
    
    for (i, c) in enumerate(spec.constraints)
        # Convert S-expression string to Julia expression string
        julia_lhs_str = sexpression_to_julia(c.lhs)
        
        # Parse the string into an expression
        lhs_expr = Meta.parse(julia_lhs_str)
        
        # Replace variable symbols in the expression with their symbolic objects from sym_dict
        lhs_symbolic = substitute_symbols(lhs_expr, sym_dict)
        
        # Handle output value: could be integer or string expression
        rhs_out_value = c.rhs_out
        if rhs_out_value isa String
            # Convert S-expression to Julia and then to symbolic
            julia_rhs_str = sexpression_to_julia(rhs_out_value)
            rhs_expr = Meta.parse(julia_rhs_str)
            rhs_out_value = substitute_symbols(rhs_expr, sym_dict)
        end
        
        # Build violation: (lhs) & (candidate != rhs_out)
        violation = lhs_symbolic & (candidate != rhs_out_value)
        
        push!(violations, violation)
    end
    
    # Link all violations with OR (|)
    result = violations[1]
    for v in violations[2:end]
        result = result | v
    end
    return result
end

"""
    substitute_symbols(expr, sym_dict::Dict)

Replace symbol names in an expression with their symbolic variable objects.
Directly evaluates operators to produce symbolic expressions.
"""
function substitute_symbols(expr, sym_dict::Dict)
    if expr isa Symbol
        # If this symbol is in our dict, return the symbolic object
        return get(sym_dict, expr, expr)
    elseif expr isa Expr
        # Recursively process the expression arguments
        new_args = Any[substitute_symbols(arg, sym_dict) for arg in expr.args]
        
        # Special handling: if the head is an operator and all args are processed,
        # apply the operator directly to get symbolic result
        if expr.head == :call && length(new_args) >= 2
            op = new_args[1]  # The operator (e.g., :<, :>, :&, :|)
            args = new_args[2:end]  # The operands
            
            # Apply the operator to the arguments
            if op == :<
                return args[1] < args[2]
            elseif op == :>
                return args[1] > args[2]
            elseif op == :<=
                return args[1] <= args[2]
            elseif op == :>=
                return args[1] >= args[2]
            elseif op == :(==)
                return args[1] == args[2]
            elseif op == :!=
                return args[1] != args[2]
            elseif op == :&
                result = args[1]
                for arg in args[2:end]
                    result = result & arg
                end
                return result
            elseif op == :|
                result = args[1]
                for arg in args[2:end]
                    result = result | arg
                end
                return result
            elseif op == :+
                result = args[1]
                for arg in args[2:end]
                    result = result + arg
                end
                return result
            elseif op == :-
                if length(args) == 1
                    return -args[1]
                else
                    result = args[1]
                    for arg in args[2:end]
                        result = result - arg
                    end
                    return result
                end
            elseif op == :*
                result = args[1]
                for arg in args[2:end]
                    result = result * arg
                end
                return result
            elseif op == :/
                result = args[1]
                for arg in args[2:end]
                    result = result / arg
                end
                return result
            elseif op == :% || op == :mod
                # Modulo operator
                return args[1] % args[2]
            elseif op == :abs
                return abs(args[1])
            elseif op == :ifelse || op == :?
                # Ternary operator (cond ? then : else)
                # In Julia AST, this is represented as ifelse(cond, then, else)
                if length(args) >= 3
                    return ifelse(args[1], args[2], args[3])
                end
            else
                # For unknown operators, try to apply directly
                return Expr(:call, new_args...)
            end
        else
            # For non-call expressions, just return the reconstructed Expr
            return Expr(expr.head, new_args...)
        end
    else
        # Numbers, strings, etc. stay as-is
        return expr
    end
end

# Example usage:
if abspath(PROGRAM_FILE) == @__FILE__
    # Test with a sample file
    test_file = "findidx_problem.sl"
    
    if isfile(test_file)
        println("Parsing: $test_file\n")
        spec = parse_sygus(test_file)
        println(spec)
        
        println("\n" * repeat("=", 80))
        println("Usage: Building CEX query")
        println(repeat("=", 80))
        println("\n# Step 1: Create symbolic variables")
        println("using SymbolicUtils")
        println("@syms x0 x1 x2 x3 x4 x5 x6 x7 x8 x9 x10 x11 x12 x13 x14 x15 x16 x17 k")
        println("")
        println("# Step 2: Create symbol dictionary")
        println("sym_dict = Dict(")
        for var in spec.vars[1:min(3, length(spec.vars))]
            println("  :$var => $var,")
        end
        println("  ... # all variables")
        println(")")
        println("")
        println("# Step 3: Build and test candidate")
        println("candidate = 3 + 0*x0  # Always returns 3")
        println("cex_query = build_cex_query(spec, candidate, sym_dict)")
        println("is_violated = issatisfiable(cex_query, Constraints([]))")
    else
        println("Usage: julia parse_sygus.jl")
        println("\nTest file not found: $test_file")
        println("\nFunctions available:")
        println("  parse_sygus(filepath) → SMTSpec")
        println("  sexpression_to_julia(s::String) → String")
        println("  build_cex_query(spec, candidate, sym_dict) → Expr")
    end
end
