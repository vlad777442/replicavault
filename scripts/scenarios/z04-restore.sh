#!/usr/bin/env bash
# z04 — restore renamed vault entries (zero-copy pilot, Phase 5). At least 20.
# Per run: write NOBJ objects (sizes 1 B to 16 MiB; one in a namespace, one with a
# locator), delete them all, then restore every one from a renamed entry (mode=rename
# in its vault line) with scripts/vault-inspect.sh restore. Each restore must:
#   - come from a renamed entry (rv.sha256 = lazy; the checksum is computed at extract);
#   - reproduce the bytes the client wrote (client-side sha256 at put time);
#   - get a new object version, newer than the vaulted one, and not overwrite a live
#     object.
# Restored objects are live again, so invariant 4 re-reads them against the client sha.
source "$(dirname "$0")/common.sh"
RUNS=2
NOBJ=12
RV_RESULTS_SUBDIR=${RV_RESULTS_SUBDIR:-zc}
scenario_init z04-restore "$@"
SIZES=(1 4096 12345 65536 1048577 4194304 16777216 300001)

for run in $(seq 1 "$RUNS"); do
  run_begin "$run" "{\"objects\": $NOBJ}"
  names=()
  for i in $(seq 0 $((NOBJ - 1))); do
    ns="" loc=""
    (( i == 3 )) && ns=tenant-z
    (( i == 7 )) && loc=loc-z
    name=$RUN_PREFIX-$i
    put_obj "$name" "${SIZES[$(( i % ${#SIZES[@]} ))]}" "$ns" "$loc"
    names+=("$name|$ns|$loc|$(tail -1 "$RUN_STATE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')")
  done
  for entry in "${names[@]}"; do
    IFS='|' read -r name ns loc _ <<<"$entry"
    del_obj "$name" "$ns" "$loc" || die "rm $name"
  done
  sleep 2
  restores=$WORK/restores-$run.jsonl
  : > "$restores"
  if vault_mode; then
    for entry in "${names[@]}"; do
      IFS='|' read -r name ns loc client_sha <<<"$entry"
      # a renamed entry: its vault line says mode=rename
      line=$(for n in $(osd_ids); do
        tail -c +"$(( $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], 0))' "$WORK/offsets-$RUN.json" "$n") + 1 ))" \
          "$CEPH_BUILD/out/osd.$n.log" 2>/dev/null | grep 'replicavault: vaulted' | grep -F " oid=$name " \
          | grep -F " ns=$ns " | grep ' mode=rename ' | sed -E "s/.* vname=([^ ]+).*/$n \1/" || true
      done | head -1)
      if [[ -z $line ]]; then
        echo "{\"object\": \"$name\", \"pass\": false, \"problem\": \"no renamed entry\"}" >> "$restores"; continue
      fi
      read -r osd vname <<<"$line"
      out=$("$INSPECT" restore "$osd" "$vname" 2>"$WORK/restore.err" | grep '^{' || true)
      if [[ -z $out ]]; then
        python3 -c 'import json,sys; print(json.dumps({"object": sys.argv[1], "pass": False, "problem": "restore failed", "stderr": open(sys.argv[2]).read()[-500:]}))' "$name" "$WORK/restore.err" >> "$restores"
        continue
      fi
      python3 -c 'import json,sys
r = json.loads(sys.argv[1]); r["client_sha256"] = sys.argv[2]
r["matches_client"] = r["sha256"] == sys.argv[2]
r["pass"] = r["readback_matches"] and r["matches_client"] and r["new_version_is_newer"] and not r["overwrote_existing"]
print(json.dumps(r))' "$out" "$client_sha" >> "$restores"
      _state put "$POOL" "$ns" "$loc" "$name" 1 "$client_sha"
    done
    wait_clean 600 || true
  fi
  rs=$(python3 - "$restores" "$(vault_mode && echo 1 || echo 0)" "$NOBJ" <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
ok = None if sys.argv[2] != "1" else (len(rows) == int(sys.argv[3]) and all(r["pass"] for r in rows))
print(json.dumps({"pass": ok, "restored": sum(r["pass"] for r in rows), "results": rows}))
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
