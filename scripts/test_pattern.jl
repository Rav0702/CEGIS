#!/usr/bin/env julia

# Test pattern matching for invalid candidates
test_cases = [
    ("0y", true, "should match digit-letter"),
    ("y0", true, "should match letter-digit"),
    ("x", false, "should not match single letter"),
    ("123", false, "should not match numbers only"),
    ("0", false, "should not match single digit"),
    ("x + y", false, "should not match with operators"),
    ("0x1", true, "should match digit-letter-digit"),
    ("xy", false, "should not match letter-letter"),
    ("01", false, "should not match digit-digit")
]

println("Testing pattern for invalid candidates:")
for (candidate, should_match, desc) in test_cases
    matches = occursin(r"[0-9][a-zA-Z]|[a-zA-Z][0-9]", candidate)
    status = matches == should_match ? "✓" : "✗"
    println("  $status '$candidate': $matches (expected $should_match) - $desc")
end
