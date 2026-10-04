#!/usr/bin/env bash
# z01 — allocation rebuild with zero-copy vault entries (zero-copy pilot, Phase 4).
# At least 30 runs; also run on the copy build (zccopy) as a control.
#
# The zc cluster's DBs are on SSD, so BlueStore keeps allocations in a file
# (bluestore_allocation_from_file) and rebuilds them from a walk of every onode,
# meta collection included, after an unclean shutdown (notes/zc/step1.md Q6).
# A renamed vault entry's blocks must survive that rebuild as used.
#
# Per run, on target OSD X (rotating over all OSDs):
#  1. write NOBJ objects (4 KiB to 16 MiB, client-side sha256) in PGs where X is
#     the primary or the retainer, delete them; X logs one vault line per delete,
#     which must be mode=rename (mode=copy on zccopy);
#  2. SIGKILL X, restart it; its log must show the onode-walk allocation rebuild;
#  3. fill X with new writes: a size-1 pool whose PGs are all upmapped to X,
#     `rados bench write --no-cleanup`; FILL_GIB normally, to ~70% of X in the
#     full-fill runs (FULL_RUNS);
#  4. stop X; `ceph-bluestore-tool free-dump`, `fsck --deep`, `qfsck`; then
#     z01check.py on every vault entry z01 has created on X so far (all runs):
#     present, bytes == client sha256, this run's entries renamed on disk, and no
#     physical extent in the persisted free list (offline fsck does not compare
#     used blocks with the free list in this mode, BlueStore.cc:11487-11488);
#     restart X, remove the fill pool, wait for X to reclaim the space;
#  5. run_end: wait clean, deep-scrub rvtest, invariants 1-4 with the disk scan.
# A run fails on any missing or corrupt entry, fsck/qfsck error, overlap with the
# free list, or a missing rebuild. Vlad's rule: any such failure is a STOP.
#
# Fill plan approved by Vlad 2026-10-04: an 8 GiB fill every run plus the direct
# free-list check; a ~70% fill in 6 of 30 runs (each OSD once, plus one).
source "$(dirname "$0")/common.sh"
RUNS=30
RV_RESULTS_SUBDIR=${RV_RESULTS_SUBDIR:-zc}
scenario_init z01-alloc-rebuild "$@"
NOBJ=${Z01_NOBJ:-16}
FILL_GIB=${Z01_FILL_GIB:-8}
FULL_PCT=${Z01_FULL_PCT:-70}
FULL_RUNS=" ${Z01_FULL_RUNS:-6 12 15 18 24 30} "
SIZES=(4096 12345 65536 1048577 4194304 16777216)
OBJ=$((4 * 1024 * 1024))
case $MODE in
  zc) EXPECT=rename ;;
  zccopy) EXPECT=copy ;;
  *) die "z01 needs the zc or zccopy build (installed: $MODE)" ;;
