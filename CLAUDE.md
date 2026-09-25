# ReplicaVault pilot — instructions for Claude Code

You are helping Vlad (PhD student, GSU) run a three-week feasibility pilot for **ReplicaVault**, a research prototype that makes Ceph keep a hidden, bounded-lifetime copy of deleted objects on one replica without disturbing Ceph's correctness. The full proposal is `docs/ReplicaVault-proposal-v2.md`. Read §1, §4.1–4.2, and §6 before doing anything else.

The pilot answers one question: **can a replica hold hidden pre-deletion data without breaking peering, backfill, scrub, or object recreation?** It is a go/no-go gate, not a product. Favor evidence over polish, and stop early if the evidence says no.

---

## Ground rules

1. **Only touch the development cluster.** Before any destructive command, confirm you are talking to the vstart cluster in this workspace (check `fsid` against `notes/environment.md`). Never run `ceph orch` commands, never zap devices, never touch any other cluster or host.
2. **Pre-registration is immutable.** Phase 0 commits `PILOT_CRITERIA.md`. After that commit, never edit it. If you think a criterion is wrong, say so to Vlad in your report; do not change the file.
3. **Do not change how peering decides authority.** Do not modify PG log semantics, peering, scrub, or backfill code. If making a scenario pass seems to require it, stop immediately and report — that is a gate-fail signal, not a bug to work around.
4. **Stop at checkpoints.** Each phase ends with a report and, where marked **STOP**, wait for Vlad before continuing.
5. **Cite code, don't paraphrase it from memory.** Every claim about Ceph behavior in the notes carries a `path:line` reference into the pinned source tree, plus the commit hash. If you have not read it, say "unverified."
6. **Git discipline.** Work on branch `replicavault-pilot` in the Ceph tree and on `main` in this workspace repo. Small commits with descriptive messages. Never force-push, never push upstream.
7. **Record everything reproducibly.** Every scenario is a script; every result is a file under `results/` with timestamp, git hash of the Ceph build, and the command that produced it.

## Workspace layout (create if missing)

```
docs/ReplicaVault-proposal-v2.md
PILOT_CRITERIA.md          # Phase 0, then frozen
notes/
  environment.md           # Phase 0
  step1-primitive.md       # Phase 1
  design-note.md           # Phase 3
  destructive-paths.md     # Phase 3 (inventory table)
  log.md                   # running daily log: date, what was done, what's blocked
scripts/
  lib.sh                   # cluster helpers (kill/restart OSD, acting set, wait-for-clean)
  smoke.sh                 # Phase 2
  scenarios/               # Phase 5, one script per scenario
  vault-inspect.sh         # list/extract vault entries via ceph-objectstore-tool
results/
  GATE_REPORT.md           # Phase 6
```

---

## Phase 0 — environment inventory and pre-registration (day 1)

Vlad has already set up a cluster. Find out exactly what it is and record it in `notes/environment.md`:

- Ceph version and git commit (`ceph --version`, `git -C <ceph-src> rev-parse HEAD`), build type (Debug vs RelWithDebInfo), build directory path.
- How the cluster was started. **The pilot requires a source build run with `vstart.sh`**, because Phase 4 modifies the OSD. If the cluster is a package or cephadm install, stop and tell Vlad before going further.
- Number of MONs, MGRs, OSDs; object store (must be BlueStore); `fsid`; how to kill and restart a single OSD in this setup (e.g. `out/osd.N.pid`, `bin/init-ceph`, or re-running `bin/ceph-osd -i N -c ceph.conf`). Verify the restart method actually works and write down the exact commands.
- Disk, RAM, and cores available, and how long an incremental rebuild of `ceph-osd` takes.

Then create a test pool if none exists: replicated, `size 3`, `min_size 2`, `pg_num 32`, autoscaler **off** (it is turned on only in the split/merge scenario).

Create `PILOT_CRITERIA.md` containing, verbatim, the **Gate** and **Decision rule** paragraphs from §6 of the proposal, plus today's date and the Ceph commit hash. Commit it with the message `pre-register pilot criteria`. Do not edit it again.

Report: a summary of the environment and anything that blocks the pilot.

---

## Phase 1 — primitive check (days 1–2, from source) — **STOP after this phase**

This is the cheapest question that could end or reshape the project, so it comes first. It needs only the source tree.

