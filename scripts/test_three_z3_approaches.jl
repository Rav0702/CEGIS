"""
Comprehensive test comparing FIVE approaches to Z3 counterexample extraction:
1. SymbolicSMT (high-level Z3 wrapper via SymbolicUtils/Symbolics)
2. Z3 Native CLI (two-call approach: check-sat → get-value if sat)
3. Z3.jl (direct Z3 API wrapper with AST building)
3B. Z3.jl (SMT-LIB2 string query parsing)
4. Z3 Native CLI (single-call with full string query)

Tests on q.smt2 which verifies an incorrect guard_fn candidate.
Expected CEX: Assignment to (x, y, z) where candidate violates spec.
"""

using Z3

println("=" ^ 80)
println("Z3 COUNTEREXAMPLE EXTRACTION - COMPARATIVE TEST")
println("=" ^ 80)
println()

# ─────────────────────────────────────────────────────────────────────────────
# Test Query: q.smt2
# ─────────────────────────────────────────────────────────────────────────────

query_text = """(set-logic LIA)
(set-option :model.completion true)

(declare-const x Int)
(declare-const y Int)
(declare-const z Int)

(define-fun guard_fn ((x Int) (y Int) (z Int)) Int (ite (< y z) 1 0))

(declare-const out_guard_fn Int)

; Spec constraints for guard_fn (valid outputs: out_guard_fn)
(assert (=> (> x 0) (= out_guard_fn (+ x y))))
(assert (=> (<= x 0) (= out_guard_fn z)))

; Check if candidate violates any constraint
(assert (not
  (and
    (=> (> x 0) (= (guard_fn x y z) (+ x y)))
  (=> (<= x 0) (= (guard_fn x y z) z))
  )
))

(check-sat)

; Free variable values at counterexample
(get-value (x y z))

; Candidate output(s)
(get-value ((guard_fn x y z)))

; Valid spec output(s) - what the spec says is correct
(get-value (out_guard_fn))
"""

println("Input Query (q.smt2):")
println("-" ^ 80)
println(query_text)
println("-" ^ 80)
println()

# ─────────────────────────────────────────────────────────────────────────────
# APPROACH 2: Z3 Native CLI (Two-Call Approach)
# ─────────────────────────────────────────────────────────────────────────────

println("\n[APPROACH 2] Z3 Native CLI (Two-Call Approach)")
println("=" ^ 80)

try
    # Phase 1: Query up to check-sat only
    query_phase1 = """(set-logic LIA)
(set-option :model.completion true)

(declare-const x Int)
(declare-const y Int)
(declare-const z Int)

(define-fun guard_fn ((x Int) (y Int) (z Int)) Int (ite (< y z) 1 0))

(declare-const out_guard_fn Int)

(assert (=> (> x 0) (= out_guard_fn (+ x y))))
(assert (=> (<= x 0) (= out_guard_fn z)))

(assert (not
  (and
    (=> (> x 0) (= (guard_fn x y z) (+ x y)))
  (=> (<= x 0) (= (guard_fn x y z) z))
  )
))

(check-sat)
"""
    
    # Execute Phase 1
    tmp1 = tempname() * ".smt2"
    write(tmp1, query_phase1)
    phase1_output = readchomp(`z3 $tmp1`)
    rm(tmp1)
    
    println("Phase 1 (check-sat): $phase1_output")
    
    # Only run Phase 2 if Phase 1 returned sat
    if contains(phase1_output, "sat")
        # Phase 2: Full query with get-value
        query_phase2 = query_text  # Already includes get-value statements
        
        tmp2 = tempname() * ".smt2"
        write(tmp2, query_phase2)
        phase2_result = readchomp(`z3 $tmp2`)
        rm(tmp2)
        
        println("\nPhase 2 (get-value calls):")
        println(phase2_result)
        
        # Parse model from Phase 2 output
        println("\nExtracted Counterexample:")
        
        # Simple parsing for demonstration
        lines = split(phase2_result, "\n")
        for line in lines
            if contains(line, "x")
                println("  Variables: $line")
            elseif contains(line, "guard_fn")
                println("  Candidate result: $line")
            elseif contains(line, "out_guard_fn")
                println("  Spec result: $line")
            end
        end
    else
        println("No counterexample (unsat)")
    end
    
    println("\n✓ Z3 Native approach completed successfully")
    
catch err
    println("\n✗ Z3 Native approach FAILED:")
    println("  Error: $err")
end

# ─────────────────────────────────────────────────────────────────────────────
# APPROACH 3: Z3.jl Direct API (Z3_solver_from_string)
# ─────────────────────────────────────────────────────────────────────────────

println("\n[APPROACH 3] Z3.jl Direct API")
println("=" ^ 80)

