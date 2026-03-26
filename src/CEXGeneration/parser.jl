"""
Parser for SyGuS-v2 (.sl) specifications to Spec data structures.

Handles:
  - Logical context (QF_LIA, QF_UFLIA, etc.)
  - Declare-var for free variables
  - Synth-fun synthesis targets with parameter declarations
  - Inv-constraint expansions (primed variables, verification conditions)
  - Constraint assertions
"""

"""Parse a .sl file (SyGuS-v2 format) to a Spec object."""
function parse_sl(filename::String)::Spec
    content = open(filename) do f
        read(f, String)
    end

    exprs = read_sexprs(content)
    spec = Spec()

    i = 1
    while i <= length(exprs)
        expr = exprs[i]
        if !isa(expr, Vector)
            i += 1; continue
        end
        if length(expr) == 0
            i += 1; continue
        end

        head = expr[1]
        if !isa(head, String)
            i += 1; continue
        end

        if head == "set-logic"
            spec.logic = String(expr[2])

        elseif head == "declare-var"
            name = String(expr[2])
            sort = String(expr[3])
            push!(spec.free_vars, FreeVar(name, sort))

        elseif head == "synth-fun"
            name = String(expr[2])
            params_expr = expr[3]
            ret_sort = String(expr[4])

            # Parse parameters: ((y1 Int) (y2 Int) ...) or ()
            params = Tuple{String,String}[]
            if isa(params_expr, Vector)
                for param_expr in params_expr
                    if isa(param_expr, Vector) && length(param_expr) == 2
                        pn = String(param_expr[1])
                        ps = String(param_expr[2])
                        push!(params, (pn, ps))
                    end
                end
            end

            push!(spec.synth_funs, SynthFun(name, params, ret_sort))

        elseif head == "constraint"
            if length(expr) > 1
                constr = sexp_to_str(expr[2])
                push!(spec.constraints, constr)
            end

        elseif head == "inv-constraint"
            # Handle invariant constraints: (inv-constraint inv pre post trans)
            if length(expr) >= 5
                inv_name = String(expr[2])
                pre_name = String(expr[3])
                post_expr = expr[4]
                post_name = isa(post_expr, Vector) ? sexp_to_str(post_expr) : String(post_expr)
                trans_expr = expr[5]
                trans = isa(trans_expr, Vector) ? sexp_to_str(trans_expr) : String(trans_expr)

                # Find the invariant synthesis function to get its parameters
                inv_found = false
                for sfun in spec.synth_funs
                    if sfun.name == inv_name
                        inv_found = true
                        params = sfun.params

                        # Build pre-condition: inv(x) => ¬pre(x)
                        inv_call = "(" * inv_name
                        for (pname, _) in params
                            inv_call *= " " * pname
                        end
                        inv_call *= ")"

                        pre_constr = "(=> $inv_call (not ($pre_name "
                        pre_constr *= join([pname for (pname, _) in params], " ")
                        pre_constr *= ")))"
                        push!(spec.constraints, pre_constr)

                        # Build transition: inv(x) ∧ trans(x,x') => inv(x')
                        trans_constr = "(=> (and $inv_call ($trans "
                        trans_constr *= join([pname for (pname, _) in params], " ")
                        trans_constr *= " "
                        trans_constr *= join([pname * "'" for (pname, _) in params], " ")
                        trans_constr *= ")) (" * inv_name
                        trans_constr *= " "
                        trans_constr *= join([pname * "'" for (pname, _) in params], " ")
                        trans_constr *= "))"
                        push!(spec.constraints, trans_constr)

                        # Build post-condition: inv(x) => ¬post(x) or inv(x) => post(x)
                        if isa(post_name, String) && startswith(post_name, "(not ")
                            post_constr = "(=> $inv_call $post_name)"
                        else
                            post_constr = "(=> $inv_call (not ($post_name "
                            post_constr *= join([pname for (pname, _) in params], " ")
                            post_constr *= ")))"
                        end
                        push!(spec.constraints, post_constr)

                        break
                    end
                end
            end
        end

        i += 1
    end

    spec
end