**Question:** can BlueStore move or clone an object into a collection *outside its PG* without copying the data?

Read and cite:

- `src/os/Transaction.h` — `OP_COLL_MOVE_RENAME`, `OP_TRY_RENAME`, `OP_CLONE`, `OP_CLONERANGE2`, `OP_SPLIT_COLLECTION2`, `OP_MERGE_COLLECTION`, `OP_MKCOLL`.
- `src/os/bluestore/BlueStore.cc` — `_txc_add_transaction` (look for assertions that source and destination collections match), `_rename`, `_clone`, `_do_clone_range`, `_split_collection`, `_merge_collection`, `_create_collection`.
- `src/os/bluestore/BlueStore.h` — how `SharedBlob` / `SharedBlobSet` are scoped (per collection? per cache shard?), and what a cross-collection reference would break.
- `src/osd/osd_types.h` — `coll_t` types (meta, PG, temp) and what a vault collection could be.
- `src/osd/OSD.cc` — what the OSD does at boot with every collection it finds (`load_pgs`, temp-object cleanup, anything that deletes or asserts on unrecognized collections). Consider whether the vault is safer as a new collection type or as a namespace inside the existing meta collection.

Write `notes/step1-primitive.md` with:

1. A direct answer to the question, with citations.
2. Which option from proposal §4.2 follows: **(a)** copying move, **(b)** extending BlueStore, **(c)** vault as a hidden namespace inside the PG collection — or any other mechanism you find (for example, a split/merge-style collection operation, or reusing snapshot clones within the PG), with its trade-offs.
3. For the recommended mechanism: what the OSD would do at boot, during scrub, and during backfill with vault data present, and which of those you have verified in code versus inferred.
4. Your confidence and what would change the answer.

**STOP.** Report the verdict to Vlad and wait for his decision on the mechanism before Phase 4. (Phases 2 and 3 may proceed while waiting.)

---

## Phase 2 — environment smoke test (days 1–3)

Write `scripts/lib.sh` with helpers: `acting_set <pool> <obj>` (from `ceph osd map`), `kill_osd N`, `restart_osd N`, `wait_clean` (poll until all PGs `active+clean`, with a timeout), `deep_scrub_all <pool>` (issue scrubs and wait until they complete, not just start), `check_inconsistent <pool>` (`rados list-inconsistent-pg` and `ceph health detail`).

Write `scripts/smoke.sh` on the **unmodified** build: put objects of several sizes, read them back with checksums, delete some, kill and restart an OSD, wait for clean, deep-scrub every PG, assert zero inconsistencies. It must pass cleanly on vanilla Ceph before any scenario result means anything.

---

## Phase 3 — trace the destructive paths (days 3–7)

Follow an object delete end to end and write `notes/design-note.md`:

- `PrimaryLogPG` (`do_osd_ops` for `CEPH_OSD_OP_DELETE`, `_delete_oid`, whiteouts when snapshots exist) → `PGTransaction` → `ReplicatedBackend::submit_transaction` / `generate_transaction` → `MOSDRepOp` → `ReplicatedBackend::do_repop` on replicas → `ObjectStore::Transaction` applied by BlueStore.
- Where exactly a single OSD — primary or replica — could rewrite *its own* local remove into a vault move, leaving the PG log entry and the transaction sent to other replicas unchanged.
- How snapshot clones are retained and trimmed (`SnapTrimmer`), how scrub builds its per-replica object map (and whether it could ever list the vault), how backfill enumerates objects, how stray PGs are deleted after remapping (`PG::do_delete_work` or equivalent), and how PG split/merge rewrite collections.

Begin `notes/destructive-paths.md` as a table: *path | entry point (command/op) | code location | removes data how | routed through vault in v1? | notes*. Include object delete, `purge`, pool deletion, pool size reduction, stray PG removal, snap trim, PG merge. Completeness matters more than depth here.

---

## Phase 4 — minimal prototype (week 2) — only after Vlad approves the Phase 1 mechanism

Scope: **object deletes only**, on a replicated pool. No PG-level paths, no overwrites, no reclaimer daemon, no policy file.

