#!/usr/bin/env bash
# Scenario 4: `ceph osd out` of a non-retaining OSD -> backfill, then of the retaining
# OSD -> backfill (its copy of the PG becomes a stray and is deleted). The vault must
# stay on the retaining OSD and must not appear on any other OSD.
#
# Per run, one PG is the focus: acting [P, R, N] with R the retainer (rank 1).
#   phase A: delete objects (vaulted on R)
#   out N, wait clean; phase B deletes (new acting set); in N, wait clean
#   out R, wait clean; phase C deletes; in R, wait clean
# Extra check "vault_not_copied": every vault entry name of this run exists only on the
# OSD(s) whose log shows the vault line for it.
source "$(dirname "$0")/common.sh"
RUNS=2
scenario_init s04-out-backfill "$@"

# put NUM objects that map to $pg, named $1-<i>; echo their names
put_in_pg() {
  local prefix=$1 num=$2 i=0 name
  for name in $(names_in_pg "$prefix" "$pg" "$num"); do
    put_obj "$name" $(( 32768 + i )); echo "$name"; i=$((i + 1))
  done
}

for run in $(seq 1 "$RUNS"); do
  run_begin "$run"
  seed=$RUN_PREFIX-seed
  put_obj "$seed" 4096
  pg=$(pg_of "$POOL" "$seed")
  read -r -a acting <<<"$(acting_set "$POOL" "$seed")"
  P=${acting[0]} R=${acting[1]} N=${acting[2]}
  note pg "\"$pg\""
  note acting_before "[$(IFS=,; echo "${acting[*]}")]"
  mapfile -t objs < <(put_in_pg "$RUN_PREFIX-o" 18)

  # phase A
  for o in "${objs[@]:0:6}"; do del_obj "$o"; done

  ceph osd out "$N" >/dev/null
  wait_clean 1200 || die "not clean after out osd.$N"
  note acting_after_out_nonretainer "[$(IFS=,; acting_set "$POOL" "$seed" | tr ' ' ',')]"
  for o in "${objs[@]:6:6}"; do del_obj "$o"; done       # phase B
  ceph osd in "$N" >/dev/null
  wait_clean 1200 || die "not clean after in osd.$N"

  ceph osd out "$R" >/dev/null
  wait_clean 1200 || die "not clean after out osd.$R"
  note acting_after_out_retainer "[$(IFS=,; acting_set "$POOL" "$seed" | tr ' ' ',')]"
  for o in "${objs[@]:12:3}"; do del_obj "$o"; done      # phase C
  ceph osd in "$R" >/dev/null
  wait_clean 1200 || die "not clean after in osd.$R"
  note acting_final "[$(IFS=,; acting_set "$POOL" "$seed" | tr ' ' ',')]"

  # vault_not_copied: names present on each OSD vs the OSD that logged them
  logged=$WORK/logged-$run
  : > "$logged"
  for o in "${objs[@]:0:15}"; do vault_lines_for "$o" >> "$logged"; done
  copied=()
  if vault_mode; then
    for n in $(osd_ids); do
      "$INSPECT" names "$n" > "$WORK/names-$n" 2>/dev/null
      while read -r lo vn; do
        if [[ $lo != "$n" ]] && grep -qxF "$vn" "$WORK/names-$n"; then copied+=("$vn@osd.$n"); fi
      done < "$logged"
    done
    wait_clean 900 || true
  fi
  nc_pass=$([[ ${#copied[@]} -eq 0 ]] && echo true || echo false)
  vault_mode || nc_pass=null
  run_end "{\"vault_not_copied\": {\"pass\": $nc_pass, \"vault_lines\": $(wc -l < "$logged"), \"copies_found\": $(printf '%s\n' "${copied[@]:-}" | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().split() if l]))')}, \"retainer\": $R, \"nonretainer\": $N, \"primary\": $P}"
done
scenario_finish
