"""
    GrammarBuilding/GrammarConfig.jl

Configuration-based grammar building system. Replaces hardcoded string interpolation
in z3_smt_cegis.jl with declarative configuration files and reusable operation sets.

## Usage

```julia
# Minimal config (uses defaults)
config = GrammarConfig(spec)

# Extended config with custom operations
config = GrammarConfig(
    spec,
    base_operations = EXTENDED_OPERATIONS,
    additional_rules = ["Expr = Expr * Expr", "Expr = Expr % Expr"]
)

# Extract free variables from spec automatically
config = GrammarConfig(spec; free_vars_from_spec=true)

# Build grammar
grammar = build_generic_grammar(spec, config)
```
"""

using HerbCore
using HerbGrammar

# ─────────────────────────────────────────────────────────────────────────────
# Base operation sets (reusable across problems)
# ─────────────────────────────────────────────────────────────────────────────

"""
    const BASE_OPERATIONS

Default base operations for integer arithmetic synthesis.

**Included**:
- Constants: 0, 1, 2, -1
- Binary arithmetic: +, -, *
- Unary arithmetic: - (negation)
- Comparisons: <, >, <=, >=, ==
- Logical: &&, ||, !
- Control: ifelse/3
- Bitwise: &, |, ~ (for bitvector synthesis)

Can be extended by user-defined operation sets.

**WARNING**: This includes logical operators which invalidate integer-only synthesis.
Use `LIA_OPERATIONS` for Linear Integer Arithmetic problems instead.
"""
const BASE_OPERATIONS = Dict(
    :constants      => [0, 1, 2, -1],
    :arithmetic     => [:+, :-, :*],
    :unary_arith    => [:-],
    :comparisons    => [:<, :>, :<=, :>=, :(==)],
    :logical        => [:&&, :||, :!],
    :control        => [:ifelse],
    :bitwise        => [:&, :|, :~],
    :modulo         => [:%],
)

"""
    const LIA_OPERATIONS

Operations for Linear Integer Arithmetic (LIA) synthesis.

**Included** (valid for integer-only synthesis):
- Constants: 0, 1, 2, -1
- Binary arithmetic: +, -, * (subtraction and multiplication)
- Comparisons: <, >, <=, >=, == (produce boolean guards)
- Control: ifelse (conditional branching)

**Excluded** (not valid for LIA):
- Unary arithmetic: unary negation (not needed, constants include -1)
- Logical: &&, ||, ! (these are for boolean synthesis, not integer evaluation)
- Bitwise: &, |, ~ (these require bitwidth semantics)
- Modulo: % (optional for LIA, excluded for simplicity)

This is the appropriate operation set for problems with `(set-logic LIA)` declarations.
"""
const LIA_OPERATIONS = Dict(
    :constants      => [0, 1, 2, -1],
    :arithmetic     => [:+, :-, :*],
    :comparisons    => [:<, :>, :<=, :>=, :(==)],
    :control        => [:ifelse],
)

"""
    const EXTENDED_OPERATIONS

Extended set of operations including additional arithmetic and bitwise operations.

**Includes BASE_OPERATIONS plus**:
- Division: /
- Integer division: div
- Squares and roots: sqrt
- Min/max: min, max
"""
const EXTENDED_OPERATIONS = merge(
    BASE_OPERATIONS,
    Dict(
        :division       => [:/],
        :int_division   => [:div],
        :sqrt           => [:sqrt],
        :min_max        => [:min, :max],
    )
)

"""
    const STRING_OPERATIONS

Operations for string synthesis problems.

**Includes**:
- String functions: length, substr, indexof, concat
- Logical: <, >, ==
- Control: ifelse
"""
const STRING_OPERATIONS = Dict(
    :string_basic   => [:length, :substr, :indexof, :concat],
    :comparisons    => [:<, :>, :(==)],
    :logical        => [:&&, :||, :!],
    :control        => [:ifelse],
    :constants      => [0, 1, ""],
)

