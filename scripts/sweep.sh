#!/bin/bash
# Clock-period sweep: one full LibreLane run per period, same flow/config.json,
# only CLOCK_PERIOD overridden (-c CLOCK_PERIOD=<ns>). Run tags: p25, p20, p17_5 ...
# Resumable: a period whose run already has final/metrics.json is skipped
# (FORCE=1 re-runs everything).
#   bash scripts/sweep.sh                         # default periods, one run at a time
#   PERIODS="25 20" bash scripts/sweep.sh
#   JOBS=2 bash scripts/sweep.sh                  # parallel: needs ~4 GB RAM per run
# Then: python scripts/sweep_report.py
set -u
cd "$(dirname "$0")/.."
PERIODS="${PERIODS:-25 20 17.5 15 12.5 10}"
JOBS="${JOBS:-1}"
FORCE="${FORCE:-0}"
mkdir -p flow/runs

run_one() {
  local p="$1" tag="p${1//./_}"
  if [ "$FORCE" != 1 ] && [ -f "flow/runs/$tag/final/metrics.json" ]; then
    echo "[$(date +%T)] skip   $tag (already done)"
    return
  fi
  echo "[$(date +%T)] start  $tag (CLOCK_PERIOD=$p ns)"
  bash scripts/ll.sh librelane --run-tag "$tag" --overwrite -j 8 \
       -c "CLOCK_PERIOD=$p" flow/config.json > "flow/runs/$tag.log" 2>&1
  local rc=$?
  echo "[$(date +%T)] finish $tag exit=$rc: $(grep -E 'Flow complete|LibreLane will now quit' "flow/runs/$tag.log" | tail -1 | sed 's/  */ /g')"
}

for p in $PERIODS; do
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 10; done
  run_one "$p" &
  [ "$JOBS" -gt 1 ] && sleep 30
done
wait
