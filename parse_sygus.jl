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

"""
    parse_sygus(filepath::String)

Parse a SyGuS (.sl) file and return an SMTSpec object.

Extracts:
- Variable declarations: (declare-var name Type)
- Function definitions: (define-fun name ((params)) ReturnType body)
- Function declarations: (declare-fun name (ParamTypes...) ReturnType)
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
    
    # Extract function definitions
    functions = extract_define_fun(content)
    
    # Extract declared functions
    declared_functions = extract_declare_fun(content)
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
    
    return SMTSpec(vars, constraints, functions, declared_functions)
end

"""
    extract_define_fun(content::String)

Extract all (define-fun ...) declarations from SyGuS file content.

Returns a Dict mapping function names to their definitions.
Each definition is a NamedTuple with:
- params::Vector{Symbol}: Parameter names
- param_types::Vector{String}: Parameter types  
- return_type::String: Return type
- body::String: Function body as S-expression string
"""
function extract_define_fun(content::String)
    functions = Dict{String, NamedTuple}()
    
    # Pattern: (define-fun name ((param1 Type1) ... (paramN TypeN)) ReturnType body)
    # We'll parse this more carefully than a simple regex
    
    lines = split(content, "\n")
    i = 1
    while i <= length(lines)
        line = strip(lines[i])
        
        if startswith(line, "(define-fun")
            # Extract function definition
            # Start collecting the full definition (may span multiple lines)
            full_def = line
            paren_count = count(c -> c == '(', line) - count(c -> c == ')', line)
            
            # Keep adding lines until we have balanced parentheses
            i += 1
            while i <= length(lines) && paren_count > 0
                full_def *= " " * strip(lines[i])
                paren_count += count(c -> c == '(', lines[i]) - count(c -> c == ')', lines[i])
                i += 1
            end
            
            # Now parse the full definition
            try
                parse_define_fun_line(String(full_def), functions)
            catch e
                # Silently skip malformed define-fun lines
                @warn "Skipped malformed define-fun declaration"
            end
        else
            i += 1
        end
    end
    
    return functions
end

"""
    parse_define_fun_line(line::String, functions::Dict)

Parse a single (define-fun ...) declaration and add to functions dict.
"""
function parse_define_fun_line(line::String, functions::Dict)
    # Pattern: (define-fun name ((param1 Type1) ... (paramN TypeN)) ReturnType body)
    
    # Extract name
    name_match = match(r"\(define-fun\s+(\w+)\s+", line)
    if name_match === nothing
        return
    end
    name = name_match.captures[1]
    
    # Find the parameters section: ((param1 Type1) ... (paramN TypeN))
    # First find the opening (( 
    params_start_idx = findfirst("((", line)
    if params_start_idx === nothing
        return
    end
    
    # Find matching )) 
    idx = params_start_idx[end]
    paren_depth = 1
    params_end_idx = idx
    
    while params_end_idx <= length(line)
        if line[params_end_idx] == '('
            paren_depth += 1
        elseif line[params_end_idx] == ')'
            paren_depth -= 1
            if paren_depth == 0
                break
            end
        end
        params_end_idx += 1
    end
    
    # Extract parameter content: everything between (( and ))
    # params_start_idx[1] is the position of the first ( in ((
    # We want from the second ( to the first ) of the closing ))
    params_section = line[params_start_idx[1]+1:params_end_idx-1]
    
    # Parse parameters
    param_names = Symbol[]
    param_types = String[]
    
    # Split by ) ( to find individual parameter declarations
    param_matches = eachmatch(r"\((\w+)\s+(\w+)\)", params_section)
    for pm in param_matches
        push!(param_names, Symbol(pm.captures[1]))
        push!(param_types, pm.captures[2])
    end
    
    # Find return type: it comes right after ) ) Type
    rest_after_params = line[params_end_idx+1:end]
    return_type_match = match(r"^\s*(\w+)\s+", rest_after_params)
    if return_type_match === nothing
        return
    end
    return_type = return_type_match.captures[1]
    
    # Find function body: everything after the return type until final )
    body_start_pos = params_end_idx + length(return_type_match.match)
    # The body is everything until the last )
    body = strip(line[body_start_pos:end-1])
    
    # Store the function definition
    functions[name] = (
        params=param_names,
        param_types=param_types,
        return_type=return_type,
        body=body
    )
end

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

"""
    sexpression_to_julia(expr::String)

