"""
    SygusGrammar.jl

Build a `ContextSensitiveGrammar` from the **grammar declared inside a SyGuS
`synth-fun`**, rather than synthesizing one from the spec's signature.

## Why this exists

`build_grammar_from_spec` invents a search space (see `GrammarConfig.jl`):
variables, constants `0,1,2,-1`, `+ - *`, all five comparisons, and a
`Expr = BoolExpr` coercion. The official SyGuS benchmarks ship a much tighter
one. For `max4.sl` (SyGuS-COMP 2017 General Track):

```
(Start Int (x y z w 0 1 (+ Start Start) (- Start Start) (ite StartBool Start Start)))
(StartBool Bool ((and B B) (or B B) (not B) (<= S S) (= S S) (>= S S)))
```

Differences that matter for any comparison against published CDGP results:

| | official SyGuS | our generated grammar |
|---|---|---|
| multiplication | **absent** | `Expr * Expr` |
| Bool→Int coercion | **absent** | `Expr = BoolExpr` |
| constants | `0, 1` | `0, 1, 2, -1` |
| comparisons | `<= = >=` | `< > <= >= ==` |
| boolean connectives | `and or not` | none |

The extra `*` and the coercion rule are why our candidates fill up with
`x3*x3` and `(x2 >= 0) + x2` — terms the official grammar cannot even express.
Any result measured on the generated grammar is therefore solving a *different,
larger* problem than the literature, and is not comparable to it.

## Mapping

SyGuS non-terminals are mapped onto the two symbols the rest of this codebase
expects: the Int-sorted start non-terminal becomes `:Expr`, the Bool-sorted one
`:BoolExpr`. Operators are translated to their Julia spellings
(`ite`→`ifelse`, `=`→`==`, `and`→`&&`, `or`→`||`, `not`→`!`), which is what
`rulenode_to_smt2` and the interpreter already understand.
"""

"""SyGuS operator → Julia operator, for the fragment the LIA/CLIA tracks use."""
const SYGUS_OP_MAP = Dict{String,Symbol}(
    "+" => :+, "-" => :-, "*" => :*, "div" => :div, "mod" => :mod, "abs" => :abs,
    "ite" => :ifelse,
    "<" => :<, ">" => :>, "<=" => :<=, ">=" => :>=, "=" => :(==),
    "and" => :&&, "or" => :||, "not" => :!,
)

"""
    parse_sygus_grammar(sfun) -> (nonterminals, productions)

Split a `SynthFun`'s grammar section into an ordered list of
`(name, sort)` non-terminals and a `name => Vector{production}` map, where each
production is the raw s-expression.
"""
function parse_sygus_grammar(sfun::CEXGeneration.SynthFun)
    g = sfun.grammar
    g === nothing && error("synth-fun `$(sfun.name)` declares no grammar section")

    nts = Tuple{String,String}[]
    prods = Dict{String,Vector{Any}}()
    for nt in g
        (nt isa Vector && length(nt) >= 3) ||
            error("malformed SyGuS non-terminal definition: $(CEXGeneration.sexp_to_str(nt))")
        name, sort, body = String(nt[1]), String(nt[2]), nt[3]
        body isa Vector ||
            error("non-terminal `$name` has a non-list production body")
        push!(nts, (name, sort))
        prods[name] = Vector{Any}(body)
    end
    return nts, prods
end

"""Render one SyGuS production as the right-hand side of a Herb grammar rule."""
function _sygus_production_to_rule(prod, symmap::Dict{String,Symbol})::String
    # Atom: a variable, a non-terminal reference, or a literal.
    if prod isa AbstractString
        haskey(symmap, prod) && return string(symmap[prod])
        return String(prod)                     # variable name or numeric literal
    end

    prod isa Vector || error("unsupported production form: $prod")
    isempty(prod) && error("empty production")

    head = prod[1]
    head isa AbstractString || error("non-atomic operator in production")

    # `(Constant Int)` / `(Variable Int)` are SyGuS shorthands we do not expand.
    head in ("Constant", "Variable", "InputVariable", "LocalVariable") &&
        error("unsupported SyGuS grammar shorthand `($head …)` — needs explicit enumeration")

    op = get(SYGUS_OP_MAP, head, nothing)
    op === nothing && error("unsupported SyGuS operator `$head`")

    args = [_sygus_production_to_rule(a, symmap) for a in prod[2:end]]

    if op === :ifelse
        length(args) == 3 || error("ite expects 3 arguments")
        return "ifelse($(args[1]), $(args[2]), $(args[3]))"
    elseif op === :!
        length(args) == 1 || error("not expects 1 argument")
        return "(!$(args[1]))"
    elseif length(args) == 1
        return "($op $(args[1]))"               # unary minus
    elseif length(args) == 2
        return "($(args[1]) $op $(args[2]))"
    end
    error("operator `$head` with arity $(length(args)) is not supported")