"""
    const BITVECTOR_OPERATIONS

Operations for bitvector synthesis problems.

**Includes**:
- Bitwise: &, |, ^, ~, <<, >>
- Arithmetic: +, -
- Comparisons: <, >, <=, >= (for signed/unsigned)
"""
const BITVECTOR_OPERATIONS = Dict(
    :bitwise        => [:&, :|, :^, :~, :<<, :>>],
    :arithmetic     => [:+, :-],
    :comparisons    => [:<, :>, :<=, :>=],
    :logical        => [:&&, :||],
    :control        => [:ifelse],
    :constants      => [0, 1, -1],
)

# ─────────────────────────────────────────────────────────────────────────────
# Grammar configuration type
# ─────────────────────────────────────────────────────────────────────────────

"""
    struct GrammarConfig

Declarative configuration for grammar building. Specifies which operations
to include, how to represent variables, and rules for composition.

**Fields**:
- `base_operations::Dict{Symbol, Vector}` — Operations grouped by category
- `additional_rules::Vector{String}` — Custom grammar rules (raw @csgrammar syntax)
- `free_vars_from_spec::Bool` — Auto-extract vars from Spec (default: true)
- `free_vars_manual::Vector{Pair{Symbol,Symbol}}` — Manual variable declarations [(name, type), ...]
- `start_symbol::Symbol` — Start non-terminal for synthesis (default: :Expr)
- `include_constants::Bool` — Include literal constants (default: true)

**Design**:
- Immutable after creation (no rebuilding logic)
- Purely declarative (describes what grammar to build)
- Composable (can combine multiple operation sets)

**Example**:
```julia
config = GrammarConfig(
    spec;
    base_operations = EXTENDED_OPERATIONS,
    additional_rules = ["Expr = Expr ^ Expr"],  # XOR
    free_vars_from_spec = true,
    start_symbol = :Program,
)
```
"""
struct GrammarConfig
    base_operations      :: Dict{Symbol, Vector}
    additional_rules     :: Vector{String}
    free_vars_from_spec  :: Bool
    free_vars_manual     :: Vector{Pair{Symbol,Symbol}}
    start_symbol         :: Symbol
    include_constants    :: Bool
    
    function GrammarConfig(
        ;
        base_operations     :: Dict{Symbol, Vector} = BASE_OPERATIONS,
        additional_rules    :: Vector{String} = String[],
        free_vars_from_spec :: Bool = true,
        free_vars_manual    :: Vector{Pair{Symbol,Symbol}} = Pair{Symbol,Symbol}[],
        start_symbol        :: Symbol = :Expr,
        include_constants   :: Bool = true,
    )
        new(base_operations, additional_rules, free_vars_from_spec, free_vars_manual, start_symbol, include_constants)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Grammar builder (main function)
# ─────────────────────────────────────────────────────────────────────────────

