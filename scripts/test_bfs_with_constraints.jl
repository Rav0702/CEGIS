#!/usr/bin/env julia
"""
Test script: BFS Iterator with HerbConstraints for max2 and max3

This script tests the BFS iterator with common constraints that speed up search:
1. Forbidden(x + 0) - Avoid identity element addition
2. Forbidden(x * 1) - Avoid identity element multiplication  
3. Forbidden(0 + x) - Commutative symmetry breaking for addition
4. Forbidden(1 * x) - Commutative symmetry breaking for multiplication
5. Ordered(x + y) - Enforce left <= right ordering on commutative operations
6. Ordered(x * y) - Enforce left <= right ordering on multiplication
7. Ordered(ifelse conds) - Symmetry breaking for ifelse comparisons

These constraints prune the search space by:
- Eliminating redundant operations (identity elements)
- Breaking symmetry in commutative operations
- Reducing equivalent program variations
"""

CEGIS_ROOT = dirname(@__DIR__)
CEGIS_SRC = joinpath(CEGIS_ROOT, "src")
push!(LOAD_PATH, CEGIS_SRC)

using HerbCore, HerbGrammar, HerbSearch, HerbSpecification, HerbInterpret, HerbConstraints
include(joinpath(CEGIS_SRC, "CEGIS.jl"))

const SPEC_DIR = joinpath(CEGIS_ROOT, "spec_files", "phase3_benchmarks")

const BENCHMARKS = Dict(
    "max2" => (path = joinpath(SPEC_DIR, "max2_simple.sl"), expected = "ifelse(x0 > x1, x0, x1)"),
    "max3" => (path = joinpath(SPEC_DIR, "max3_simple.sl"), expected = "ifelse(x > y, ifelse(x > z, x, z), ifelse(y > z, y, z))"),
)

# Use type-aware parser that handles Bool→Int coercion automatically
CEGIS.CEXGeneration.set_default_candidate_parser(CEGIS.CEXGeneration.SymbolicCandidateParser())

# Conversion mode toggle
const USE_DIRECT_RULENODE_TO_SMT2 = true

# BFS Iterator configuration
const MAX_DEPTH = 5
const MAX_SIZE = 20

function add_pruning_constraints!(grammar)
    """
    Add common pruning constraints to the grammar.
    These constraints help speed up search by eliminating symmetric and redundant program variants.
    
    Constraints added:
    1. Forbidden(x + 0) - Don't enumerate addition with 0 constant on right
    2. Forbidden(0 + x) - Symmetry breaking: prevent 0 + x (only allow x + 0 eliminated above)
    3. Forbidden(x * 1) - Don't enumerate multiplication with 1 constant on right
    4. Forbidden(1 * x) - Symmetry breaking: prevent 1 * x (only allow x * 1 eliminated above)
    5. Ordered(x + y) - Enforce x <= y ordering on addition (both operands)
    6. Ordered(x * y) - Enforce x <= y ordering on multiplication (both operands)
    7. Forbidden(x - x) - Eliminate subtraction of identical operands
    """
    
    # Find rule indices by matching expressions
    add_rule_idx = nothing
    mul_rule_idx = nothing
    sub_rule_idx = nothing
    const_0_idx = nothing
    const_1_idx = nothing
    
    for (idx, rule) in enumerate(grammar.rules)
        if rule isa Expr
            if rule.head == :call && length(rule.args) == 3
                op = rule.args[1]
                if op == :+
                    add_rule_idx = idx
                elseif op == :*
                    mul_rule_idx = idx
                elseif op == :-
                    sub_rule_idx = idx
                end
            end
        elseif rule == 0
            const_0_idx = idx
        elseif rule == 1
            const_1_idx = idx
        end
    end
    
    constraints_added = []
    
    if !isnothing(add_rule_idx) && !isnothing(const_0_idx)
        try
            # Constraint 1: Forbidden(x + 0)
            forbidden_add_zero = Forbidden(RuleNode(add_rule_idx, [
                VarNode(:a),
                RuleNode(const_0_idx, [])
            ]))
            addconstraint!(grammar, forbidden_add_zero)
            push!(constraints_added, "Forbidden(x + 0)")
        catch e
            println("      Warning: Could not add Forbidden(x + 0): $e")
        end
        
        try
            # Constraint 2: Forbidden(0 + x) - symmetry breaking
            forbidden_zero_add = Forbidden(RuleNode(add_rule_idx, [
                RuleNode(const_0_idx, []),
                VarNode(:b)
            ]))
            addconstraint!(grammar, forbidden_zero_add)
            push!(constraints_added, "Forbidden(0 + x)")
        catch e
            println("      Warning: Could not add Forbidden(0 + x): $e")
        end
        
        try
            # Constraint 5: Ordered(x + y) - enforce ordering
            ordered_add = Ordered(RuleNode(add_rule_idx, [
                VarNode(:a),
                VarNode(:b)
            ]), [:a, :b])
            addconstraint!(grammar, ordered_add)
            push!(constraints_added, "Ordered(x + y)")
        catch e
            println("      Warning: Could not add Ordered(x + y): $e")
        end
    end
    
    if !isnothing(mul_rule_idx) && !isnothing(const_1_idx)
        try
            # Constraint 3: Forbidden(x * 1)
            forbidden_mul_one = Forbidden(RuleNode(mul_rule_idx, [
                VarNode(:a),
                RuleNode(const_1_idx, [])
            ]))
            addconstraint!(grammar, forbidden_mul_one)
            push!(constraints_added, "Forbidden(x * 1)")
        catch e
            println("      Warning: Could not add Forbidden(x * 1): $e")
        end
        
        try
            # Constraint 4: Forbidden(1 * x) - symmetry breaking
            forbidden_one_mul = Forbidden(RuleNode(mul_rule_idx, [
                RuleNode(const_1_idx, []),
                VarNode(:b)
            ]))
            addconstraint!(grammar, forbidden_one_mul)
            push!(constraints_added, "Forbidden(1 * x)")
        catch e
            println("      Warning: Could not add Forbidden(1 * x): $e")
        end
        
        try
            # Constraint 6: Ordered(x * y) - enforce ordering
            ordered_mul = Ordered(RuleNode(mul_rule_idx, [
                VarNode(:a),
                VarNode(:b)
            ]), [:a, :b])
            addconstraint!(grammar, ordered_mul)
            push!(constraints_added, "Ordered(x * y)")
        catch e
            println("      Warning: Could not add Ordered(x * y): $e")
        end
    end
    
    if !isnothing(sub_rule_idx)
        try
            # Constraint 7: Forbidden(x - x) - eliminate self-subtraction
            forbidden_sub_self = Forbidden(RuleNode(sub_rule_idx, [
                VarNode(:a),
                VarNode(:a)
            ]))
            addconstraint!(grammar, forbidden_sub_self)
            push!(constraints_added, "Forbidden(x - x)")
        catch e
            println("      Warning: Could not add Forbidden(x - x): $e")
        end
    end
    
    return constraints_added
