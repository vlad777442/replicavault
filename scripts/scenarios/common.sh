#!/usr/bin/env bash
# Scenario harness. Source from a scenario script:
#
#   source "$(dirname "$0")/common.sh"
#   scenario_init <name> "$@"             # parses --runs N, --pool P
#   for run in $(seq 1 "$RUNS"); do
#     run_begin "$run" '{"param": 1}'     # records log offsets, clears the per-run state
#     put_obj NAME SIZE [NS] [LOC]; del_obj NAME [NS] [LOC]; ...
#     run_end                             # wait clean, deep-scrub, invariants 1-4
#   done
#   scenario_finish                       # writes results/<name>-<ts>.json
#
# Every put/delete is appended to $RUN_STATE (JSON lines) for rvcheck.py. Delete
# outcome = rados exit status: 0 means the cluster acknowledged the delete.
set -euo pipefail
SCEN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCEN_DIR/../lib.sh"
export PYTHONPATH=$CEPH_BUILD/lib/cython_modules/lib.3${PYTHONPATH:+:$PYTHONPATH}
export CEPH_BUILD

INSPECT=$SCEN_DIR/../vault-inspect.sh
RUNS=10
POOL=rvtest
EXTRA_POOLS=()          # scenarios that use more pools add them here (scrubbed and checked)
VAULT_INSPECT=1

scenario_init() {
  SCENARIO=$1; shift
  while [[ $# -gt 0 ]]; do
    case $1 in
      --runs) RUNS=$2; shift 2 ;;
      --pool) POOL=$2; shift 2 ;;
      --no-vault-inspect) VAULT_INSPECT=0; shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  TS=$(date +%Y%m%dT%H%M%S)
  WORK=$(mktemp -d)
  # phase 2 results go to results/phase2 by default: the pilot's files directly
  # under results/ are frozen and must not gain neighbours from later runs
  RESULTS=$RV_ROOT/results/${RV_RESULTS_SUBDIR:-phase2}
  mkdir -p "$RESULTS"
  OUT=$RESULTS/$SCENARIO-$TS.json
  RUNS_FILE=$WORK/runs.jsonl
  : > "$RUNS_FILE"
  SCEN_CMD="scripts/scenarios/$(basename "$0") $*"
  rv_require_cluster
  rv_check_osd_binaries || die "an OSD runs a stale binary; use scripts/use-build.sh"
  MODE=$(rv_build)
  CEPH_GIT=$(rv_ceph_git)
  SCEN_START=$SECONDS
  log "scenario $SCENARIO: mode=$MODE ceph=$CEPH_GIT runs=$RUNS pool=$POOL"
  trap 'ceph osd unset noout >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
  wait_clean 600 || die "cluster not clean at start"
}

run_begin() {
  RUN=$1
  RUN_PARAMS=${2:-}
  [[ -n $RUN_PARAMS ]] || RUN_PARAMS='{}'
  RUN_START=$SECONDS
  RUN_STATE=$WORK/state-$RUN.jsonl
  RUN_NOTES=$WORK/notes-$RUN.jsonl
  : > "$RUN_STATE"; : > "$RUN_NOTES"
  RUN_PREFIX=$SCENARIO-$TS-r$RUN
  local n offs="{"
  for n in $(osd_ids); do
    offs+="\"$n\": $(stat -c %s "$CEPH_BUILD/out/osd.$n.log" 2>/dev/null || echo 0),"
  done
  echo "${offs%,}}" > "$WORK/offsets-$RUN.json"
  log "--- $SCENARIO run $RUN $RUN_PARAMS"
}

# note KEY VALUE-JSON: free-form per-run facts (acting sets, timings, outcomes)
note() {
  python3 -c 'import json,sys; print(json.dumps({sys.argv[1]: json.loads(sys.argv[2])}))' "$1" "$2" >> "$RUN_NOTES"
}