- Retention rule for the pilot: the OSD at **acting-set rank 1** at the time it applies the delete retains the object. Rank 0 (primary) and rank 2 delete normally. Make the rank a compile-time or hard-coded constant; do not add a `ceph config` option.
- Rewrite only that OSD's local transaction: the remove becomes a move into the vault, using the mechanism Vlad approved. Vault entry name encodes pool, PG, object name (including namespace and locator), object version, and deletion time, so repeated delete-and-recreate of one name produces distinct entries.
- Record a checksum of the data at vault time (in an xattr or omap on the vault entry).
- Log every vault move at a fixed debug level with a greppable prefix: `replicavault: vaulted pool=… pg=… oid=… v=… osd=…`. The scenarios use these lines as ground truth for where copies should be.
- Do not add any command that releases or deletes vault data.
- Rebuild only what changed; rerun `scripts/smoke.sh` after each rebuild.

Write `scripts/vault-inspect.sh`: stop an OSD, use `ceph-objectstore-tool` to list vault entries and extract one entry's bytes, restart the OSD. For the pilot, restore is manual: extract bytes, verify checksum, `rados put` under the original name, and confirm the result is a new object version.

---

## Phase 5 — scenario suite (week 3)

One script per scenario in `scripts/scenarios/`. Each script:

- runs against a fresh or known state, writes objects with known checksums, and records acting sets before acting;
- repeats **at least 10 times** where timing matters (kills "during" a delete are racy; vary the delay);
- after each run: waits for clean, deep-scrubs every PG, and checks the invariants below;
- writes `results/<scenario>-<timestamp>.json` with pass/fail per invariant, per run.

**Run every scenario first on the vanilla build** (vault checks skipped) to confirm the script itself is sound, then on the prototype.

Invariants checked after every run:

1. **No resurrection:** every acknowledged-deleted object returns `ENOENT` (`rados stat`), and never reappears in `rados ls`.
2. **No inconsistency:** deep-scrub reports zero inconsistent objects or PGs.
3. **Vault present and intact:** for every acknowledged delete, at least one vault entry exists on an OSD whose log shows a `replicavault: vaulted` line for it, and its checksum matches the checksum recorded at write time.
4. **Live data unaffected:** every object that was not deleted reads back with the correct checksum.

Scenarios (from proposal §6, step 5):

1. Primary killed **before** a delete (delete lands on the new primary).
2. Primary killed **during** a delete (racy; many runs).
3. Primary killed **after** a delete, then restarted.
4. `ceph osd out` of a non-retaining OSD → backfill; then of the retaining OSD → backfill. The vault must stay on the retaining OSD's disk and must not be backfilled anywhere.
5. Deep-scrub of every PG with vault entries present.
6. Same object name recreated after deletion; content of the new object is correct and independent of the vault.
7. Repeated delete-and-recreate of one object name (e.g. 20 cycles): one distinct vault entry per cycle.
8. **OSD restart** of the retaining OSD with vault entries on disk: vault not deleted, not treated as a stray or temp collection, no assert; entries intact.
9. **pg_num change** with the autoscaler on (or set directly): split, then merge, while vault entries exist for the affected PGs.
10. **Delete of an object with snapshot clones** (pool snapshot via `rados mksnap`, then delete the head): document what the prototype does and whether invariants hold; do not change snapshot semantics.
11. **Manual restore** of a sample of vault entries via `scripts/vault-inspect.sh`: content matches, and the restored object has a new version.

If a scenario fails, diagnose before touching code. Classify each failure as: *script bug*, *prototype bug*, or *design problem*. A design problem that would require changing peering authority is a **gate fail — stop and report**.

---

## Phase 6 — gate report

Write `results/GATE_REPORT.md`:

- For each criterion in `PILOT_CRITERIA.md`: pass/fail, the evidence (result files, run counts), and any caveat.
- The mechanism used and how it differs from the proposal's §4.2 description.
- Surprises, and anything that affects the proposal's hypotheses (H1 overhead, H2 coverage, H3 capacity) or open questions in §10.
- Your recommendation: **pass**, **pass with revised hypotheses**, or **fail**, per the decision rule — stated plainly. Vlad makes the call.

---

## Out of scope for you

- Step 6 (capacity analysis from traces) and step 7 (prior-art reading) of the proposal. Vlad runs these separately; do not start them unless asked.
- Pool deletion, size reduction, and stray-PG vaulting; overwrites; erasure-coded pools; the reclaimer daemon; the policy file; performance measurement beyond noting anything obviously slow.
