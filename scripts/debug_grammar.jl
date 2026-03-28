using HerbCore, HerbGrammar

# Recreate to see rule 11 definition
grammar_str = """
@csgrammar begin
    Expr = y | x | 0 | 1 | 2 | -1
    Expr = ifelse(Expr, Expr, Expr)
    Expr = (Expr + Expr)
    Expr = (Expr - Expr)
    Expr = (Expr * Expr)
    Expr = (Expr < Expr)
    Expr = (Expr > Expr)
    Expr = (Expr <= Expr)
    Expr = (Expr >= Expr)
    Expr = (Expr == Expr)
end
"""
expr = Meta.parse(grammar_str)
grammar = Core.eval(Main, expr)

println("Grammar rules:")
for i in 1:length(grammar.rules)
    rule = collect(grammar.rules[i])
    println("Rule $i: $rule")
end

# Show what RuleNode 11{4,1} produces
node = RuleNode(11, [RuleNode(4), RuleNode(1)])
candidate_expr = HerbGrammar.rulenode2expr(node, grammar)
println("\nRuleNode 11{4,1} -> $(candidate_expr) -> $(string(candidate_expr))")
