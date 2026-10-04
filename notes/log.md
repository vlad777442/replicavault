# Pilot log

## 2026-09-25
- Phase 0: found no source build or vstart cluster; `/etc/ceph` points at a separate cephadm cluster on node0 (left alone). With Vlad's OK: formatted `sdb` → `/data`, cloned Ceph v19.2.3 (`c92aebb2`), installed deps, started Debug build.
- Committed proposal and `PILOT_CRITERIA.md` (pre-registration, frozen).
- Phase 1: wrote `notes/step1-primitive.md`. Verdict: no supported zero-copy move/clone out of a PG collection. Recommend option (a) — copy into a hidden namespace in the meta collection. **STOP: waiting for Vlad's decision on mechanism.**
- Build done (10 min). vstart up: 1 MON, 1 MGR, 5 OSD BlueStore, fsid 224f2f2c-…; osd.2/3 mkfs raced, fixed by hand. Pool `rvtest` created. OSD kill/restart verified. Incremental ceph-osd rebuild 59 s. Phase 0 complete.
- Phase 2: `scripts/lib.sh`, `scripts/smoke.sh` pass on vanilla (results/smoke-20260925T173923.json, smoke-20260925T174318.json; ~70 s/run). Added `scripts/negative-control.sh`: offline-corrupts one replica via ceph-objectstore-tool; deep scrub + check_inconsistent detected it (PG 1.1d) and repair restored clean (results/negative-control-20260925T174145.json).
- Harness bug found and fixed: SIGTERM'd OSD is marked down before it exits → offline tool hit a locked store. `kill_osd` now waits for down *and* process exit. First negative-control attempt aborted with `noout` set; cleaned up by hand, script now clears it via trap.
- Standing HEALTH_WARN "12 mgr modules have failed dependencies" (python deps for mgr modules in the dev build). Harmless for the pilot; check_inconsistent ignores it.
- Phase 3 (first pass): `notes/design-note.md` (delete path primary→replica, hook points, bypass paths, scrub/backfill/snap-trim/stray/split-merge) and `notes/destructive-paths.md` (22 rows). Findings: (1) primary encodes subop txn before queuing its own, so local rewrite is invisible to replicas; replica can rewrite `rm->opt` in `do_repop`. (2) One `queue_transactions` = one BlueStore txc, so vault copy + remove are atomic. (3) Recovery-delete and backfill-remove bypass `do_repop` → coverage gap when rank 1 was down; recommend hooking `remove_snap_mapped_object` too. (4) `trim stale osdmaps` admin command deletes meta objects whose name contains `osdmap.` → vault names must be hex-encoded.
- Open for Vlad: mechanism (Phase 1), recovery-delete hook, whiteout handling.

