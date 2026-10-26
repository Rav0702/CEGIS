#!/usr/bin/env bash
# spec_knowledge/EXPERIMENTS.md E4: spec knowledge as seeds of the first population. baseline-lex with 40 seeded
# programs (guard / inert / partial / full) or none, seeds 1-66 (primary arms first), then the exploratory
# no-parsimony block on seeds 1001-1020.
# Sequential, in its own console; nothing else heavy meanwhile; do not edit src/ or bench/ while it runs.
# --shards 4: four workers per spec. With the default (one per spec for 4 specs and 4 jobs) tiered3's 66 seeds ran one
# after another while the other workers idled; the first attempt was stopped and resumed with this on 2026-10-23
# (spec_knowledge/EXPERIMENTS.md, E4). The log is appended to, so it keeps both attempts.
cd "$(dirname "$0")/.." || exit 1
LOG=results/e4_main.log
echo "LAUNCH --shards 4 $(date -u +%FT%TZ)" >> "$LOG"
SPECS=above4,array_search4,max6.sygus,tiered3
run() { echo "START $* $(date -u +%FT%TZ)" >> "$LOG"; julia bench/run.jl "$@" >> "$LOG" 2>&1; echo "END $? $(date -u +%FT%TZ)" >> "$LOG"; }
run --arm lex-init-guard   --name e4-guard   --specs $SPECS --seeds 1:66 --jobs 4 --shards 4
run --arm lex-init-inert   --name e4-inert   --specs $SPECS --seeds 1:66 --jobs 4 --shards 4
run --arm baseline-lex     --name e4-none    --specs $SPECS --seeds 1:66 --jobs 4 --shards 4
run --arm lex-init-partial --name e4-partial --specs $SPECS --seeds 1:66 --jobs 4 --shards 4
run --arm lex-init-full    --name e4-full    --specs $SPECS --seeds 1:66 --jobs 4 --shards 4
echo "E4-MAIN-DONE $(date -u +%FT%TZ)" >> "$LOG"
run --arm baseline-lex   --name e4x-none-nopars  --specs $SPECS   --seeds 1001:1020 --jobs 4 --shards 4 --set parsimony=false
run --arm lex-init-guard --name e4x-guard-nopars --specs $SPECS   --seeds 1001:1020 --jobs 4 --shards 4 --set parsimony=false
run --arm lex-init-full  --name e4x-full-nopars  --specs tiered3  --seeds 1001:1020 --jobs 4 --shards 4 --set parsimony=false
echo "E4-DONE $(date -u +%FT%TZ)" >> "$LOG"
