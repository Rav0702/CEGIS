"""
S-expression reader and writer for SMT-LIB2 / SyGuS-v2 format.
"""

"""Tokenize text into s-expression tokens."""
function tokenise_sexp(text::String)::Vector{String}
    text = replace(text, r";[^\n]*" => "")   # Strip line comments
    tokens = String[]
    i = 1; n = length(text)
    while i <= n
        c = text[i]
        if isspace(c)
            i += 1
        elseif c ∈ ('(', ')')
            push!(tokens, string(c)); i += 1
        elseif c == '"'                       # Quoted string
            j = i + 1
            while j <= n
                text[j] == '"'  && (j += 1; break)
                text[j] == '\\' && (j += 1)
                j += 1
            end
            push!(tokens, text[i:j-1]); i = j
        elseif c == '|'                       # Quoted symbol
            j = i + 1
            while j <= n && text[j] != '|'; j += 1; end
            push!(tokens, text[i:j]); i = j + 1
        else
            j = i
            while j <= n && !isspace(text[j]) && text[j] ∉ ('(', ')', '"', '|')
                j += 1
            end
            tok = text[i:j-1]
            isempty(tok) || push!(tokens, tok)
            i = j
        end
    end
    tokens
end

"""Read s-expressions from text."""
function read_sexprs(text::String)::Vector{Any}
    toks = tokenise_sexp(text)
    pos  = Ref(1)
    out  = Any[]
    while pos[] <= length(toks)
        push!(out, _read1(toks, pos))
    end
    out
end

"""Parse a single s-expression."""
function _read1(toks::Vector{String}, pos::Ref{Int})::Any
    pos[] > length(toks) && error("Unexpected EOF in s-expression")
    t = toks[pos[]]; pos[] += 1
    if t == "("
        lst = Any[]
        while true
            pos[] > length(toks) && error("Unclosed '('")
            toks[pos[]] == ")" && (pos[] += 1; break)
            push!(lst, _read1(toks, pos))
        end
        return lst
    elseif t == ")"
        error("Unexpected ')' near token $(pos[]-1)")
    else
        return t
    end
end

"""Convert s-expression (nested Vector/String) to string."""
function sexp_to_str(s)::String
    if s isa String
        return s
    elseif s isa Vector
        return isempty(s) ? "()" : "(" * join(sexp_to_str.(s), " ") * ")"
    else
        return string(s)
    end
end
