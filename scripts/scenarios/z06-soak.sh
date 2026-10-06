#!/usr/bin/env bash
# z06 — soak (zero-copy pilot, Phase 5). One run of SOAK_S seconds (default 3600):
# random write_full, partial overwrites, deletes and recreation of deleted names in
# rvtest and rvsnap, pool snapshot creation and removal in rvsnap, and a SIGKILL of a
# random OSD every KILL_S seconds (default 240), restarted by a watcher here.
# Then: wait clean; deep-scrub both pools; invariants 1 and 4 (rvcheck, no per-entry
# inspection); for every OSD in turn: stop, deep fsck, FuseStore scan of every vault
# entry (vault-scan.py), restart. Invariant 3 from the scan: every acknowledged delete
# has an entry, on some OSD, whose bytes match the client sha256 recorded for that
# delete (identity from the entry name; each entry used once); every entry on disk is
# intact (copy entries: stored sha == bytes; renamed: read without error).
source "$(dirname "$0")/common.sh"
RUNS=1
SNAP_POOL=rvsnap
SOAK_S=${SOAK_S:-3600}
KILL_S=${KILL_S:-240}
RV_RESULTS_SUBDIR=${RV_RESULTS_SUBDIR:-zc}
VAULT_INSPECT=0
export RV_DISK_SCAN=off RV_FSCK=off RV_DEEP_FSCK_BATCH=0
scenario_init z06-soak "$@"
EXTRA_POOLS=("$SNAP_POOL")
if ! ceph osd pool ls | grep -qx "$SNAP_POOL"; then
  ceph osd pool create "$SNAP_POOL" 8 8 replicated --autoscale-mode=off >/dev/null
  ceph osd pool set "$SNAP_POOL" size 3 >/dev/null
  ceph osd pool set "$SNAP_POOL" min_size 2 >/dev/null
  ceph osd pool application enable "$SNAP_POOL" rados >/dev/null
  wait_clean 300
fi
export CEPH_CONF

run=1
run_begin "$run" "{\"seconds\": $SOAK_S, \"kill_every_s\": $KILL_S}"
ceph osd set noout >/dev/null
# watcher: restart any OSD that died (the driver SIGKILLs one every KILL_S seconds)
( while [[ ! -e $WORK/soak.done ]]; do
    for n in $(osd_ids); do
      osd_pid "$n" >/dev/null || { sleep 3; osd_pid "$n" >/dev/null || restart_osd "$n" >/dev/null 2>&1; }
    done
    sleep 2
  done ) &
watcher=$!
summary=$(python3 "$SCEN_DIR/z06soak.py" "$POOL" "$SNAP_POOL" "$SOAK_S" "$RUN_STATE" "$RUN_PREFIX" "$KILL_S" \
          "$CEPH_BUILD/out" "$(osd_ids | paste -sd,)")
touch "$WORK/soak.done"; wait "$watcher" 2>/dev/null || true
for n in $(osd_ids); do osd_pid "$n" >/dev/null || restart_osd "$n"; done
ceph osd unset noout >/dev/null
note soak "$summary"
log "soak done: $summary"
wait_clean 1800 || true

# per OSD: stop, deep fsck, FuseStore scan of every vault entry, restart
scan=$WORK/scan.jsonl
: > "$scan"
fsck='{'
ceph osd set noout >/dev/null
for n in $(osd_ids); do
  kill_osd "$n" TERM >/dev/null 2>&1
  t0=$SECONDS
  out=$("$CEPH_BUILD/bin/ceph-bluestore-tool" --path "$CEPH_BUILD/dev/osd$n" --command fsck --deep 1 2>&1 | grep -E 'fsck (success|status)' | tail -1)
  fsck+="\"$n\": {\"pass\": $([[ $out == *"fsck success"* ]] && echo true || echo false), \"output\": \"$out\", \"seconds\": $((SECONDS - t0))},"
  if vault_mode; then
    python3 "$SCEN_DIR/../vault-scan.py" "$CEPH_BUILD/bin/ceph-objectstore-tool" "$CEPH_BUILD/dev/osd$n" "$n" "$WORK/mnt$n" >> "$scan"
  fi
  restart_osd "$n" >/dev/null 2>&1
done
ceph osd unset noout >/dev/null
fsck="${fsck%,}}"
wait_clean 900 || true

v3=$(python3 - "$RUN_STATE" "$scan" "$(vault_mode && echo 1 || echo 0)" <<'EOF'
import collections, json, sys
state, scan, vault = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
if not vault:
    print(json.dumps({"pass": None, "skipped": "vanilla"})); sys.exit()
pools = {}
last, deletes = {}, []
for l in open(state):
    r = json.loads(l); k = (r["pool"], r["name"])
    if r["op"] == "put" and r.get("acked", True):
        last[k] = r["sha"]
    elif r["op"] == "del" and r["acked"]:
        deletes.append((k, last.get(k))); last.pop(k, None)
    elif r["op"] == "unknown":
        last.pop(k, None)
entries = [json.loads(l) for l in open(scan) if l.strip() and "vname" in l]
bad_entries = [e for e in entries if not e.get("intact")]
by_ident = collections.defaultdict(list)
for e in entries:
    rv = e["rv"]
    by_ident[(rv.get("rv.pool"), rv.get("rv.oid"))].append(e)
# pool names -> ids, via the entries' rv.pool and the state's pool names
import subprocess, os
ls = json.loads(subprocess.run([os.environ["CEPH_BUILD"] + "/bin/ceph", "-c", os.environ["CEPH_CONF"],
                                "osd", "pool", "ls", "detail", "-f", "json"], capture_output=True, text=True).stdout)
pid = {p["pool_name"]: str(p["pool_id"]) for p in ls}
used, missing, modes = set(), [], collections.Counter()
for (pool, name), sha in deletes:
    if sha is None:
        continue          # deleted before any acknowledged write in this run
    hit = None
    for e in by_ident.get((pid.get(pool), name), []):
        key = (e["osd"], e["vname"])
        if key not in used and e.get("intact") and e.get("data_sha256") == sha:
            hit = e; used.add(key); break
    if hit:
        modes[hit["rv"].get("rv.mode", "copy")] += 1
    else:
        missing.append({"pool": pool, "name": name, "expected_sha": sha})
print(json.dumps({"pass": not missing and not bad_entries, "checked": len([d for d in deletes if d[1]]),
                  "missing": missing[:50], "missing_count": len(missing),
                  "entries_scanned": len(entries), "entries_not_intact": bad_entries[:20],
                  "matched_by_mode": dict(modes)}))
EOF
)
run_end "{\"deep_fsck_all\": $(python3 -c 'import json,sys; o=json.loads(sys.argv[1]); print(json.dumps({"pass": all(v["pass"] for v in o.values()), "osds": o}))' "$fsck"), \"vault_scan\": $v3}"
python3 - "$RUNS_FILE" <<'EOF'
import json, sys
path = sys.argv[1]
runs = [json.loads(l) for l in open(path)]
r = runs[-1]
# invariant 3 comes from the FuseStore scan (rvcheck ran without per-entry inspection)
r["invariants"]["3_vault_intact"] = r["vault_scan"]
r["pass"] = (r["clean_after"] and r["deep_fsck_all"]["pass"]
             and all(v.get("pass") in (True, None) for v in r["invariants"].values()))
open(path, "w").write("".join(json.dumps(x) + "\n" for x in runs))
EOF
scenario_finish