end

results = []
for (name, config) in BENCHMARKS
    try
        println(">>>> Testing $name (BFS with Constraints)")
        if config.expected !== nothing
            println("      Expected: $(config.expected)")
        else
            println("      Expected: TBD (will check with Z3)")
        end
        
        problem = CEGIS.CEGISProblem(
            config.path;
            desired_solution = config.expected,
        )
        grammar = CEGIS.build_grammar_from_spec(config.path)
        
        # Add pruning constraints to grammar
        constraints_added = add_pruning_constraints!(grammar)
        println("      Constraints added:")
        for (i, constraint) in enumerate(constraints_added)
            println("        $i. $constraint")
        end
        
        # Create BFS iterator with max_depth
        iterator = CEGIS.IteratorConfig.create_iterator(
            CEGIS.IteratorConfig.BFSIteratorConfig(max_depth=MAX_DEPTH),
            grammar,
            :Expr
        )
        
        result = CEGIS.run_synthesis(
            problem, iterator;
            max_enumerations = 1_000_0000,
            use_direct_conversion = USE_DIRECT_RULENODE_TO_SMT2,
        )
        
        status_str = "$(result.status)"
        verified = status_str == "cegis_success"

        if result.program !== nothing
            solution_expr = HerbGrammar.rulenode2expr(result.program, grammar)
            solution_str = string(solution_expr)
            println("      Candidate: $solution_str")
            push!(results, (
                name=name, 
                status=status_str, 
                iters=result.iterations, 
                found=verified, 
                solution=solution_str, 
                expected=config.expected,
                constraints=length(constraints_added)
            ))
        else
            println("      Candidate: NONE")
            push!(results, (
                name=name, 
                status=status_str, 
                iters=result.iterations, 
                found=false, 
                solution=nothing, 
                expected=config.expected,
                constraints=length(constraints_added)
            ))
        end
        println()
    catch e
        println("      ERROR: $e")
        println("      Stack trace: $(stacktrace(catch_backtrace()))\n")
        push!(results, (
            name=name, 
            status="ERROR", 
            iters=0, 
            found=false, 
            solution=nothing, 
            expected=config.expected,
            constraints=0
        ))
    end
end

println("\n" * "="^70)
println("SUMMARY (BFS with Constraints):")
println("="^70)
for r in results
    found_str = r.found ? "✓" : "✗"
    expected_str = r.expected !== nothing ? r.expected : "TBD"
    match_str = ""
    if r.found && r.expected !== nothing
        match_str = r.solution == r.expected ? "MATCH ✓" : "MISMATCH ✗"
    end
    println("  $found_str (name = \"$(r.name)\", status = \"$(r.status)\", iters = $(r.iters), constraints = $(r.constraints), found = $(r.found))")
    if r.solution !== nothing
        label = r.found ? "Found" : "Best"
        println("      $label:     $(r.solution)")
    end
    if r.found
        println("      Expected: $expected_str $match_str")
    elseif r.expected !== nothing
        println("      Expected: $expected_str")
    end
end
success_count = sum(r.found for r in results)
println("\nSolutions found: $success_count / $(length(results))")
println("="^70)
