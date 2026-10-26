#!/usr/bin/env bash
# Contention measurement (BENCHMARK_METHODOLOGY.md §14 item 14): per arm and spec, the same 4
# seeds for a fixed number of generations, alone vs as 4 concurrent processes. Own console.
cd "$(dirname "$0")/../.." || exit 1
OUTDIR=results/contention
mkdir -p "$OUTDIR"
RAW=$OUTDIR/raw.csv
LOG=$OUTDIR/run.log
echo "arm,spec,mode,seed,gens,elapsed_s" > "$RAW"
: > "$LOG"
N=4
i=0
# arm spec generations (≈10-15 s per seed alone)
while read -r ARM SPEC GENS; do
  [ -z "$ARM" ] && continue
  i=$((i + 1))
  solo() { julia --project=. scripts/contention/contention_run.jl "$ARM" "$SPEC" "$GENS" solo 0 $N none "$RAW" >> "$LOG" 2>&1; }
  conc() {
    SYNC=$(mktemp -d)
    for id in $(seq 1 $N); do
      julia --project=. scripts/contention/contention_run.jl "$ARM" "$SPEC" "$GENS" conc "$id" $N "$SYNC" "$RAW" >> "$LOG" 2>&1 &
    done
    wait
    rm -rf "$SYNC"
  }
  echo "START $ARM $SPEC $GENS $(date -u +%T)" >> "$LOG"
  if [ $((i % 2)) -eq 1 ]; then solo; conc; else conc; solo; fi   # alternate order against drift
  echo "END $ARM $SPEC $(date -u +%T)" >> "$LOG"
done <<'EOF'
baseline-lex array_search4 500
lex-guided array_search4 300
lex-percon array_search4 250
hybrid-ratio array_search4 250
baseline-lex max6 120
lex-guided max6 25
lex-percon max6 80
hybrid-ratio max6 90
EOF
echo "CONTENTION-DONE $(date -u +%T)" >> "$LOG"