"""
    build_generic_grammar(spec::Any, config::GrammarConfig) :: AbstractGrammar

Build a context-sensitive grammar from specification and configuration.

**Process**:
1. Extract free variables from `spec` (if `free_vars_from_spec=true`)
2. Merge with manually provided variables
3. Flatten operation sets from `config.base_operations`
4. Generate @csgrammar syntax dynamically
5. Evaluate grammar in appropriate context

**Arguments**:
- `spec::Spec` — Parsed specification (provides variable names/types)
- `config::GrammarConfig` — Configuration describing grammar structure

**Returns**:
- `AbstractGrammar` — Fully-constructed HerbGrammar

**Throws**:
- `ArgumentError` if variables are undefined or types are unsupported
- `ErrorException` if grammar construction fails

**Example**:
```julia
spec = parse_spec(SyGuSParser(), "max.sl")
config = GrammarConfig(
    base_operations = BASE_OPERATIONS,
    free_vars_from_spec = true
)
grammar = build_generic_grammar(spec, config)
```

**Implementation Note**:
This is the most complex part of the refactor. It must:
- Map spec variable types (Int → :Int, Bool → :Bool, etc.)
- Handle variable naming conflicts
- Generate syntactically correct Julia code for @csgrammar
- Support arbitrary operation sets
"""
function build_generic_grammar(spec::Any, config::GrammarConfig) :: AbstractGrammar
    # Step 1: Extract or collect free variables
    free_vars = Dict{Symbol, Symbol}()  # name => type
    
    if config.free_vars_from_spec
        for fv in spec.free_vars
            # Map SyGuS sort to Julia type
            jl_type = sygus_sort_to_julia_type(fv.sort)
            free_vars[Symbol(fv.name)] = jl_type
        end
    end
    
    # Merge with manually provided variables
    for (name, typ) in config.free_vars_manual
        free_vars[name] = typ
    end
    
    # Step 2: Flatten operations from config
    operations = flatten_operations(config.base_operations)
    
    # Step 3: Generate @csgrammar string
    grammar_str = generate_grammar_string(
        config.start_symbol,
        free_vars,
        operations,
        config.additional_rules,
        config.include_constants
    )
    
    # Debug: print generated grammar
    println("[DEBUG] Generated grammar:")
    println(grammar_str)
    
    # Step 4: Evaluate the grammar definition
    # This is a meta-programming step that creates the grammar dynamically
    grammar = eval_grammar_string(grammar_str)
    
    return grammar
end

"""
    sygus_sort_to_julia_type(sort::String) :: Symbol

Convert SyGuS sort name to Julia type symbol.

**Mapping**:
- "Int" → :Int
- "Bool" → :Bool
- "String" → :String
- others → error
"""
function sygus_sort_to_julia_type(sort::String) :: Symbol
    if sort == "Int"
        return :Int
    elseif sort == "Bool"
        return :Bool
    elseif sort == "String"
        return :String
    else
        error("Unsupported sort: $sort. Supported: Int, Bool, String")
    end
end

"""
    flatten_operations(ops::Dict{Symbol, Vector}) :: Vector

Flatten operation dictionary into single vector, removing duplicates.

**Input**: Dict(:arithmetic => [:+, :-, :*], :logical => [:&&, :||], ...)
**Output**: [:+, :-, :*, :&&, :||, ...]
"""
function flatten_operations(ops::Dict{Symbol, Vector}) :: Vector
    flattened = []
    for (key, ops_list) in ops
        # Skip constants; they're handled separately in generate_grammar_string
        if key != :constants
            append!(flattened, ops_list)
        end
    end
    return unique(flattened)  # Remove duplicates
end

