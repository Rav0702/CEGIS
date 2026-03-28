using HerbCore, HerbGrammar

# Manually create the exact grammar that's being generated
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

println("Total rules: $(length(grammar.rules))")
println("\nFirst few rules:")
for i in 1:min(15, length(grammar.rules))
    rule = grammar.rules[i]
    println("  Rule $(i): $rule")
end

# Try to reconstruct the problematic RuleNode
println("\n\nTesting RuleNode 11{4,1}:")
node = RuleNode(11, [RuleNode(4), RuleNode(1)])
expr = HerbGrammar.rulenode2expr(node, grammar)
println("  Expression: $expr")
println("  String: $(string(expr))")

# Also test individual nodes
println("\n\nTesting individual nodes:")
for rule_id in 1:6
    node = RuleNode(rule_id)
    expr = HerbGrammar.rulenode2expr(node, grammar)
    println("  Rule $rule_id: $expr")
end