Convert S-expression (prefix notation) to Julia syntax.
Examples: "(< x0 x1)" → "x0 < x1", "(and (< x0 x1) (< x1 x2))" → "(x0 < x1) & (x1 < x2)"
"""
function sexpression_to_julia(expr::AbstractString)
    expr = strip(String(expr))
    !startswith(expr, "(") && return expr
    
    expr = expr[2:end-1]
    idx = findfirst(x -> isspace(x) || x == '(', expr)
    idx === nothing && return expr
    
    op, rest = expr[1:idx-1], strip(expr[idx:end])
    operands = split_sexpressions(rest)
    julia_args = [sexpression_to_julia(o) for o in operands]
    
    # Logical operators
    op == "and" && return "(" * join(julia_args, ") & (") * ")"
    op == "or"  && return "(" * join(julia_args, ") | (") * ")"
    
    # Comparison operators
    op in ["<", ">", "<=", ">=", "!="] && length(operands) == 2 && 
        return "$(julia_args[1]) $op $(julia_args[2])"
    op == "=" && length(operands) == 2 && 
        return "$(julia_args[1]) == $(julia_args[2])"
    
    # Arithmetic operators
    op in ["+", "*", "/"] && return join(julia_args, " $op ")
    op == "-" && return length(operands) == 1 ? "-$(julia_args[1])" : join(julia_args, " - ")
    op == "mod" && length(operands) == 2 && return "($(julia_args[1]) % $(julia_args[2]))"
    op == "abs" && length(operands) == 1 && return "abs($(julia_args[1]))"
    op == "ite" && length(operands) == 3 && return "($(julia_args[1]) ? $(julia_args[2]) : $(julia_args[3]))"
    
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
        julia_rhs = c.rhs_out isa AbstractString ? sexpression_to_julia(c.rhs_out) : c.rhs_out
        println(io, "  [$i] Julia: $julia_lhs => $julia_rhs")
    end
end

"""
    build_cex_query(spec::SMTSpec, candidate, sym_dict::Dict)

Build a counterexample query: returns (violation_1 ∨ ... ∨ violation_n)
where violation_i = (precondition_i) ∧ (candidate ≠ expected_output_i).
Query is satisfiable iff candidate fails at least one constraint.
"""
function build_cex_query(spec::SMTSpec, candidate, sym_dict::Dict)
    isempty(spec.constraints) && return false
    
    violations = map(spec.constraints) do c
        lhs_symbolic = substitute_symbols(Meta.parse(sexpression_to_julia(c.lhs)), sym_dict)
        rhs = c.rhs_out isa AbstractString ? 
            substitute_symbols(Meta.parse(sexpression_to_julia(c.rhs_out)), sym_dict) : c.rhs_out
        lhs_symbolic & (candidate != rhs)
    end
    
    reduce(|, violations)
end

"""
    substitute_symbols(expr, sym_dict::Dict)

Replace symbol names in an expression with their symbolic variable objects.
Directly evaluates operators to produce symbolic expressions.
"""
function substitute_symbols(expr, sym_dict::Dict)
    expr isa Symbol && return get(sym_dict, expr, expr)
    expr isa Number && return expr
    expr isa Expr || return expr
    
    new_args = [substitute_symbols(arg, sym_dict) for arg in expr.args]
    expr.head != :call && return Expr(expr.head, new_args...)
    length(new_args) < 2 && return Expr(:call, new_args...)
    
    op, args = new_args[1], new_args[2:end]
    
    # Binary/n-ary operators
    op == :< && return args[1] < args[2]
    op == :> && return args[1] > args[2]
    op == :<= && return args[1] <= args[2]
    op == :>= && return args[1] >= args[2]
    op == :(==) && return args[1] == args[2]
    op == :!= && return args[1] != args[2]
    op == :& && return reduce(&, args)
    op == :| && return reduce(|, args)
    op == :+ && return reduce(+, args)
    op == :* && return reduce(*, args)
    op == :/ && return reduce(/, args)
    op == :- && return length(args) == 1 ? -args[1] : reduce(-, args)
    (op == :% || op == :mod) && return args[1] % args[2]
    op == :abs && return abs(args[1])
    (op == :ifelse || op == :?) && length(args) >= 3 && return ifelse(args[1], args[2], args[3])
    
    return Expr(:call, new_args...)
end