_rargs() {  # _rargs POOL NS LOC -> rados CLI args
  local a=(-p "$1")
  [[ -n $2 ]] && a+=(-N "$2")
  [[ -n $3 ]] && a+=(--object-locator "$3")
  printf '%s\n' "${a[@]}"
}

_state() {  # _state op pool ns loc name acked [sha]
  python3 -c 'import json,sys
op,pool,ns,loc,name,acked=sys.argv[1:7]
r={"op":op,"pool":pool,"ns":ns,"loc":loc,"name":name,"acked":acked=="1"}
if len(sys.argv)>7: r["sha"]=sys.argv[7]
print(json.dumps(r))' "$@" >> "$RUN_STATE"
}

# put_obj NAME SIZE [NS] [LOC] [POOL]: random content; prints nothing, records sha
put_obj() {
  local name=$1 size=$2 ns=${3:-} loc=${4:-} pool=${5:-$POOL} f
  f=$WORK/put.$$
  head -c "$size" /dev/urandom > "$f"
  mapfile -t ra < <(_rargs "$pool" "$ns" "$loc")
  rados "${ra[@]}" put "$name" "$f" || die "put $name failed"
  _state put "$pool" "$ns" "$loc" "$name" 1 "$(sha "$f")"
}

# del_obj NAME [NS] [LOC] [POOL]: returns rados exit status; records acked or not
del_obj() {
  local name=$1 ns=${2:-} loc=${3:-} pool=${4:-$POOL} rc=0
  mapfile -t ra < <(_rargs "$pool" "$ns" "$loc")
  rados "${ra[@]}" rm "$name" || rc=$?
  _state del "$pool" "$ns" "$loc" "$name" "$([[ $rc == 0 ]] && echo 1 || echo 0)"
  return $rc
}

# record_del_result NAME RC [NS] [LOC] [POOL]: for deletes run in the background
record_del_result() {
  local name=$1 rc=$2 ns=${3:-} loc=${4:-} pool=${5:-$POOL}
  _state del "$pool" "$ns" "$loc" "$name" "$([[ $rc == 0 ]] && echo 1 || echo 0)"
}

# Wait until the object's PG is active (usable after killing an acting OSD).
wait_pg_active() {
  local pg=$1 i
  for i in $(seq 1 120); do
    ceph pg "$pg" query 2>/dev/null | python3 -c '
import json,sys
s=json.load(sys.stdin)["state"]; sys.exit(0 if s.startswith("active") else 1)' && return 0
    sleep 1
  done
  return 1
}

