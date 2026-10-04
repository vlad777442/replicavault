#!/usr/bin/env bash
# c02 — read-after-queue (phase 2, B3). At least 200 cases.
# One case = one object: a synchronous initial put, then k aio_write_full calls with
# distinct contents and an aio_remove, issued back to back without waiting (librados
# keeps per-object order). The vault entry must hold the content of the last write
# queued before the remove, not the initial put or an earlier write.
# Cases vary object size (4 KiB to 8 MiB) and k (1 to 4 in-flight writes). Each
# harness run holds 20 cases and ends with the full invariant check (run_end), so
# 10 runs = 200 cases; every case is checked individually by invariant 3.
source "$(dirname "$0")/common.sh"
RUNS=10
CASES=20
RV_RESULTS_SUBDIR=${RV_RESULTS_SUBDIR:-zc}
scenario_init c02-read-after-queue "$@"
SIZES=(4096 65536 1048576 4194304 8388608)

for run in $(seq 1 "$RUNS"); do
  run_begin "$run" "{\"cases\": $CASES}"
  cases=$WORK/cases-$run.jsonl
  : > "$cases"
  for c in $(seq 1 "$CASES"); do
    name=$RUN_PREFIX-c$c
    size=${SIZES[$(( (c - 1) % ${#SIZES[@]} ))]}
    k=$(( (c - 1) / ${#SIZES[@]} % 4 + 1 ))
    put_obj "$name" "$size"
    out=$(python3 "$SCEN_DIR/aio_ops.py" write-remove "$POOL" "$name" "$size" "$k" "$WORK")
    # the queued writes, in order, then the remove
    python3 - "$out" "$RUN_STATE" "$POOL" "$name" "$cases" "$size" "$k" <<'EOF'
import json, sys
out, state, pool, name, cases, size, k = sys.argv[1:8]
o = json.loads(out)
with open(state, "a") as f:
    for w in o["writes"]:
        f.write(json.dumps({"op": "put", "pool": pool, "ns": "", "loc": "", "name": name,
                            "sha": w["sha"], "acked": w["rc"] == 0}) + "\n")
    f.write(json.dumps({"op": "del", "pool": pool, "ns": "", "loc": "", "name": name,
                        "acked": o["remove_rc"] == 0}) + "\n")
with open(cases, "a") as f:
    f.write(json.dumps({"name": name, "size": int(size), "in_flight_writes": int(k),
                        "write_rcs": [w["rc"] for w in o["writes"]], "remove_rc": o["remove_rc"]}) + "\n")
EOF
  done
  run_end "{\"cases\": $(python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in open(sys.argv[1])]))' "$cases")}"
done
scenario_finish
