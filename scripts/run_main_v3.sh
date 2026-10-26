#!/usr/bin/env bash
# Main comparison baseline-lex vs lex-guided-v3 (RQ1_RQ2_PLAN.md §7.10b), in its own console.
cd "$(dirname "$0")/.." || exit 1
LOG=results/main_v3.log
: > "$LOG"
SPECS=countpos4.split,array_search4,above4,max6
run() { echo "START $* $(date -u +%FT%TZ)" >> "$LOG"; julia bench/run.jl "$@" >> "$LOG" 2>&1; echo "END $? $(date -u +%FT%TZ)" >> "$LOG"; }
run --arm baseline-lex  --name main-lex       --specs $SPECS --seeds 1:66 --jobs 4
run --arm lex-guided-v3 --name main-guided-v3 --specs $SPECS --seeds 1:66 --jobs 4
echo "MAIN-DONE" >> "$LOG"