## 2026-09-26
- Vlad: mechanism (a) approved; yes to vaulting recovery-path deletes and whiteout heads. Asked me to draft the revision.
- Drafted `docs/revision-1-copying-vault.md` (H1 restated with proposed thresholds, Figure A reframed, B3 dropped, consequential edits, scope decisions). Not committed: waiting for Vlad to confirm thresholds, because committing freezes it and building can't start until it's committed.
- Vlad kept the thresholds. Committed revision 1; starting Phase 4.
- Phase 4: prototype built (ceph `ca2a5b2`, `17451c9`). Hooks in `do_repop` and `remove_missing_object`; module `src/osd/ReplicaVault.{h,cc}`. Probe delete vaulted only on rank 1 with matching sha256; smoke passes on prototype.
- Bug found: vault copy in the PG txc → vault bytes charged to PG pool → BlueStore fsck statfs errors on retaining OSDs. Fixed by queuing the vault copy as its own txc on the same sequencer (order preserved by `_txc_finish_io`). Repaired all OSD stats; fsck clean after re-test.
- `scripts/vault-inspect.sh` (dump/list/extract/restore). Harness bug: objectstore-tool `get-bytes` silently refuses to overwrite a file (EEXIST, exit 0) — script now removes temp file first. Manual restore of `rvprobe-1`: new version 13 > vaulted 6, content matches.
- Phase 5 started. Tooling: `scripts/use-build.sh vanilla|rv` (installs bin/ceph-osd.<build>, records bin/ceph-osd.build, rolling restart; lib `rv_build`, stale-binary check), `scripts/scenarios/common.sh` (per-run state + log offsets, run_end = wait clean + deep-scrub + invariants), `scripts/scenarios/rvcheck.py` (invariants 1, 3, 4), 11 scenario scripts, `run-all.sh`. `vault-inspect.sh` gained `check` and `names`.
- Environment problem: first attempt to run vanilla OSD failed — plugin version check (`lib/*.so` rebuilt at rv HEAD report `19.2.3-2-g17451c9`, vanilla binary expects `19.2.3`; the string comes from `git describe` at cmake time). osd.0 restored on the rv binary. Fix: reconfigure with `-DENABLE_GIT_VERSION=OFF` (fixed "Development" version for all binaries and plugins) and rebuild both OSD binaries.
- s10 script bug: `rados -s` prints 'selected snap' to stdout, polluted snapshot checksum; content was correct. Fixed. s02 delays shifted to 0.05-0.5 s (first vanilla run: delays <= 0.1 s always killed before the op was sent). Both to be rerun on vanilla.
- Vanilla suite: all 11 scenarios pass (s10 and s02 after the fixes above; the superseded s10 vanilla result file with 0/3 is kept for the record). Switching to rv build.
- Prototype suite: all 11 scenarios pass (results/*-20260926T1645..1921*.json). Added s12 (rank-1 OSD misses a delete → recovery-path vault); running vanilla then rv.
- s12: vanilla 10/10, rv 10/10 (recovery-path vault fires; 2 copies per missed delete). Final fsck on all 5 OSDs clean with 601 vault entries (results/final-fsck-*.json). Phase 5 complete.
- Phase 6: results/GATE_REPORT.md written. Recommendation: pass with revised hypotheses. (Caught and fixed two wrong numbers while cross-checking the report against result files: vault-check total 646, not 814; s02 prototype timing split 10/2/8.)

## 2026-09-28 — Phase 2 (project phase 2), Phase 0
- Committed `CLAUDE.md` (phase 2 instructions) and Revision 1a (Vlad confirmed H1b 1.5×, H1e 50%; only the status line was edited before commit).
- Pre-registered `PHASE2_CRITERIA.md` (verbatim from CLAUDE.md, diff-checked) at `1a01660`, before any phase 2 code. Created Ceph branch `replicavault-p2` at `17451c9` (no changes yet).
- B4: `git format-patch c92aebb2..replicavault-pilot` → `ceph-patch/pilot/0001,0002`; `ceph-patch/README.md` explains apply and build, including `-DENABLE_GIT_VERSION=OFF` and `-DWITH_PYTHON3=3.12`.
- B4 verification from scratch (`/data/verify-ceph`): fresh `--depth 1` clone of v19.2.3 + `git am --committer-date-is-author-date` gives HEAD **`17451c9003d3e9b5e72d1d1a09b2397cf33eab1f`**, identical commit hash and tree (`601bacda…`) to the pilot branch; 5 files, +387 lines. Clone+apply 161 s; cmake + `ninja ceph-osd` done at 673 s total. The build reports version "Development" and contains the `replicavault: ` log strings. The binary is not byte-identical to `bin/ceph-osd.rv`: Debug binaries embed absolute source paths (2,202 `/data/verify-ceph/` strings vs 1,925 `/data/ceph/src` ones), so this is expected; the source is identical.

## 2026-09-28 — phase 2, Phases 1–2 — **STOP: waiting for Vlad**

**Phase 1 (coverage gap).** a01–a05 written, and all five pass on vanilla (results in `results/phase2/`). On the pilot prototype `17451c9`:
- a01 10/10 pass, a02 10/10 pass. **Not the expected failures.** Backfill targets never enter the acting set (`PeeringState.cc:1742–1747`); the out or upmapped OSD's old copy stays in acting through `pg_temp`, and the next complete OSD becomes rank 1 and vaults (80/80 each).
- a03 **0/3**: acting size 1, 24/24 deletes unvaulted.
- a04 **5/10**: when primary-temp puts the primary at acting[1], 25/25 unvaulted, because the retainer is the unhooked primary. When it puts it at acting[2], all vaulted.
- a05: exactly 2 copies per missed delete, retained/deleted = 2.00.

So the pilot's coverage model (design-note §§1, 4; GATE_REPORT caveat 2) named the wrong gap. The real gaps are **G1** (acting has no rank 1) and **G2** (rank 1 is the primary). Details and log evidence: `notes/b1-design.md` §5.

**Phase 2 (design).** All three facts verified in code (`b1-design.md` §1):
1. The primary never applies a delete to an object it is missing.
2. `should_send_op` sends empty transactions only to backfill targets or async-recovery targets missing the object, and neither is ever in the acting set.
3. The client ack waits for the primary's own commit, so a vault transaction queued first on the same sequencer is durable before the ack.

**Recommendation: design (i), primary fallback, with a primary-first retainer function.** retainer = first acting OSD that is not the primary, else the primary. The primary vaults locally only when it is the retainer (acting size 1). No message, peering, PG log, scrub or backfill change; about 60–90 lines; closes G1 and G2.

**Decisions for Vlad:**
- (a) Approve (i).
- (b) Under primary-temp the retainer becomes acting[0] rather than acting[1]; acceptable?
- (c) Correct the wrong gap description in a Revision 1b note (GATE_REPORT is frozen)?
- (d) Revision 1a B1's listed attacks (out, upmap, pg-temp) do not open a gap; size 1 and primary-temp do.

## 2026-09-28/29 — phase 2, Phase 3
- Vlad approved design (i), with acting[0] as the retainer under primary-temp, and asked for a Revision 1b correction to be drafted (it goes into the phase 2 report).
- Implemented on `replicavault-p2` as `ef0be10`: `retainer_osd()` (primary-first acting order; the primary itself if the acting set has no other member), a primary hook in `ReplicatedBackend::submit_transaction` (after `issue_op`, before `log_operation`, own txc queued ahead of `op_t`, `path=fallback`), and `do_repop` / `remove_missing_object` switched to the retainer function. The CRUSH mapping runs only for transactions that delete a head. 4 files; no message, peering, PG log, scrub or backfill change.
- Harness: `p2` build mode (`use-build.sh p2`, rvcheck, `vault_mode`); new result files now default to `results/phase2/` (smoke, negative-control, scenarios), so nothing can land beside the frozen pilot results.
- Full matrix (smoke, s01–s12, a01–a05) on vanilla, then p2: **34/34 scenario results pass, both smoke runs pass** (`results/phase2/`, log `results/phase2/logs/phase3-full-20260928T*.log`). On p2, a03 3/3 (every delete vaulted `path=fallback` by the single acting OSD) and a04 10/10 (primary at acting[1] → acting[0] vaults via `repop`). a05 on p2: 2 copies per missed delete, retained/deleted 2.00, unchanged from the pilot.
- B4 for p2: `ceph-patch/p2/` (3 patches) applied on the fresh clone reproduces `ef0be10b…` exactly (commit and tree `2ad62347…`); incremental `ninja ceph-osd` 104 s; the binary contains `retainer_osd` and `vault_deleted_heads`.
- Harness bug noticed: this node's `grep` is ugrep, which rejects backreferences, so my "not all runs passed" filter in the overnight failure watcher never worked. The results were checked afterwards in python instead; no failures.

## 2026-09-29 — phase 2, Phase 4 — results and a finding for Vlad
- Results in `results/phase2/`:
  - c01 vanilla 20/20 (script validation: 12 default, 4 sync, 4 sync+rand; a deliberate reduction from 100 to save about 5 h, full 100 on p2).
  - c02 vanilla 10/10 (200 cases).
  - **c01 p2 100/100:** 60 default, 20 `bluestore_sync_submit_transaction`, 20 sync + `bluestore_debug_randomize_serial_transaction=2`. 1,600/1,600 acknowledged deletes have an intact vault entry after restart; fsck clean on the killed retainer in 100/100 runs; no delete went unacknowledged (the client resent every in-flight remove); 1,405 of the 1,600 were acknowledged after the kill.
  - **c02 p2 10/10:** 200/200 cases; the vault always held the last queued write (sizes 4 KiB–8 MiB × 1–4 in-flight writes, 40 or 50 per cell).
  - Duplicates: 19 of 1,600 deletes have 2 intact copies, 1,581 have 1.
- No BlueStore option stops between KV submissions. The two used change submission grouping: `global.yaml.in:5180`, `:5354`; `BlueStore.cc:14192–14213`.
- **Finding (does not fail the pre-registered c01 criterion, which is checked after restart):** for 993 of the 1,600 acknowledged deletes, the only intact vault copy was made by the killed retainer **through recovery after it restarted** (`path=recovery`).
  - Its original staging (`path=repop`, logged) died with the crash; there are 148 such "logged but never durable" `vaulted` lines across the run. So a `vaulted` log line records staging, not durability.
  - No other OSD vaulted these deletes. The client's acknowledgement was sent after the kill because, on the interval change, `apply_and_flush_repops` (`PrimaryLogPG.cc:12825–12865`) requeues the in-flight ops, the resent op is a dup (`check_in_progress_op`, `:2230–2244`), and `already_complete` (`:15453–15478`) only checks repops still queued in the new interval.
  - The new acting set (primary + old rank 2) had applied the remove without vaulting. At ack time the pre-delete bytes were therefore durable only on the crashed retainer's disk, as its vault entry or as the not-yet-removed object.
  - **So contract item 5 (Revision 1a B1: the ack waits for a durable vault copy) is not enforced for deletes in flight when the retainer crashes.** If that OSD never returned, those deletes would have no copy.
  - Verified in code and observed; no fix attempted. Enforcing item 5 here would need a second copy staged before the non-retainers remove (e.g. primary also vaults, or retainer confirmation plus a fallback copy), i.e. a design change for Vlad.

## 2026-09-29 — phase 2, Phases 5–6
- Cost probe (A3): RelWithDebInfo pair built in 34 min (`/data/ceph/build-rel`, ceph-osd.vanilla and .p2); separate 3-OSD vstart cluster, fsid `e6e34e84-822b-4fe5-859c-e245368dcab6`, ports 42000/42001; the same `--mkfs` race hit osd.2 and was fixed by hand as before. `scripts/cost-probe.{py,sh}`; results `results/phase2/cost-probe-*.json`. Larger-sample run (20 deletes/size, 16 threads): 4 KiB p99 during deletes vs vanilla 1.1× (1 MiB), **1.7× (4 MiB)**, 1.2× (16), 3.5× (64), 4.8× (128); delete p50 2.1× at 4 MiB, 13× at 128 MiB. mClock pacing and file-backed OSDs inflate absolute numbers; only ratios mean anything.
- Wrote `results/phase2/PHASE2_REPORT.md` (criteria, design as built, a01–a05 before/after, crash findings, cost probe, draft Revision 1b). All four pass/fail criteria pass. Two findings for Vlad: (1) the pilot's coverage gap was misdescribed (size 1 and primary-temp are the real gaps, now closed); (2) item 5 is not enforced when the retainer crashes mid-delete (bytes durable only on that OSD). H1b and H1e are flagged at risk.

## 2026-09-29 — Vlad's decisions on the phase 2 report, and c03 — **STOP (finding 2)**
- Vlad: phase 2 accepted with finding 2 open; add c03; fix the log line; Revision 1b as a file with item 5 PENDING c03 and no H1b/H1e pass/fail wording; push `main` (incl. `ceph-patch/`) after c03 and the c01 rerun are committed.
- Traced (verified): a returning OSD whose PGs were remapped is a stray. It gets no log (`PeeringState.cc:2748–2850`), is added to `stray_set` (`:340–346`), and is purged (`:241–270` → `MOSDPGRemove` → `PG::do_delete_work`, `PG.cc:2716–2762`, direct `t.remove`, no `remove_missing_object`, no vault).
- Log fix: `25b9d8d` (`replicavault-p2`). The `vaulted` line is emitted from the vault txc's on_commit context, with `r=` appended.
- Revision 1b draft committed: `docs/revision-1b-coverage-and-ack-window.md` (`1dcf572`).
- c03 written (`scripts/scenarios/c03-retainer-out-during-deletes.sh`). Vanilla 5/5 (script validation; strays purged in 10–13 s; on vanilla all deletes finish before the kill, so the window is not exercised there). **p2 run 1: 10 of 16 acknowledged deletes have no vault copy anywhere** after the retainer was killed, marked out, recovered around, and purged as a stray. STOP per Vlad's instruction. Fix proposals in `notes/b1-design.md` §6 (recommend F1: the primary also vaults). Nothing implemented. The remaining c03 runs and the c01 rerun (log-fix check) continue in the background; they change no code.
- c03 p2 complete: **1/20 runs pass; 261 of 320 acknowledged deletes lost**. The lost ones are, almost exactly, the deletes acknowledged after the retainer's kill (261 of 263); none acknowledged before it was lost. Strays purged in 20/20; invariants 1, 2 and 4 hold in 20/20. Details in `b1-design.md` §6.1. The c01 rerun (log-fix check) is still running.

## 2026-09-29 — F1
- Vlad chose F1. Implemented as `05289b5` (`replicavault-p2`): the primary vaults every delete (`path=primary`), and recovery vaults on the primary and on the retainer. Smoke passes, with 2 copies per delete.
- **c03 on F1: 20/20 pass, 0/320 acknowledged deletes lost** (before F1: 261/320 lost). 253 survived only via the primary's copy. `b1-design.md` §6.3.
- Revision 1b draft updated: item 5 now carries a PROPOSED restatement with c03 results, awaiting Vlad's confirmation.
- The c01 rerun (100 runs, log-fix check, now on the F1 build) is running. The push to origin follows its commit, as agreed.
- c01 rerun on F1 (`05289b5`, `results/phase2/c01-crash-under-deletes-20260929T222223.json`): **100/100 runs**, 1,600/1,600 acknowledged deletes with an intact copy (1,585 acknowledged after the kill), fsck clean 100/100. **Log-fix check: 3,282 `vaulted` lines, 0 without a durable copy** (before the fix: 148). Copies per delete: 1 (69), 2 (1,380), 3 (151). Paths: 1,600 primary, 204 repop, 1,478 recovery. (An earlier c01 rerun on `25b9d8d` was stopped at run 43 to switch to F1; its partial log is kept but it wrote no result file.)

## 2026-09-30 — F1 regression and cost
- F1 regression on the p2 build `05289b5`: s01–s12 and a01–a05, **118/118 runs**, 1,000/1,000 deletes vaulted. a05: 3 copies per missed delete, retained / deleted bytes 3.00.
- Cost probe on the F1 release build: delete p50 22× vanilla at 128 MiB (13× before F1); 4 KiB p99 11× (4.8× before F1).
- `ceph-patch/p2/` re-exported (5 patches) and verified: reproduces `05289b5` exactly; builds in 110 s on the fresh clone.
- Vlad pushed `main` to origin up to `a194ae0`. This commit needs another push.
- Wrote and committed `notes/advisor-update-2026-09-30.md` before the F1 regression finished. It lists the regression and cost probe as in progress, and gives pre-F1 cost numbers.

## 2026-10-01 — Vlad's follow-ups
- Item 2 (the 69 single-copy deletes in F1 c01 `…T222223`): all 69 also have an intact vault entry on the retainer, checksum-verified, that was durable but never logged. SIGKILL landed between the vault txc's kv commit and its on_commit callback (`BlueStore.cc:14457–14467`, `Transaction.h:46–49`). Their retainer log already held the delete, so recovery did not re-vault. Each has 2 copies.
- **Same blind spot, larger effect:** the pre-F1 c03 "261 lost" includes 97 deletes with such an entry (97/97 intact, expected bytes). **True loss: 164/320, 18/20 runs.** F1 c03 "253 primary-only" is 230. Corrected in `b1-design.md` §§6.1, 6.3, 6.4 and the advisor note. `PHASE2_REPORT.md` and Revision 1b still say 261 (wording proposed to Vlad, not committed).
- Harness: `rvcheck.py --disk-scan` (`03e41c7`); c04 written (primary failure; A = returns as stray, B = never returns); running vanilla then F1, 20 runs per variant.
- Advisor note updated (F1 regression, F1 cost, shared-disk caveat, corrected counts, c04 pending).
- c04 complete. Vanilla A 20/20, B 20/20. **F1 A 20/20, B 20/20; 0 of 320 acknowledged deletes lost in each** (305 and 300 acked after the primary's kill). Survivors: the retainer's repop copy, or the new primary's and new retainer's copies for resent ops; 30 of P's copies in A were durable but unlogged and found by the disk scan. `b1-design.md` §6.5.
- Item 3 (rewrite Revision 1b item 5 and the PHASE2_REPORT addendum claim to only what c01, c03 and c04 support): wording drafted and shown to Vlad, **not committed**.
- Vlad approved the item 3 wording. Committed: Revision 1b final (item 5 limited to the c01/c03/c04 evidence; counts corrected to 164 and 230), PHASE2_REPORT addendum corrected (adds c04), advisor note with c04 results.

## 2026-10-03 — zero-copy pilot, Phase 0
- Committed `CLAUDE.md` (zero-copy pilot) and proposal v3, with §4.1 item 5 restated as a design goal and the following paragraph de-duplicated, per Vlad.
- `ZC_CRITERIA.md` pre-registered (`9b20da1`), with the fsck rule as amended by Vlad: deep fsck after every run for z01 and z06; elsewhere a regular fsck per run plus one deep fsck per batch; the disk scan every run. Diff-checked against CLAUDE.md: only that rule differs.
- Ceph branch `replicavault-zc` created at `05289b5`.
- Debug build reconfigured `WITH_TESTS=ON`; `ceph_test_objectstore` built (260 s); `ceph-osd` unchanged.
- Fresh vstart cluster `/data/zc`, fsid `b0729c2b-…` (`notes/environment.md`). Scripts now default to it, with results in `results/zc/`. Smoke passes on F1.