run_end() {
  local extra=${1:-} scrub_ok=true inc_ok=true pool check rc=0 clean_ok=true
  [[ -n $extra ]] || extra='{}'
  wait_clean 900 || clean_ok=false
  for pool in "$POOL" "${EXTRA_POOLS[@]:-}"; do
    [[ -z $pool ]] && continue
    deep_scrub_all "$pool" 1200 || scrub_ok=false
    check_inconsistent "$pool" 2>>"$WORK/inc-$RUN.txt" || inc_ok=false
  done
  local inspect_flag=()
  (( VAULT_INSPECT )) || inspect_flag=(--no-vault-inspect)
  check=$(python3 "$SCEN_DIR/rvcheck.py" --state "$RUN_STATE" --offsets "$WORK/offsets-$RUN.json" \
          --mode "$MODE" --inspect "$INSPECT" --disk-scan "${RV_DISK_SCAN:-missing}" "${inspect_flag[@]}" \
          2>"$WORK/rvcheck-$RUN.err") || rc=$?
  [[ -n $check ]] || check='{"rvcheck_error": {"pass": false, "stderr": ""}}'
  # vault-inspect stopped and restarted OSDs; come back to clean before the next run
  wait_clean 900 || clean_ok=false
  python3 - "$RUNS_FILE" "$RUN" "$RUN_PARAMS" "$check" "$RUN_NOTES" "$scrub_ok" "$inc_ok" \
           "$clean_ok" "$((SECONDS - RUN_START))" "$extra" "$WORK/inc-$RUN.txt" "$WORK/rvcheck-$RUN.err" <<'EOF'
import json, sys
(runs_file, run, params, check, notes_file, scrub_ok, inc_ok, clean_ok, dur, extra,
 inc_file, err_file) = sys.argv[1:13]
check = json.loads(check)
if "rvcheck_error" in check:
    check["rvcheck_error"]["stderr"] = open(err_file).read()[-3000:]
notes = {}
for l in open(notes_file):
    notes.update(json.loads(l))
inv = {
    "1_no_resurrection": check.get("no_resurrection", {"pass": False}),
    "2_no_inconsistency": {"pass": scrub_ok == "true" and inc_ok == "true",
                           "deep_scrub_completed": scrub_ok == "true",
                           "findings": open(inc_file).read()[-3000:] if inc_ok != "true" else ""},
    "3_vault_intact": check.get("vault_intact", {"pass": False}),
    "4_live_intact": check.get("live_intact", {"pass": False}),
}
rec = {"run": int(run), "params": json.loads(params), "notes": notes, "invariants": inv,
       "clean_after": clean_ok == "true", "duration_s": int(dur), **json.loads(extra)}
if "rvcheck_error" in check:
    rec["rvcheck_error"] = check["rvcheck_error"]
if "vault_inspect_error" in check:
    rec["vault_inspect_error"] = check["vault_inspect_error"]
rec["pass"] = rec["clean_after"] and all(v.get("pass") in (True, None) for v in inv.values())
open(runs_file, "a").write(json.dumps(rec) + "\n")
print("run %s: %s  [%s]" % (run, "PASS" if rec["pass"] else "FAIL",
      " ".join("%s=%s" % (k.split("_", 1)[0], {True: "ok", False: "FAIL", None: "skip"}[v.get("pass")])
               for k, v in inv.items())), file=sys.stderr)
EOF
}

scenario_finish() {
  python3 - "$RUNS_FILE" "$OUT" "$SCENARIO" "$TS" "$MODE" "$CEPH_GIT" "$SCEN_CMD" "$POOL" \
           "$((SECONDS - SCEN_START))" "$(cat "$CEPH_BUILD/bin/ceph-osd.build" 2>/dev/null)" <<'EOF'
import json, sys
runs_file, out, scen, ts, mode, git, cmd, pool, dur, marker = sys.argv[1:11]
runs = [json.loads(l) for l in open(runs_file)]
inv_names = ["1_no_resurrection", "2_no_inconsistency", "3_vault_intact", "4_live_intact"]
summary = {"runs": len(runs), "runs_passed": sum(r["pass"] for r in runs)}
for k in inv_names:
    vals = [r["invariants"][k].get("pass") for r in runs]
    summary[k] = {"pass": vals.count(True), "fail": vals.count(False), "skipped": vals.count(None)}
res = {"scenario": scen, "timestamp": ts, "mode": mode, "ceph_git": git,
       "osd_build_marker": marker, "command": cmd, "pool": pool, "duration_s": int(dur),
       "summary": summary, "result": "pass" if runs and summary["runs_passed"] == len(runs) else "fail",
       "runs": runs}
json.dump(res, open(out, "w"), indent=1)
print(f"{scen} [{mode}]: {summary['runs_passed']}/{len(runs)} runs passed -> {out}", file=sys.stderr)
sys.exit(0 if res["result"] == "pass" else 1)
EOF
}

# carry_previous_run: fold the previous run's actions and log offsets into this run,
# so this run's checks also cover objects deleted earlier (e.g. vault entries created
# before a PG split must still be intact after the merge).
carry_previous_run() {
  local prev=$((RUN - 1))
  [[ -f $WORK/state-$prev.jsonl ]] || die "no previous run to carry"
  cat "$WORK/state-$prev.jsonl" "$RUN_STATE" > "$WORK/state-carry"
  mv "$WORK/state-carry" "$RUN_STATE"
  cp "$WORK/offsets-$prev.json" "$WORK/offsets-$RUN.json"
}

