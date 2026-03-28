"""
    stub_oracle.jl

Stub oracle for testing and rapid prototyping.

StubOracle always reports success (no counterexamples found), allowing synthesis
to run without a full oracle implementation. Useful for testing the synthesis
pipeline before implementing formal verification backends.
"""

"""
    struct StubOracle <: AbstractOracle

Stub oracle that reports no counterexamples.

This oracle is used for testing and rapid prototyping. It always reports that
candidates are valid (no counterexamples found), allowing the synthesis loop
to terminate when a candidate is found or exploration completes.

**When to use**:
- Testing the synthesis pipeline without oracle implementation
- Rapid prototyping before formal verification backend is ready
- Benchmarking grammar building and search strategies

**Note**: The StubOracle does NOT verify correctness. It should only be used
for testing purposes.
"""
struct StubOracle <: AbstractOracle
    description :: String
    
    function StubOracle(description::String = "Testing/Stub Oracle")
        new(description)
    end
end

"""
    extract_counterexample(oracle::StubOracle, problem, candidate) -> Nothing

Stub oracle always returns `nothing` (no counterexample found).

This allows any candidate to be considered valid, enabling synthesis loops
to run without formal verification backend implementation.
"""
function extract_counterexample(
    oracle :: StubOracle,
    problem,
    candidate,
) :: Union{Counterexample, Nothing}
    # Stub oracle: always reports success (no counterexample)
    return nothing
end

"""Create a StubOracle for testing."""
StubOracle() = StubOracle("Testing/Stub Oracle")
