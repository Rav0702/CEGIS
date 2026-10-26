#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
LOG=results/full_tests.log
: > "$LOG"
echo "START $(date -u +%FT%TZ)" >> "$LOG"
julia --project=. test/runtests.jl >> "$LOG" 2>&1
echo "TESTS-DONE $? $(date -u +%FT%TZ)" >> "$LOG"