esac
mapfile -t OSDS < <(osd_ids)
POOL_ID=$(ceph osd pool ls detail -f json | python3 -c 'import json,sys
print([p["pool_id"] for p in json.load(sys.stdin) if p["pool_name"]==sys.argv[1]][0])' "$POOL")
PG_NUM=$(ceph osd pool get "$POOL" pg_num -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["pg_num"])')
ART=$RESULTS/z01-artifacts/$TS
mkdir -p "$ART"
FILL_POOL=""
cleanup_fill() {
  if [[ -n $FILL_POOL ]]; then
    ceph osd pool rm "$FILL_POOL" "$FILL_POOL" --yes-i-really-really-mean-it >/dev/null || true
    FILL_POOL=""
  fi
}
trap 'cleanup_fill; ceph osd unset noout >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

osd_used() {  # osd_used N -> "used_bytes total_bytes"
  ceph osd df -f json | python3 -c 'import json,sys
n=[x for x in json.load(sys.stdin)["nodes"] if x["id"]==int(sys.argv[1])][0]
print(n["kb_used"]*1024, n["kb"]*1024)' "$1"
}

for run in $(seq 1 "$RUNS"); do
  X=${OSDS[$(( (run - 1) % ${#OSDS[@]} ))]}
  full=false; [[ $FULL_RUNS == *" $run "* ]] && full=true
  run_begin "$run" "{\"osd\": $X, \"full_fill\": $full, \"expect_mode\": \"$EXPECT\"}"
  ceph osd set noout >/dev/null

  # 1. objects in PGs where X is the primary or the retainer, then delete them
  mapfile -t objs < <(ceph pg ls-by-pool "$POOL" -f json | python3 -c '
import json, sys
sys.path.insert(0, sys.argv[1])
import pgmap
x, pool_id, pg_num, prefix, n = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], int(sys.argv[6])
d = json.load(sys.stdin)
good = set()
for p in d.get("pg_stats", d):
    prim = p["acting_primary"]
    order = [prim] + [o for o in p["acting"] if o != prim]
    if x == prim or (len(order) > 1 and order[1] == x):
        good.add(p["pgid"])
i = 0
out = []
while len(out) < n:
    name = f"{prefix}-o{i}"
    if pgmap.pg_of(pool_id, pg_num, name) in good:
        out.append(name)
    i += 1
print("\n".join(out))' "$SCEN_DIR/.." "$X" "$POOL_ID" "$PG_NUM" "$RUN_PREFIX" "$NOBJ")
  i=0
  for o in "${objs[@]}"; do
    put_obj "$o" "${SIZES[$(( (i + run) % ${#SIZES[@]} ))]}"
    i=$((i + 1))
  done
  for o in "${objs[@]}"; do del_obj "$o" || die "delete of $o not acknowledged"; done
  sleep 2
  # X's vault lines for this run's objects -> cumulative entry list for X
  python3 - "$CEPH_BUILD/out/osd.$X.log" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$WORK/offsets-$run.json" "$X")" \
      "$RUN_STATE" "$X" "$run" "$WORK/z01-entries-$X.jsonl" "$WORK/z01-lines-$run.json" <<'EOF'
import json, re, sys
log, off, state, x, run, entries, out = sys.argv[1:8]
sha = {}
for l in open(state):
    r = json.loads(l)
    if r["op"] == "put":
        sha[r["name"]] = r["sha"]
f = open(log, "rb"); f.seek(int(off))
rx = re.compile(r"replicavault: vaulted pool=\S+ pg=\S+ oid=(\S+) ns=\S* v=\S+ osd=(\d+) path=(\w+) mode=(\w+) .*size=(\d+) .*vname=(\S+)")
lines = []
for raw in f:
    m = rx.search(raw.decode(errors="replace"))
    if m and m.group(2) == x and m.group(1) in sha:
        lines.append({"name": m.group(1), "path": m.group(3), "mode": m.group(4),
                      "size": int(m.group(5)), "vname": m.group(6)})
with open(entries, "a") as e:
    for l in lines:
        e.write(json.dumps({"vname": l["vname"], "sha": sha[l["name"]], "run": int(run),
                            "size": l["size"], "path": l["path"]}) + "\n")
json.dump({"lines": len(lines), "objects": len(sha),
           "modes": sorted({l["mode"] for l in lines}),
           "paths": {p: sum(l["path"] == p for l in lines) for p in {l["path"] for l in lines}}},
          open(out, "w"))
EOF
  note vault_lines_on_x "$(cat "$WORK/z01-lines-$run.json")"
  note entries_on_x "$(python3 -c 'import json,sys; print(json.dumps([e for e in map(json.loads, open(sys.argv[1])) if e["run"] == int(sys.argv[2])]))' "$WORK/z01-entries-$X.jsonl" "$run")"

  # 2. unclean shutdown of X, restart: the onode-walk allocation rebuild must run
  kill_off=$(stat -c %s "$CEPH_BUILD/out/osd.$X.log")
  kill_osd "$X" KILL
  restart_osd "$X"
  for k in $(seq 1 30); do
    tail -c +"$((kill_off + 1))" "$CEPH_BUILD/out/osd.$X.log" | grep -q "Allocation Recovery was completed" && break
    sleep 1
  done
  rebuild=$(tail -c +"$((kill_off + 1))" "$CEPH_BUILD/out/osd.$X.log" | python3 -c '
import json, sys
t = sys.stdin.read()
done = [l for l in t.splitlines() if "Allocation Recovery was completed" in l]
print(json.dumps({"full_recovery_from_onodes": "Run Full Recovery from ONodes" in t,
                  "completed": done[-1].split("read_allocation_from_drive_on_startup")[-1].strip()[:200] if done else None}))')
  note rebuild "$rebuild"
  wait_clean 600 || true

  # 3. fill X through a size-1 pool upmapped to it
  FILL_POOL=zcfill-$TS-r$run
  ceph osd pool create "$FILL_POOL" 32 32 replicated --size 1 --yes-i-really-mean-it >/dev/null
  ceph osd pool set "$FILL_POOL" pg_autoscale_mode off >/dev/null
  ceph osd pool set "$FILL_POOL" min_size 1 >/dev/null
  ceph osd pool application enable "$FILL_POOL" rados >/dev/null
  fid=$(ceph osd pool ls detail -f json | python3 -c 'import json,sys
print([p["pool_id"] for p in json.load(sys.stdin) if p["pool_name"]==sys.argv[1]][0])' "$FILL_POOL")
  for s in $(seq 0 31); do ceph osd pg-upmap "$(printf '%d.%x' "$fid" "$s")" "$X" >/dev/null; done
  wait_clean 600 || die "fill pool not clean"
  read -r used total < <(osd_used "$X")
  if $full; then
    want=$(( total * FULL_PCT / 100 - used ))
  else
    want=$(( FILL_GIB * 1024 * 1024 * 1024 ))
  fi
  nfill=$(( (want + OBJ - 1) / OBJ ))
  t0=$SECONDS
  rados -p "$FILL_POOL" bench 36000 write -b "$OBJ" -t 16 --max-objects "$nfill" --no-cleanup \
    > "$WORK/bench-$run.txt" 2>&1 || die "fill bench failed"
  sleep 5
  read -r used2 total < <(osd_used "$X")
  note fill "{\"objects\": $nfill, \"bytes\": $((nfill * OBJ)), \"seconds\": $((SECONDS - t0)), \"used_before\": $used, \"used_after\": $used2, \"total\": $total, \"pct_after\": $(( used2 * 100 / total ))}"

  # 4. offline checks on X
  kill_osd "$X" TERM
  dev=$CEPH_BUILD/dev/osd$X
  "$CEPH_BUILD/bin/ceph-bluestore-tool" --path "$dev" --command free-dump > "$WORK/free-$run.txt" 2>"$WORK/free-$run.err" \
    || die "free-dump failed on osd.$X"
  t0=$SECONDS
  "$CEPH_BUILD/bin/ceph-bluestore-tool" --path "$dev" --command fsck --deep 1 > "$WORK/fsck-$run.txt" 2>&1 || true
  fsck_s=$((SECONDS - t0))
  "$CEPH_BUILD/bin/ceph-bluestore-tool" --path "$dev" --command qfsck > "$WORK/qfsck-$run.txt" 2>&1 || true
  zc=$(python3 "$SCEN_DIR/z01check.py" --osd "$X" --data-path "$dev" --cot "$CEPH_BUILD/bin/ceph-objectstore-tool" \
        --free-dump "$WORK/free-$run.txt" --entries "$WORK/z01-entries-$X.jsonl" --run "$run" \
        --expect-mode "$EXPECT" 2>"$WORK/z01check-$run.err") || true
  [[ -n $zc ]] || zc="{\"pass\": false, \"error\": $(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()[-2000:]))' "$WORK/z01check-$run.err")}"
  restart_osd "$X"
  cleanup_fill
  ceph osd unset noout >/dev/null
  # X deletes the fill pool's PGs in the background; wait for the space
  for k in $(seq 1 360); do
    read -r used3 total < <(osd_used "$X")
    (( used3 < used + 2 * 1024 * 1024 * 1024 )) && break
    sleep 5
  done

  z01=$(python3 - "$WORK/fsck-$run.txt" "$WORK/qfsck-$run.txt" "$zc" "$fsck_s" "$WORK/z01-lines-$run.json" "$rebuild" "$EXPECT" "$NOBJ" <<'EOF'
import json, sys
fsck, qfsck, zc, fsck_s, lines, rebuild, expect, nobj = sys.argv[1:9]
ft, qt = open(fsck).read(), open(qfsck).read()
zc, lines, rebuild = json.loads(zc), json.load(open(lines)), json.loads(rebuild)
r = {
  "fsck_deep": {"pass": "fsck success" in ft, "seconds": int(fsck_s), "tail": ft[-600:]},
  "qfsck": {"pass": "qfsck success" in qt, "tail": qt[-600:]},
  "check": zc,
  "vault_lines_on_x": {"pass": lines["lines"] == int(nobj) and lines["modes"] == [expect], **lines},
  "rebuild": {"pass": bool(rebuild["full_recovery_from_onodes"] and rebuild["completed"]), **rebuild},
}
r["pass"] = all(v["pass"] for v in r.values())
print(json.dumps(r))
EOF
)
  if [[ $(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["pass"])' "$z01") != True ]]; then
    d=$ART/run-$run; mkdir -p "$d"
    cp "$WORK"/{free,fsck,qfsck,z01check,bench}-"$run".* "$d"/ 2>/dev/null || true
    cp "$WORK/z01-entries-$X.jsonl" "$d"/ 2>/dev/null || true
    tail -c +"$((kill_off + 1))" "$CEPH_BUILD/out/osd.$X.log" | tail -n 20000 > "$d/osd.$X.log.tail"
    log "z01 run $run: CHECK FAILED; artifacts in $d"
  fi
  run_end "{\"z01\": $z01}"
  python3 - "$RUNS_FILE" <<'EOF'
import json, sys
path = sys.argv[1]
runs = [json.loads(l) for l in open(path)]
r = runs[-1]
r["pass"] = r["pass"] and r["z01"]["pass"]
open(path, "w").write("".join(json.dumps(x) + "\n" for x in runs))
EOF
  tail -1 "$RUNS_FILE" | python3 -c 'import json,sys; r=json.load(sys.stdin); z=r["z01"]
c=z["check"]
print("z01 run %d osd.%s: %s  fsck=%s qfsck=%s rebuild=%s entries=%s/%s free_overlap=%d sha_bad=%d missing=%d fill=%s%%" % (
  r["run"], r["params"]["osd"], "PASS" if r["pass"] else "FAIL", z["fsck_deep"]["pass"], z["qfsck"]["pass"],
  z["rebuild"]["pass"], c.get("entries_this_run"), c.get("entries_checked"), len(c.get("free_overlap", [])),
  len(c.get("sha_mismatch", [])), len(c.get("missing", [])), r["notes"]["fill"]["pct_after"]))' >&2
  # Vlad: any corrupted or missing entry or fsck error is a STOP
  [[ $(tail -1 "$RUNS_FILE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["z01"]["pass"])') == True ]] \
    || { log "z01: STOP condition in run $run"; break; }
done
scenario_finish
