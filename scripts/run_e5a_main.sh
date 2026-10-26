#!/usr/bin/env bash
# spec_knowledge/EXPERIMENTS.md E5a: what is the guard alone worth? baseline-lex on orig / inert / scrambled /
# guard / case grammars, seeds 1-66 (primary arms first), then the exploratory countpos4.split row at depth cap 19.
# Sequential, in its own console; nothing else heavy meanwhile; do not edit src/ or bench/ while it runs.
cd "$(dirname "$0")/.." || exit 1
LOG=results/e5a_main.log
: > "$LOG"
SPECS=above4,array_search4,max6.sygus
run() { echo "START $* $(date -u +%FT%TZ)" >> "$LOG"; julia bench/run.jl "$@" >> "$LOG" 2>&1; echo "END $? $(date -u +%FT%TZ)" >> "$LOG"; }
run --arm baseline-lex --name e5a-guard     --specs $SPECS --seeds 1:66 --jobs 4 --variant guard
run --arm baseline-lex --name e5a-inert     --specs $SPECS --seeds 1:66 --jobs 4 --variant inert
run --arm baseline-lex --name e5a-scrambled --specs above4,max6.sygus --seeds 1:66 --jobs 4 --variant guarddecoy
run --arm baseline-lex --name e5a-orig      --specs $SPECS --seeds 1:66 --jobs 4
run --arm baseline-lex --name e5a-case      --specs $SPECS --seeds 1:66 --jobs 4 --variant case
echo "E5A-MAIN-DONE $(date -u +%FT%TZ)" >> "$LOG"
run --arm baseline-lex --name e5a-cp-orig-cap19  --specs countpos4.split --seeds 1001:1020 --jobs 4 --depth-cap 19
run --arm baseline-lex --name e5a-cp-guard-cap19 --specs countpos4.split --seeds 1001:1020 --jobs 4 --depth-cap 19 --variant guard
run --arm baseline-lex --name e5a-cp-case-cap19  --specs countpos4.split --seeds 1001:1020 --jobs 4 --depth-cap 19 --variant case
echo "E5A-DONE $(date -u +%FT%TZ)" >> "$LOG"
