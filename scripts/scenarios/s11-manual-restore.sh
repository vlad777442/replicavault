#!/usr/bin/env bash
# Scenario 11: manual restore of a sample of vault entries via scripts/vault-inspect.sh.
# Per run: write and delete 10 objects (one in a namespace, one with a locator), then
# restore 5 of them from the OSD that logged the vault line. Each restore must
# reproduce the original bytes and produce a new object version newer than the
# vaulted one. Restored objects are then live (invariant 4 re-reads them).
# On the vanilla build there is nothing to restore; the restore step is skipped.
source "$(dirname "$0")/common.sh"
RUNS=2
scenario_init s11-manual-restore "$@"

for run in $(seq 1 "$RUNS"); do
  run_begin "$run"
  names=()
  for i in $(seq 0 9); do
    ns="" loc=""
    (( i == 3 )) && ns=tenant-r
    (( i == 7 )) && loc=loc-r
    name=$RUN_PREFIX-$i
    put_obj "$name" $(( 300000 + 4099 * i )) "$ns" "$loc"
    del_obj "$name" "$ns" "$loc" || die "rm $name"
    names+=("$name|$ns|$loc")
  done
  restores=$WORK/restores-$run.jsonl
  : > "$restores"
  if [[ $MODE == rv ]]; then
    for entry in "${names[@]:1:5}" "${names[7]}"; do
      IFS='|' read -r name ns loc <<<"$entry"
      line=$(vault_lines_for "$name" | head -1)
      [[ -n $line ]] || { echo "{\"object\": \"$name\", \"pass\": false, \"problem\": \"no vault line\"}" >> "$restores"; continue; }
      read -r osd vname <<<"$line"
      out=$("$INSPECT" restore "$osd" "$vname" 2>/dev/null | grep '^{' || true)
      if [[ -n $out ]]; then
        echo "$out" >> "$restores"
        # the restored object is live again, with the original bytes
        want=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["sha256"])' "$out")
        _state put "$POOL" "$ns" "$loc" "$name" 1 "$want"
      else
        echo "{\"object\": \"$name\", \"pass\": false, \"problem\": \"restore failed\"}" >> "$restores"
      fi
    done
    wait_clean 600 || true
  fi
  rs=$(python3 - "$restores" "$MODE" <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
for r in rows:
    if "pass" not in r:
        r["pass"] = r["readback_matches"] and r["new_version_is_newer"] and not r["overwrote_existing"]
ok = None if sys.argv[2] != "rv" else (bool(rows) and all(r["pass"] for r in rows))
print(json.dumps({"pass": ok, "restored": len(rows), "results": rows}))
EOF
)
  run_end "{\"restore\": $rs}"
  python3 - "$RUNS_FILE" <<'EOF'
import json, sys
path = sys.argv[1]
runs = [json.loads(l) for l in open(path)]
r = runs[-1]
r["pass"] = r["pass"] and r["restore"]["pass"] in (True, None)
open(path, "w").write("".join(json.dumps(x) + "\n" for x in runs))
EOF
done
scenario_finish
