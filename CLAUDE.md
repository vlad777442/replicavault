# ReplicaVault — phase 2 instructions for Claude Code

You are helping Vlad (PhD student, GSU) continue **ReplicaVault**, a Ceph prototype that keeps a hidden, bounded-lifetime copy of deleted objects so that an attacker with Ceph admin credentials cannot destroy data irrecoverably. The feasibility pilot is finished: see `results/GATE_REPORT.md` (pass with revised hypotheses). This phase fixes what the pilot exposed before the full evaluation.

Read these first, in order:

1. `docs/ReplicaVault-proposal-v2.md`: §1, §3 (threat model), §4.1 (protected-delete contract).
2. `docs/revision-1-copying-vault.md`: the mechanism the pilot adopted.
3. `docs/revision-1a-ordered-vault.md`: corrections and the new requirements B1–B4. **This phase implements B1, B3 and B4, and probes A3.**
4. `results/GATE_REPORT.md` §3 (caveats) and `notes/design-note.md` §§1, 4, 7.

Phase 2 has four goals:
- **(B4)** Make the prototype reproducible from this repository.
- **(B1)** Show that the coverage gap is real and attacker-triggerable, then close it.
- **(B3)** Test crash consistency and read-after-queue instead of arguing them.
- **(A3)** Get an early, honest signal on the apply-path read cost.

---

## Ground rules

1. **Only touch the vstart development cluster** described in `notes/environment.md`. The cephadm cluster whose configuration is in `/etc/ceph` on node0 is not yours: never run commands against it. Before any destructive command, check the `fsid`.
2. **Frozen files stay frozen.** Never edit these: `PILOT_CRITERIA.md`, `docs/revision-1-copying-vault.md`, `docs/revision-1a-ordered-vault.md` once committed, `PHASE2_CRITERIA.md` once committed, or any existing file under `results/` from the pilot. New results go under `results/phase2/`. If you think a frozen criterion is wrong, say so in your report.
3. **Do not change how peering decides authority.** Do not change PG log contents, peering, scrub, or backfill logic. Replication-message changes (for example a new field in `MOSDRepOp` or `MOSDRepOpReply`) are allowed **only** if Vlad approves them at the Phase 2 STOP. If a fix seems to need anything outside these limits, stop and report.
4. **Stop at every STOP.** Write your report to `notes/log.md` and wait for Vlad.
5. **Cite code.** Every claim about Ceph behavior carries a `path:line` into the pinned tree and is marked **verified** (you read it) or **inferred**.
6. **Git.** Ceph changes go on a new branch, `replicavault-p2`, based on `replicavault-pilot`. Workspace changes go to `main`. Small commits, no force-push. **Do not push anything to any remote without Vlad's explicit OK in this session.**
7. **Reproducibility.** Every scenario is a script, and every result is a JSON file recording its command, timestamp, OSD build and Ceph commit. Every scenario runs on vanilla first, as in the pilot.
8. **Protect the time.** Vlad's proposal defense is in mid-October. Anything that will take more than a day beyond its phase's estimate is reported, not quietly absorbed.

---

## Phase 0 — housekeeping and pre-registration (half a day)

1. **Publish the patch (B4).** Run `git format-patch c92aebb2..replicavault-pilot` into `ceph-patch/pilot/`. Add `ceph-patch/README.md` explaining how to apply the patches to a clean v19.2.3 checkout and build both binaries, including `-DENABLE_GIT_VERSION=OFF`. Verify the whole path: fresh clone, apply, build `ceph-osd`, and confirm the build's commit hash and the patch contents match `17451c9`. Commit.
2. **Commit Revision 1a** only after Vlad has confirmed its two *proposed* thresholds (§A3). Ask him if he hasn't already.
3. **Pre-register this phase.** Create `PHASE2_CRITERIA.md` containing the criteria below, today's date, and the Ceph commit. Commit it before writing any phase 2 code. Never edit it afterwards.

```
Phase 2 criteria

Coverage (B1): pass if, on the phase 2 prototype, across pilot scenarios s01–s12
and adversarial scenarios a01–a05, every acknowledged delete has at least one
intact vault entry, and pilot invariants 1, 2 and 4 hold in every run.

Crash consistency (B3): pass if, across at least 100 crash runs (c01), no
acknowledged delete lacks an intact vault entry after restart, and BlueStore
fsck is clean on every OSD. Duplicate entries are counted and reported, not
failures.

Read-after-queue (B3): pass if, across at least 200 runs (c02), the vault
entry's content always equals the last write acknowledged or queued before the
delete.

Limits: fail if closing the coverage gap requires changing how peering decides
authority, PG log contents, scrub, or backfill logic.

Cost probe (A3): no pass/fail. Report only.
```

---

## Phase 1 — demonstrate the coverage gap on the pilot prototype (1–2 days)

Write adversarial scenarios in `scripts/scenarios/`. They use the pilot harness (`common.sh`, `rvcheck.py`), with invariant 3 as defined in the pilot. Run each **on vanilla** (invariant 3 skipped, to validate the script) and **on the pilot prototype** (`17451c9`). Each timing-dependent scenario runs at least 10 times.

- **a01 — rank 1 marked out.** For a target PG, `ceph osd out` its rank-1 OSD so that the new rank 1 is a backfill target. Throttle backfill (`osd_max_backfills 1`, `osd_recovery_sleep`) so the window stays open, and delete objects the backfill target has not received yet.
- **a02 — upmap to an empty OSD.** `ceph osd pg-upmap-items` moves the PG's rank-1 slot to an OSD holding no copy of it; delete during backfill. Needs `ceph osd set-require-min-compat-client luminous`, or whatever v19 requires; record it.
- **a03 — size 1.** Set pool `min_size 1` and `size 1`, then delete. Only deletes are checked here. The replicas removed by the size change are a PG-level path, which is out of scope in v1.
- **a04 — primary-temp.** Use `ceph osd primary-temp` (or primary affinity) so the acting set's primary is not the up set's first OSD. Delete, and check which OSD vaults.
- **a05 — duplicate inflation (B2).** Repeatedly mark the rank-1 OSD down and up while deleting a stream of objects. Report vault copies per delete and retained bytes per deleted byte. No pass/fail.

