#!/usr/bin/env bash
# E6a stage 1 re-run with the direct oracle (spec_knowledge/EXPERIMENTS.md, "Stage 1 fault"). Run alone.
cd "$(dirname "$0")/.." || exit 1
LOG=results/e6a_stage1.log
: > "$LOG"
echo "STAGE1-START $(date -u +%FT%TZ)" >> "$LOG"
julia --project=. scripts/e6a_cegis.jl 300 spec_files/partial_knowledge/tiered3.sl >> "$LOG" 2>&1
echo "STAGE1-END $? $(date -u +%FT%TZ)" >> "$LOG"