"""
    generate_grammar_string(
        start_sym::Symbol,
        free_vars::Dict{Symbol,Symbol},
        operations::Vector,
        additional_rules::Vector{String},
        include_constants::Bool
    ) :: String

Generate @csgrammar syntax as a string with properly typed grammar.

**Output example** (with proper typing):
```julia
@csgrammar begin
    Expr = x | y | 1 | 0 | 2 | -1
    Expr = BoolExpr                    # Bool→Int coercion (e.g., (x < y) + y)
    Expr = Expr + Expr
    Expr = Expr - Expr
    Expr = Expr * Expr
    Expr = ifelse(BoolExpr, Expr, Expr)   # ← Fixed: BoolExpr for condition!
    
    BoolExpr = (Expr < Expr)
    BoolExpr = (Expr > Expr)
    BoolExpr = (Expr <= Expr)
    BoolExpr = (Expr >= Expr)
    BoolExpr = (Expr == Expr)
    BoolExpr = (BoolExpr and BoolExpr)
    BoolExpr = (BoolExpr or BoolExpr)
    BoolExpr = (not BoolExpr)
end
```

**Key improvements**:
1. Separate `Expr` (Int) and `BoolExpr` (Bool) non-terminals
2. `Expr = BoolExpr` allows Bool→Int coercion (expressions like `(x < y) + y`)
3. `ifelse(BoolExpr, Expr, Expr)` prevents invalid candidates like `ifelse(y, y, y)` where condition is Int
4. Comparisons and logical ops explicitly return `BoolExpr`

**Process**:
1. Build Int rule: `Expr = var1 | var2 | ... | const1 | const2 | ...`
2. Add Bool→Int coercion rule: `Expr = BoolExpr`
3. Add binary/unary arithmetic operations on Expr
4. Add ifelse with BoolExpr condition
5. Add all Boolean comparison and logical operations
6. Add any additional custom rules
7. Return complete grammar string ready for eval()
"""
function generate_grammar_string(
    start_sym::Symbol,
    free_vars::Dict{Symbol,Symbol},
    operations::Vector,
    additional_rules::Vector{String},
    include_constants::Bool
) :: String
    
    lines = ["@csgrammar begin"]
    
    # First rule: variables and constants for Expr (Int expressions)
    first_rule_parts = String[]
    
    # Add variables (filter to Int-typed ones)
    for (var_name, var_sort) in free_vars
        if var_sort == :Int
            push!(first_rule_parts, string(var_name))
        end
    end
    
    # Add constants
    if include_constants
        # Integer constants
        for const_val in [0, 1, 2, -1]
            push!(first_rule_parts, string(const_val))
        end
    end
    
    first_rule = "$start_sym = " * join(first_rule_parts, " | ")
    push!(lines, "    " * first_rule)
    
    # Add Bool→Int coercion rule: allows (x < y) + y style expressions
    push!(lines, "    $start_sym = BoolExpr")
    
    # Separate boolean ops from integer ops
    bool_ops = [:(<), :(>), :(<=), :(>=), :(==), :distinct, :&&, :||, :!, :and, :or, :not]
    int_ops = filter(op -> op ∉ bool_ops, operations)
    
    # Binary and unary arithmetic operations (Int → Int)
    for op in int_ops
        arity = operation_arity(op)
        
        if arity == 2
            push!(lines, "    $start_sym = ($start_sym $op $start_sym)")
        elseif arity == 1
            push!(lines, "    $start_sym = ($op $start_sym)")
        elseif arity == 3 && op == :ifelse
            # ifelse with BoolExpr condition and Expr branches
            push!(lines, "    $start_sym = ifelse(BoolExpr, $start_sym, $start_sym)")
        end
    end

    # Now add BoolExpr rules for comparisons
    # Comparisons: Int × Int → Bool
    push!(lines, "    BoolExpr = ($start_sym < $start_sym)")
    push!(lines, "    BoolExpr = ($start_sym > $start_sym)")
    push!(lines, "    BoolExpr = ($start_sym <= $start_sym)")
    push!(lines, "    BoolExpr = ($start_sym >= $start_sym)")
    push!(lines, "    BoolExpr = ($start_sym == $start_sym)")
    
    # NOTE: Logical compositions (and, or, not) can be expressed using nested ifelse
    # We don't add them here because 'and', 'or', 'not' are not valid Julia operators in this context
    
    for rule in additional_rules
        push!(lines, "    " * rule)
    end
    
    push!(lines, "end")
    
    return join(lines, "\n")
end

"""
    operation_arity(op::Symbol) :: Int

Determine the arity (number of arguments) of an operation.

**Returns**:
- 1 for unary: !, ~, length, sqrt, etc. (note: unary - is excluded as it's ambiguous with binary -)
- 2 for binary: +, -, *, <, >, &&, ||, &, |, etc.
- 3 for ternary: ifelse
"""
function operation_arity(op::Symbol) :: Int
    unary_ops = [:!, :~, :length, :sqrt, :sin, :cos, :abs]
    ternary_ops = [:ifelse]
    
    if op in unary_ops
        return 1
    elseif op in ternary_ops
        return 3
    else
        return 2  # Default to binary
    end