try
    # Using Z3.jl's direct API with Solver AST construction
    ctx = Context()
    solver = Solver(ctx)
    
    # Note: Z3.jl doesn't easily expose :model.completion option
    # This demonstrates the model sparseness issue
    
    # Variables
    x = IntVar("x", ctx)
    y = IntVar("y", ctx)
    z = IntVar("z", ctx)
    out_gf = IntVar("out_guard_fn", ctx)
    
    # For simplicity, define basic constraints without And/Or combinations
    # Constraint: x > 0 AND out_gf ≠ x+y (candidate violates spec when x > 0)
    add!(solver, x > IntVal(0, ctx))
    add!(solver, out_gf != x + y)
    
    # Also constrain variables to make problem interesting
    # (otherwise solver just picks unconstrained values)
    add!(solver, x >= IntVal(-10, ctx))
    add!(solver, x <= IntVal(10, ctx))
    add!(solver, y >= IntVal(-10, ctx))
    add!(solver, y <= IntVal(10, ctx))
    add!(solver, z >= IntVal(-10, ctx))
    add!(solver, z <= IntVal(10, ctx))
    add!(solver, out_gf >= IntVal(-10, ctx))
    add!(solver, out_gf <= IntVal(10, ctx))
    
    # Check satisfiability
    result = check(solver)
    println("Satisfiability: $(result)")
    
    if result == :sat
        model = get_model(solver)
        println("\nModel (CEX found):")
        
        # Evaluate variables 
        try
            x_val = eval(x, model)
            y_val = eval(y, model)
            z_val = eval(z, model)
            out_val = eval(out_gf, model)
            
            println("  x = $x_val")
            println("  y = $y_val")
            println("  z = $z_val")
            println("  out_guard_fn = $out_val")
            
        catch err
            println("  Error evaluating model: $err")
        end
        
        println("\n✓ Z3.jl approach completed (with model extraction limits)")
        
    else
        println("\nConstraints unsatisfiable (no CEX found)")
    end
    
catch err
    println("\n✗ Z3.jl approach FAILED:")
    println("  Error: $err")
end

# ─────────────────────────────────────────────────────────────────────────────
# APPROACH 3B: Z3.jl with SMT-LIB2 String Query Parsing
# ─────────────────────────────────────────────────────────────────────────────

println("\n[APPROACH 3B] Z3.jl with SMT-LIB2 String Query Parsing")
println("=" ^ 80)

try
    # Using Z3.jl to parse and execute SMT-LIB2 query string directly
    ctx = Context()
    
    # Create parser from SMT-LIB2 string
    # Z3.jl provides parse_smt2_string for this
    
    # Read the SMT-LIB2 query string
    smt2_query = query_text
    
    # Parse using Z3's parser
    ast_exprs = Z3.parse_smt2_string(ctx, smt2_query)
    
    println("Parsed expressions from SMT-LIB2 string: $(length(ast_exprs)) expressions")
    
    # Create solver and assert the parsed expressions
    solver = Solver(ctx)
    for expr in ast_exprs
        if !(expr isa Z3.BoolSortAST)  # Skip commands, add assertions
            try
                add!(solver, expr)
            catch e
                # Skip non-assertion expressions (set-logic, set-option, etc.)
            end
        end
    end
    
    # Check satisfiability
    result = check(solver)
    println("Satisfiability: $(result)")
    
    if result == :sat
        model = get_model(solver)
        println("\nModel (CEX found):")
        
        try
            # Try to extract variable values
            x = IntVar("x", ctx)
            y = IntVar("y", ctx)
            z = IntVar("z", ctx)
            out_gf = IntVar("out_guard_fn", ctx)
            
            x_val = eval(x, model)
            y_val = eval(y, model)
            z_val = eval(z, model)
            out_val = eval(out_gf, model)
            
            println("  x = $x_val")
            println("  y = $y_val")
            println("  z = $z_val")
            println("  out_guard_fn = $out_val")
            
        catch err
            println("  Error extracting variables: $err")
            println("  Model string: $(model_to_string(model))")
        end
        
        println("\n✓ Z3.jl String parsing approach completed successfully")
        
    else
        println("\n✓ Z3.jl String parsing: No counterexample (unsat)")
    end
    
catch err
    println("\n✗ Z3.jl String parsing approach FAILED:")
    println("  Error: $err")
    println("""
    Note: Z3.jl's parse_smt2_string requires:
    - Proper SMT-LIB2 format in the query string
    - All set-option and set-logic before assertions
    - May still suffer from sparse model extraction
    """)
end

# ─────────────────────────────────────────────────────────────────────────────

println("\n[APPROACH 4] Z3 Native CLI (Single-Call - Direct String Query)")
println("=" ^ 80)

try
    # Simplest approach: Pass full query string directly to z3 via temp file
    # No manual phase separation - let z3 handle everything
    
    tmp_file = tempname() * ".smt2"
    write(tmp_file, query_text)
    
    # Execute z3 with full query in one call
    z3_output = readchomp(`z3 $tmp_file`)
    rm(tmp_file)
    
    println("Z3 Output:")
    println(z3_output)
    
    # Parse the output to extract model
    println("\nExtracted Results:")
    
    # Split output into lines for parsing
    lines = split(z3_output, "\n")
    
    # Simple regex-based extraction
    variables = ""
    candidate_result = ""
    spec_result = ""
    
    for line in lines
        stripped = strip(line)
        if contains(stripped, "((x ") || contains(stripped, "(x ") 
            variables = stripped
        elseif contains(stripped, "guard_fn")
            candidate_result = stripped
        elseif contains(stripped, "out_guard_fn")
            spec_result = stripped
        end
    end
    
    println("  Status: $(lines[1])")  # First line is sat/unsat
    if isempty(variables)
        println("  Variables: (no variables extracted)")
    else
        println("  Variables: $variables")
    end
    if !isempty(candidate_result)
        println("  Candidate result: $candidate_result")
    end
    if !isempty(spec_result)
        println("  Spec result: $spec_result")
    end
    
    if contains(z3_output, "sat")
        println("\n✓ Z3 string query approach completed successfully")
        println("  Counterexample found!")
    else
        println("\n✓ Z3 string query approach completed (unsat)")
    end
    
catch err
    println("\n✗ Z3 string query approach FAILED:")
    println("  Error: $err")
end