#!/usr/bin/env bash
# spec_knowledge/EXPERIMENTS.md E6a, stage 1-3: plain + decomposed CEGIS, cvc5, CDGP pilot. Sequential, in its
# own console; nothing else heavy meanwhile; do not edit src/ or bench/ while it runs.
cd "$(dirname "$0")/.." || exit 1
LOG=results/e6a.log
: > "$LOG"
E=spec_files/enriched
O=spec_files/partial_knowledge/tiered3.sl
echo "STAGE1-START $(date -u +%FT%TZ)" >> "$LOG"
julia --project=. scripts/e6a_cegis.jl 300 $O >> "$LOG" 2>&1
echo "STAGE1-END $? $(date -u +%FT%TZ)" >> "$LOG"
echo "STAGE2-START $(date -u +%FT%TZ)" >> "$LOG"
PY=bench/.venv/Scripts/python
$PY scripts/cvc5_compare.py --tlimit 60 --modes default,random --tag e6a $O $E/tiered3_case.sl $E/tiered3_caseguard.sl $E/tiered3_decoy.sl >> "$LOG" 2>&1
$PY scripts/cvc5_compare.py --tlimit 60 --modes si-nogram --tag e6a $O >> "$LOG" 2>&1
echo "STAGE2-END $? $(date -u +%FT%TZ)" >> "$LOG"
run() { echo "START $* $(date -u +%FT%TZ)" >> "$LOG"; julia bench/run.jl "$@" >> "$LOG" 2>&1; echo "END $? $(date -u +%FT%TZ)" >> "$LOG"; }
run --arm baseline-lex --name pilot-e6a-orig      --specs tiered3 --seeds 1001:1020 --jobs 4
run --arm baseline-lex --name pilot-e6a-case      --specs tiered3 --seeds 1001:1020 --jobs 4 --variant case
run --arm baseline-lex --name pilot-e6a-caseguard --specs tiered3 --seeds 1001:1020 --jobs 4 --variant caseguard
run --arm baseline-lex --name pilot-e6a-decoy     --specs tiered3 --seeds 1001:1020 --jobs 4 --variant decoy
echo "E6A-PILOT-DONE $(date -u +%FT%TZ)" >> "$LOG"