# wait_pg_num POOL N [timeout]: pg_num and pgp_num both reach N, then clean
wait_pg_num() {
  local pool=$1 want=$2 timeout=${3:-3600} start=$SECONDS pn ppn
  while (( SECONDS - start < timeout )); do
    pn=$(ceph osd pool get "$pool" pg_num -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["pg_num"])')
    ppn=$(ceph osd pool get "$pool" pgp_num -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["pgp_num"])')
    if [[ $pn == "$want" && $ppn == "$want" ]] && wait_clean 60; then
      log "$pool pg_num=pgp_num=$want and clean after $((SECONDS - start)) s"
      return 0
    fi
    sleep 5
  done
  log "$pool did not reach pg_num $want (pg_num=$pn pgp_num=$ppn)"
  return 1
}

# vault_lines_for NAME: "osd vname" for every vault line of NAME logged during this run
vault_lines_for() {
  local name=$1 n
  for n in $(osd_ids); do
    tail -c +"$(( $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], 0))' "$WORK/offsets-$RUN.json" "$n") + 1 ))" \
      "$CEPH_BUILD/out/osd.$n.log" 2>/dev/null \
      | grep 'replicavault: vaulted' | grep -F " oid=$name " \
      | sed -E "s/.* vname=([^ ]+).*/$n \1/" || true
  done
}

# names_in_pg PREFIX PGID COUNT [NS] [POOL]: first COUNT names "PREFIX-<i>" in PGID,
# computed locally (scripts/pgmap.py, validated against `ceph osd map`)
names_in_pg() {
  local prefix=$1 pgid=$2 count=$3 ns=${4:-} pool=${5:-$POOL} pid pgn
  pid=$(ceph osd pool ls detail -f json | python3 -c "import json,sys; print([p['pool_id'] for p in json.load(sys.stdin) if p['pool_name']=='$pool'][0])")
  pgn=$(ceph osd pool get "$pool" pg_num -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["pg_num"])')
  python3 "$SCEN_DIR/../pgmap.py" find "$pid" "$pgn" "$pgid" "$prefix" "$count" --ns "$ns"
}

# obj_up_acting POOL OBJ -> "pg=P up=[..] acting=[..] primary=N" from the osdmap
# (`ceph pg map` has no primary field; `ceph osd map` has acting_primary)
obj_up_acting() {
  ceph osd map "$1" "$2" -f json | python3 -c 'import json,sys
d=json.load(sys.stdin); print("pg=%s up=%s acting=%s primary=%s" % (d["pgid"], d["up"], d["acting"], d["acting_primary"]))'
}

# pg_state PGID -> the PG state string
pg_state() {
  ceph pg "$1" query 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])'
}

# vault_copies_json NAME... -> JSON {"copies": {name: n}, "bytes": vaulted bytes} for this run
vault_copies_json() {
  local n name
  for n in $(osd_ids); do
    tail -c +"$(( $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], 0))' "$WORK/offsets-$RUN.json" "$n") + 1 ))" \
      "$CEPH_BUILD/out/osd.$n.log" 2>/dev/null | grep 'replicavault: vaulted' || true
  done | python3 -c '
import json, re, sys
names = set(sys.argv[1:]); copies = {n: 0 for n in names}; nbytes = 0
for l in sys.stdin:
    m = re.search(r" oid=(\S*) ns=.* size=(\d+) ", l)
    if m and m.group(1) in names:
        copies[m.group(1)] += 1; nbytes += int(m.group(2))
print(json.dumps({"copies": copies, "bytes": nbytes}))' "$@"
}

# vault_mode: true iff the installed OSD build vaults (pilot "rv" or phase 2 "p2")
vault_mode() {
  [[ $MODE == rv || $MODE == p2 ]]
}
