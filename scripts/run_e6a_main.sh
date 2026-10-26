#!/usr/bin/env bash
# spec_knowledge/EXPERIMENTS.md E6a main stage: baseline-lex on tiered3, orig / case / caseguard / decoy, seeds 1-66.
# Sequential, in its own console; nothing else heavy meanwhile; do not edit src/ or bench/ while it runs.
cd "$(dirname "$0")/.." || exit 1
LOG=results/e6a_main.log
: > "$LOG"
run() { echo "START $* $(date -u +%FT%TZ)" >> "$LOG"; julia bench/run.jl "$@" >> "$LOG" 2>&1; echo "END $? $(date -u +%FT%TZ)" >> "$LOG"; }
run --arm baseline-lex --name main-e6a-orig      --specs tiered3 --seeds 1:66 --jobs 4
run --arm baseline-lex --name main-e6a-case      --specs tiered3 --seeds 1:66 --jobs 4 --variant case
run --arm baseline-lex --name main-e6a-caseguard --specs tiered3 --seeds 1:66 --jobs 4 --variant caseguard
run --arm baseline-lex --name main-e6a-decoy     --specs tiered3 --seeds 1:66 --jobs 4 --variant decoy
echo "E6A-MAIN-DONE $(date -u +%FT%TZ)" >> "$LOG"
