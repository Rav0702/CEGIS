#!/usr/bin/env bash
# RQ1_RQ2_PLAN.md §7.12: non-GP reference and GA ablation on the 4 specs, in its own console.
cd "$(dirname "$0")/.." || exit 1
LOG=results/recipe_arms.log
: > "$LOG"
SPECS=countpos4.split,array_search4,above4,max6
run() { echo "START $* $(date -u +%FT%TZ)" >> "$LOG"; julia bench/run.jl "$@" >> "$LOG" 2>&1; echo "END $? $(date -u +%FT%TZ)" >> "$LOG"; }
run --arm recipe-cegis     --name main-recipe-cegis     --specs $SPECS --seeds 1:66 --jobs 4
run --arm lex-recipes-only --name main-recipes-only     --specs $SPECS --seeds 1:66 --jobs 4
echo "ARMS-DONE" >> "$LOG"