end

"""
    build_grammar_from_sygus(spec; start_symbol=:Expr, mod=Main) -> ContextSensitiveGrammar

Build the grammar the SyGuS benchmark actually declares. Errors if the spec has
no grammar section — callers wanting the synthesized fallback should call
`build_grammar_from_spec` explicitly, so the choice is never silent.

!!! note "`HerbGrammar` must be visible in `mod`"
    The rules are assembled as source and expanded through `@csgrammar` in
    `mod` (default `Main`), so `mod` must have done `using HerbGrammar`.
    Otherwise every spec fails identically with
    `UndefVarError: HerbGrammar not defined in Main` — a spec-independent
    environment error, not a problem with the benchmark file.

The first Int-sorted non-terminal is named `start_symbol` (default `:Expr`) and
the first Bool-sorted one `:BoolExpr`; any further non-terminals keep sanitized
names. For a **predicate** synth-fun (return sort `Bool`, e.g. `IsSorted`) the
caller must pass `:BoolExpr` as the search's start symbol — see
`sygus_start_symbol`.
"""
function build_grammar_from_sygus(spec; start_symbol::Symbol=:Expr, mod::Module=Main)
    isempty(spec.synth_funs) && error("spec has no synth-fun")
    sfun = spec.synth_funs[1]
    nts, prods = parse_sygus_grammar(sfun)

    # Map SyGuS non-terminal names onto the symbols the pipeline expects,
    # keyed on *sort* rather than position: the start non-terminal is Bool for
    # predicate benchmarks (IsSorted, IsSeries), Int for the rest, and both
    # kinds need the Int non-terminal to be `start_symbol` and the Bool one
    # `:BoolExpr` regardless of declaration order.
    symmap = Dict{String,Symbol}()
    int_seen = false
    bool_seen = false
    for (name, sort) in nts
        if sort == "Bool" && !bool_seen
            symmap[name] = :BoolExpr
            bool_seen = true
        elseif sort != "Bool" && !int_seen
            symmap[name] = start_symbol
            int_seen = true
        else
            symmap[name] = Symbol("NT_", name)
        end
    end

    lines = ["begin"]
    for (name, _) in nts
        sym = symmap[name]
        for prod in prods[name]
            push!(lines, "    $sym = " * _sygus_production_to_rule(prod, symmap))
        end
    end
    push!(lines, "end")
    src = join(lines, "\n")

    # @csgrammar must be expanded where HerbGrammar is visible.
    return mod.eval(Meta.parse("HerbGrammar.@csgrammar $src"))
end

"""
    sygus_start_symbol(spec; start_symbol=:Expr) -> Symbol

Start symbol for searching this spec: `:BoolExpr` for a predicate synth-fun
(return sort `Bool`), otherwise `start_symbol`. The paper's LIA suite contains
both kinds (`IsSorted`/`IsSeries` are predicates, `Sum`/`Median` are not).
"""
sygus_start_symbol(spec; start_symbol::Symbol=:Expr)::Symbol =
    (!isempty(spec.synth_funs) && spec.synth_funs[1].sort == "Bool") ?
    :BoolExpr : start_symbol

"""
    build_grammar_auto(spec_path; prefer_sygus=true, start_symbol=:Expr)

Grammar for a spec file, preferring the benchmark's own SyGuS grammar and
falling back to the synthesized one when the spec declares none. Returns
`(grammar, source)` where `source` is `:sygus` or `:generated`, so callers can
report which search space a result was obtained in — the two are not
comparable.
"""
function build_grammar_auto(spec_path::String; prefer_sygus::Bool=true,
                            start_symbol::Symbol=:Expr, mod::Module=Main)
    spec = CEXGeneration.parse_spec_from_file(spec_path)
    if prefer_sygus && !isempty(spec.synth_funs) && spec.synth_funs[1].grammar !== nothing
        try
            return (build_grammar_from_sygus(spec; start_symbol=start_symbol, mod=mod), :sygus)
        catch e
            @warn "SyGuS grammar unusable, falling back to generated grammar" spec_path exception=e
        end
    end
    return (build_grammar_from_spec(spec_path; start_symbol=start_symbol), :generated)
end
