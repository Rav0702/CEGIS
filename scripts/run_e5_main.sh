#!/usr/bin/env bash
# spec_knowledge/EXPERIMENTS.md E5: knowledge granularity. baseline-lex on the atoms / blocks grammars and their inert
# placebos (primary arms first), then orig, guard and case rerun in this session so every arm shares the machine
# load. Seeds 1-66, four workers per spec.
# Sequential, in its own console; nothing else heavy meanwhile; do not edit src/ or bench/ while it runs.
cd "$(dirname "$0")/.." || exit 1
LOG=results/e5_main.log
echo "LAUNCH $(date -u +%FT%TZ)" >> "$LOG"
SPECS=above4,array_search4,max6.sygus
run() { echo "START $* $(date -u +%FT%TZ)" >> "$LOG"; julia bench/run.jl "$@" >> "$LOG" 2>&1; echo "END $? $(date -u +%FT%TZ)" >> "$LOG"; }
run --arm baseline-lex --name e5-blocks      --specs $SPECS --seeds 1:66 --jobs 4 --shards 4 --variant blocks
run --arm baseline-lex --name e5-blocksinert --specs $SPECS --seeds 1:66 --jobs 4 --shards 4 --variant blocksinert
run --arm baseline-lex --name e5-atoms       --specs $SPECS --seeds 1:66 --jobs 4 --shards 4 --variant atoms
run --arm baseline-lex --name e5-atomsinert  --specs $SPECS --seeds 1:66 --jobs 4 --shards 4 --variant atomsinert
run --arm baseline-lex --name e5-orig        --specs $SPECS --seeds 1:66 --jobs 4 --shards 4
run --arm baseline-lex --name e5-guard       --specs $SPECS --seeds 1:66 --jobs 4 --shards 4 --variant guard
run --arm baseline-lex --name e5-case        --specs $SPECS --seeds 1:66 --jobs 4 --shards 4 --variant case
echo "E5-DONE $(date -u +%FT%TZ)" >> "$LOG"