end

"""
    eval_grammar_string(grammar_str::String) :: AbstractGrammar

Evaluate a @csgrammar string to produce an actual grammar object.
**Example**:
```julia
grammar_str = \"\"\"
@csgrammar begin
    Expr = x | y | 1 | 0
    Expr = Expr + Expr
    Expr = Expr - Expr
end
\"\"\"
grammar = eval_grammar_string(grammar_str)
```
"""
function eval_grammar_string(grammar_str::String) :: AbstractGrammar
    try
        # Parse the grammar string as Julia code
        expr = Meta.parse(grammar_str)
        
        # Evaluate in Main module context (where @csgrammar macro is available)
        grammar = Core.eval(Main, expr)
        
        return grammar
    catch e
        error("Failed to construct grammar from generated grammar string. " *
              "Error: $(e)\n" *
              "Generated grammar:\n$(grammar_str)")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Convenience functions for common configurations
# ─────────────────────────────────────────────────────────────────────────────

"""
    is_lia_problem(spec::Any) :: Bool

Determine whether a specification is a Linear Integer Arithmetic problem.

Checks the `logic` field of the spec (e.g., "LIA", "QF_LIA", "QF_ALIA").
"""
function is_lia_problem(spec::Any) :: Bool
    if hasfield(typeof(spec), :logic)
        logic = spec.logic
        # Match common LIA logic identifiers
        return in(uppercase(logic), ["LIA", "QF_LIA", "QF_ALIA", "ALIA"])
    end
    return false
end

"""
    default_grammar_config(spec::Any=nothing) :: GrammarConfig

Returns a default grammar configuration suited to the synthesis problem.

**Logic**:
- If `spec` is provided and is an LIA problem: uses `LIA_OPERATIONS` (no logical operators)
- Otherwise: uses `BASE_OPERATIONS` (includes logical operators)

**Defaults** (regardless of problem type):
- Free vars from spec: true (extract from SyGuS declaration)
- Include constants: true (0, 1, 2, -1)
- Start symbol: :Expr

**Arguments**:
- `spec::Union{Any, Nothing}` — Optional specification for logic detection
"""
function default_grammar_config(spec::Any = nothing) :: GrammarConfig
    # Detect problem type and choose appropriate operations
    ops = BASE_OPERATIONS
    if spec !== nothing && is_lia_problem(spec)
        ops = LIA_OPERATIONS
    end
    
    return GrammarConfig(
        base_operations = ops,
        free_vars_from_spec = true,
        start_symbol = :Expr,
        include_constants = true,
    )
end

"""
    lia_grammar_config() :: GrammarConfig

Returns a grammar configuration specifically for Linear Integer Arithmetic (LIA).

Excludes logical operators (&&, ||, !) which are invalid for integer synthesis.
Uses only arithmetic, comparisons, and control flow (ifelse).
"""
function lia_grammar_config() :: GrammarConfig
    return GrammarConfig(
        base_operations = LIA_OPERATIONS,
        free_vars_from_spec = true,
        start_symbol = :Expr,
        include_constants = true,
    )
end

"""
    extended_grammar_config() :: GrammarConfig

Returns a configuration with extended operations (division, sqrt, min, max).
"""
function extended_grammar_config() :: GrammarConfig
    return GrammarConfig(
        base_operations = EXTENDED_OPERATIONS,
        free_vars_from_spec = true,
        start_symbol = :Expr,
        include_constants = true,
    )
end

"""
    string_grammar_config() :: GrammarConfig

Returns a configuration suitable for string synthesis problems.
"""
function string_grammar_config() :: GrammarConfig
    return GrammarConfig(
        base_operations = STRING_OPERATIONS,
        free_vars_from_spec = true,
        start_symbol = :Expr,
        include_constants = true,
    )
end
