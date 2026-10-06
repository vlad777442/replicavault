#!/usr/bin/env bash
# z05 — omap-heavy objects (zero-copy pilot, Phase 5).
# Per run: objects with 100, 2,000 and 20,000 omap keys (100-400 B values), a header
# and 64 KiB of data. Delete each, timing the client remove (rename rewrites every
# omap key, O(keys); vanilla removes them with one range delete, BlueStore.cc
# _do_omap_clear; compare z05 on vanilla and zc). Then, on a prototype build, for
# every vault line of these objects: stop that OSD, read the entry's data, header and
# full omap straight from the store (z05omap.py vault), compare with what the client
# wrote, and confirm mode=rename. Finally restore each object from one entry (data,
# header, omap) under its original name and compare the live object again.
source "$(dirname "$0")/common.sh"
RUNS=2
RV_RESULTS_SUBDIR=${RV_RESULTS_SUBDIR:-zc}
scenario_init z05-omap-heavy "$@"
KEYS=(100 2000 20000)
Z=$SCEN_DIR/z05omap.py
export CEPH_CONF

for run in $(seq 1 "$RUNS"); do
  run_begin "$run" "{\"keys\": [$(IFS=,; echo "${KEYS[*]}")]}"
  res=$WORK/z05-$run.jsonl
  : > "$res"
  for k in "${KEYS[@]}"; do
    name=$RUN_PREFIX-k$k
    w=$(python3 "$Z" write "$POOL" "$name" "$k" 65536)
    _state put "$POOL" "" "" "$name" 1 "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["sha"])' "$w")"
    d=$(python3 "$Z" delete "$POOL" "$name")
    _state del "$POOL" "" "" "$name" 1
    python3 -c 'import json,sys; w=json.loads(sys.argv[1]); w.update(json.loads(sys.argv[2])); w["name"]=sys.argv[3]; print(json.dumps(w))' "$w" "$d" "$name" >> "$res"
  done
  sleep 2
  checks=$WORK/z05-checks-$run.jsonl
  : > "$checks"
  if vault_mode; then
    while read -r row; do
      name=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["name"])' "$row")
      first=1
      while read -r osd vname mode; do
        [[ -n $osd ]] || continue
        ceph osd set noout >/dev/null
        kill_osd "$osd" TERM >/dev/null 2>&1
        keep=""; (( first )) && keep=$WORK/restore-data
        python3 "$Z" vault "$CEPH_BUILD/dev/osd$osd" "$vname" "$CEPH_BUILD/bin/ceph-objectstore-tool" \
          "$CEPH_BUILD/bin/ceph-kvstore-tool" $keep > "$WORK/vault.json"
        restart_osd "$osd" >/dev/null 2>&1
        ceph osd unset noout >/dev/null
        rest='null'
        if (( first )); then
          wait_clean 300 >/dev/null 2>&1 || true
          rest=$(python3 "$Z" restore "$POOL" "$name" "$WORK/vault.json" "$WORK/restore-data")
          first=0
        fi
        python3 - "$row" "$WORK/vault.json" "$osd" "$mode" "$rest" >> "$checks" <<'EOF'
import json, sys
row, v, osd, mode, rest = json.loads(sys.argv[1]), json.load(open(sys.argv[2])), sys.argv[3], sys.argv[4], json.loads(sys.argv[5])
r = {"name": row["name"], "nkeys": row["nkeys"], "osd": int(osd), "mode": mode,
     "found": v.get("found"), "vault_nkeys": v.get("nkeys"),
     "data_match": v.get("data_sha") == row["sha"],
     "omap_match": v.get("omap_digest") == row["omap_digest"]}
if rest is not None:
    r["restore"] = {"data_match": rest["data_readback_sha"] == row["sha"],
                    "omap_match": rest["omap_digest_after"] == row["omap_digest"],
                    "nkeys_after": rest["nkeys_after"], "new_version": rest["new_version"],
                    "overwrote_existing": rest["overwrote_existing"]}
r["pass"] = bool(r["found"] and r["data_match"] and r["omap_match"] and mode == "rename"
                 and (rest is None or (r["restore"]["data_match"] and r["restore"]["omap_match"]
                                       and not r["restore"]["overwrote_existing"])))
print(json.dumps(r))
EOF
        if [[ -n $keep ]]; then
          # restored: live again with the client's bytes
          _state put "$POOL" "" "" "$name" 1 "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["sha"])' "$row")"
        fi
      done < <(for n in $(osd_ids); do
          tail -c +"$(( $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], 0))' "$WORK/offsets-$RUN.json" "$n") + 1 ))" \
            "$CEPH_BUILD/out/osd.$n.log" 2>/dev/null | grep 'replicavault: vaulted' | grep -F " oid=$name " \
            | sed -E "s/.* mode=([a-z]+) .* vname=([^ ]+).*/$n \2 \1/" || true
        done)
    done < "$res"
  fi
  z=$(python3 - "$res" "$checks" "$(vault_mode && echo 1 || echo 0)" <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
checks = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
vault = sys.argv[3] == "1"
ok = None
if vault:
    names = {r["name"] for r in rows}
    restored = {c["name"] for c in checks if "restore" in c}
    ok = bool(checks) and all(c["pass"] for c in checks) and restored == names
print(json.dumps({"pass": ok, "deletes": [{"nkeys": r["nkeys"], "omap_bytes": r["omap_bytes"], "rm_s": r["rm_s"]} for r in rows],
                  "checks": checks}))
EOF
)
  run_end "{\"z05\": $z}"
  python3 - "$RUNS_FILE" <<'EOF'
import json, sys
path = sys.argv[1]
runs = [json.loads(l) for l in open(path)]
r = runs[-1]
r["pass"] = r["pass"] and r["z05"]["pass"] in (True, None)
open(path, "w").write("".join(json.dumps(x) + "\n" for x in runs))
EOF
done
scenario_finish
