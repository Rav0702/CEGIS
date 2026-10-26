#!/usr/bin/env bash
# Calibrate baseline-lex on spec `tiered3` (seeds 1001-1020, cap 300 s); then: python scripts/pick_budget.py cal-tiered3-lex tiered3
cd "$(dirname "$0")/.." || exit 1
LOG=results/cal_tiered3.log
: > "$LOG"
echo "START $(date -u +%FT%TZ)" >> "$LOG"
julia bench/run.jl --arm baseline-lex --name cal-tiered3-lex --specs tiered3 --seeds 1001:1020 --jobs 4 >> "$LOG" 2>&1
echo "CAL-DONE $? $(date -u +%FT%TZ)" >> "$LOG"