**Expected:** a01–a03 fail invariant 3 on the pilot prototype. That is the point. Record exactly which deletes went unvaulted and why, with the log lines. If any of them *passes*, explain why before moving on: it means the model in `design-note.md` is wrong somewhere.

---

## Phase 2 — design the fix (1 day) — **STOP after this phase**

Write `notes/b1-design.md`.

**Verify these in code first (cite and mark verified or inferred):**

1. A primary never applies a client delete to an object that it is itself missing. It recovers the object first, or it blocks the op. Find the check.
2. At `issue_op` time the primary knows, for each acting peer, whether the peer will receive an empty transaction (`should_send_op`, `last_backfill`) and whether the peer is missing the object (`peer_missing`). This must be the same condition that determines what the peer actually applies.
3. Whether the client ack waits for the primary's own local transactions, including a vault transaction queued before the PG transaction on the same sequencer.

**Then compare these designs**, including any better one you find:

- **(i) Primary fallback.** The primary vaults locally whenever, in its own view, the rule's retainer will not apply the delete with the object present. No message change.
- **(ii) Retainer confirmation.** Retainers set a flag in `MOSDRepOpReply`, and the primary vaults locally, or delays the ack, when no flag arrives. This needs a message change and Vlad's approval.
- **(iii) Vault on every replica holding the object.** Simplest. It multiplies H1 and H3 costs.

For each design, give:
- whether it enforces contract item 5 ("acknowledged delete implies a durable vault copy") under a01–a04 and under s01–s12;
- the cases where it produces duplicates;
- the files and functions it touches;
- a rough size.

Also cover the recovery-delete path, where the primary applies a delete through `remove_missing_object`, and the whiteout path.

**STOP.** Recommend one design and wait for Vlad.

---

## Phase 3 — implement and rerun everything (2–3 days)

Implement the approved design on `replicavault-p2`. Keep `RETAIN_RANK` and the log format. Add a `path=fallback` (or equivalent) value to the `replicavault: vaulted` log line, so scenarios can see which mechanism made each copy.

Rebuild, then run `smoke.sh`, **all of s01–s12**, and **all of a01–a05**, on both vanilla and the phase 2 build. Write results to `results/phase2/`. Every scenario that passed in the pilot must still pass. a01–a04 must now pass invariant 3.

Then export the phase 2 patch series to `ceph-patch/p2/`, the same way as in Phase 0.

---

## Phase 4 — crash consistency and read-after-queue (1–2 days)

- **c01 — crash under deletes.** Stream deletes of objects from 4 KiB to 8 MiB against a PG, and SIGKILL the retaining OSD after a random delay. Restart it, wait for clean, run `ceph-bluestore-tool fsck` while the OSD is stopped, and check invariants 1–4. At least 100 runs. Record: acknowledged deletes, vault entries found, duplicates, and any delete in flight at kill time that was *not* acknowledged. Check whether BlueStore offers a debug option that stops between KV submissions. If one exists, add runs that use it. Do not invent option names; cite the option from the source.
- **c02 — read-after-queue.** With librados AIO (Python `rados` bindings are fine), issue `aio_write_full(obj, new_bytes)` and then immediately `aio_remove(obj)`, without waiting for the write to complete. Check that the vault entry holds `new_bytes`. At least 200 runs, varying object size and the number of in-flight writes.

If c01 or c02 finds a missing or wrong vault copy, stop and report with logs before changing anything.

---

## Phase 5 — cost probe (1 day, indicative only)

This is not the H1 evaluation. It is an early warning for A3.

- On the vstart cluster, keep reading and writing 4 KiB objects in one pool, while deleting objects of 1, 4, 16, 64 and 128 MiB in the same pool, on vanilla and on the phase 2 build. Report p50 and p99 of the 4 KiB ops on the retaining OSDs, per deleted-object size, plus delete latency itself. Use `ceph daemon osd.N perf dump` counters where they help.
- The Debug build and file-backed OSDs distort absolute numbers. If building a RelWithDebInfo pair takes less than half a day, use it and say so. Either way, label the numbers "indicative, single host".
- If 64–128 MiB deletes visibly stall 4 KiB ops, note possible mitigations (for example, chunked reads or moving the read off the op shard) in `notes/b1-design.md` §"Future work", without implementing them.

---

## Phase 6 — report

Write `results/phase2/PHASE2_REPORT.md`:

- Each criterion in `PHASE2_CRITERIA.md`: pass or fail, evidence (result files, run counts), and caveats.
- The design implemented, how it differs from `b1-design.md`, and the exact files touched.
- a01–a05 before and after the fix, side by side.
- Crash and read-after-queue findings, and duplicate counts.
- The cost probe, with its limits stated plainly.
- Anything that changes the proposal's H1, H2 or H3, or needs a Revision 1b. Draft the revision text in the report; don't create the revision file.

Vlad makes the call.

---

## Out of scope for you

- Verifying pilot claims *for* Vlad's defense. He does that himself; answer his questions when asked.
- Proposal steps 6 and 7 (the capacity trace analysis and the prior-art reading).
- The full H1 evaluation on the multi-host testbed.
- PG-level retention (pool deletion, size reduction, stray-PG removal, backfill-remove).
- Overwrites, erasure-coded pools, the reclaimer daemon, the policy file, and an online vault reader.
