# ReplicaVault: Bounded Recovery After Authorized Destruction in Replicated Object Storage

**Research proposal — paper three · Revision 3, October 2026**
Vladislav Esaulov, advised by Lipeng Wan, Georgia State University

Revision 3 replaces the September proposal (revision 2). It folds in the feasibility pilot and the follow-up correctness study (§6), and the design revisions they forced: Revisions 1, 1a and 1b in the project repository. Appendix C lists what changed.

---

## 1. Summary

Replication protects data against hardware. It does not protect data against the storage system itself. When an operation is *authorized* — a `rados rm`, a pool deletion, a pool size reduction — Ceph applies it faithfully to every replica. The redundancy that took three times the capacity to buy is destroyed in the same instant as the data it protected.

These operations are exactly what an attacker performs after stealing administrative credentials, and exactly what a mistaken operator or a misbehaving automation agent issues by accident. Ceph's existing safeguards sit at the wrong layer or answer to the wrong authority. RGW Object Lock is enforced in the S3 gateway, so anything that talks to RADOS directly bypasses it. Pool flags, the pool-deletion guard, and snapshots can all be reversed by the same administrator they are meant to stop.

ReplicaVault separates **logical deletion** from **physical irreversibility**:

- A destructive operation completes normally. Every replica agrees the object is gone, clients see `ENOENT`, the PG log records the deletion, and peering treats it as authoritative.
- Before an OSD removes the object, it copies the pre-delete data into a local vault outside every placement group. Two OSDs do this for each delete: the primary and one retaining replica.
- Each copy is held for a bounded retention window. Only a protected reclamation path, outside the reach of Ceph administrative credentials, can release it, and only after the window expires.
- Restore writes the data back as a new object version, never rolling history backward.

Detection of an attack no longer has to succeed before the damage is done — only before the retention window closes.

The idea is simple to state, but making it correct inside a replicated store is not. A three-week pilot and a one-week follow-up study (§6) built a working prototype in Ceph v19.2.3. They also found three ways a straightforward design silently loses data that clients were told was retained: a pool reduced to one replica, a manipulated primary, and a retaining OSD that crashes mid-delete and returns after its data has been moved elsewhere. Each was fixed and re-tested. These findings are the core of the paper's correctness argument.

The work rests on three hypotheses. The feasibility gate that preceded them has passed.

- **H1 (overhead).** Retention costs a bounded local copy of each deleted object on each retaining OSD. At the 4 MiB object size that RBD, RGW and CephFS use by default, that cost is modest. Without a mitigation it grows with object size; with the mitigation planned in §4.8, it stays off the path of unrelated operations.
- **H2 (coverage).** For destructive operations issued through Ceph's command surface, ReplicaVault recovers all destroyed data whenever detection occurs within the retention window. This holds under any single OSD failure during the attack.
- **H3 (affordability).** Under realistic delete rates, retention holds a small fraction of cluster capacity for windows of hours to days. Asymmetric windows bring the cost of two copies close to that of one. The capacity-exhaustion attack this invites is contained by a declared fail-closed policy.

---

## 2. Motivation

### 2.1 Replication multiplies data, not history

Three-way replication turns one object into three copies and one delete into three deletes. Erasure coding does the same with shards. Neither provides a way to undo an operation the system accepted as legitimate. That job is left to snapshots, versioning, and external backups. These cost capacity, need management, and in Ceph's case are controlled by the same administrative authority an attacker would hold.

### 2.2 Ceph's safeguards answer to the attacker

| Safeguard | Why it does not stop an administrator |
|---|---|
| RGW Object Lock and versioning | Enforced in the gateway; direct RADOS operations bypass it |
| Pool `nodelete` / `nosizechange` flags | The administrator can unset them |
| `mon_allow_pool_delete = false` | The administrator can set it to true |
| Pool and self-managed snapshots | The administrator can remove them (`rmsnap`), after which the snap trimmer reclaims the data |
| RBD trash | A deferred delete for images, purgeable by the same administrator |
| External backups | Effective, but outside the cluster, with their own cost and recovery-point gap |

Ceph does not lack protection mechanisms. The gap is that every one of them can be switched off by whoever holds the admin keyring.

### 2.3 Who holds the admin keyring

Three kinds of actor issue authorized destructive operations:

- **Attackers with stolen credentials.** Ransomware operators increasingly destroy backups and storage before encrypting endpoints, so that recovery is impossible without paying. Against a storage cluster, the fastest destruction is deletion: of pools, images and buckets.
- **Human operators making mistakes.** Deleting the wrong pool, reducing the wrong pool's size, or running a cleanup script against the wrong cluster.
- **Automation and AI operations agents.** Agents that operate infrastructure with administrative credentials — including LLM-driven Ceph operations agents such as CephMaestro — can issue destructive commands because of a model error, a misread instruction, or prompt injection. *(Cite a specific documented incident after verification.)*

All three have Ceph credentials. None needs root on the storage hosts. ReplicaVault is designed for exactly that gap.

### 2.4 Deletion first, overwrites second

ReplicaVault targets **destruction by deletion**: object deletes and the PG-level operations that remove data in bulk. Ransomware that encrypts RBD or CephFS data *in place* overwrites rather than deletes. Version 1 does not cover it, and the paper says so. Overwrite retention is the stretch goal (§3.3). The motivation is framed around deletion-driven destruction: backup and pool wiping, operator error, and agents.

---

## 3. Threat model and scope

### 3.1 Attacker

| Capability | In scope? |
|---|---|
| Any librados operation, including `rm`, `purge`, `truncate`, `writefull` | Yes |
| Any monitor or manager command: pool delete, size reduction, flag changes, config changes, `ceph tell` to OSDs | Yes |
| Shaping placement: marking OSDs out, destroyed or purged; `pg-upmap-items`, `pg-temp`, `primary-temp`, primary affinity | Yes |
| Orchestrator access (cephadm SSH keys, Rook/Kubernetes control) | **No** — see below |
| Root on OSD hosts, raw device access, physical destruction | **No** |
| Modifying the OSD binary | **No** |

The orchestrator exclusion is essential, and the paper states it plainly. In cephadm deployments, the manager holds SSH access to every host. It can deploy new container images (`ceph orch upgrade`) or wipe devices (`ceph orch device zap`). In Rook, Kubernetes control confers the same power. An attacker with orchestrator access effectively has root on the hosts, and no software on those hosts can then guarantee anything.

The realistic attacker ReplicaVault targets holds Ceph capabilities — a stolen admin keyring, a compromised automation account, an agent's credentials — but not the orchestrator. Deployments must keep the two separated, and the paper reports what that separation requires.

### 3.2 Defender

The defender retains root on the storage hosts through an out-of-band channel. The trusted computing base is:

- the OSD binary;
- the host operating system;
- a local retention policy file, owned by root and not writable by the `ceph` user.

Recovery is performed from the hosts, after the defender has revoked the compromised credentials.

### 3.3 Operations covered

- **Version 1 (core).** Object deletion (`rm`, `purge`), including deletes applied through recovery. The PG-level paths that destroy data without per-object deletes: pool deletion, pool size reduction, and removal of stray PG copies after remapping. Object deletion is built and tested (§6); the PG-level paths are next (§4.5).
- **Stretch.** Destructive writes (`truncate`, `zero`, `writefull`, partial overwrites), handled by copying an object's pre-write state once per object per retention epoch. This gives the same semantics as a snapshot taken at the start of the window.
- **Out of scope.** Erasure-coded pools, where retaining a single shard is useless. Gradual corruption that stays below any detection threshold for longer than the retention window.

---

## 4. Design

### 4.1 The protected-delete contract

For a destructive operation on object *O* at version *v*:

1. *O* becomes logically deleted immediately on every replica; clients see normal semantics.
2. The PG log records the deletion normally, and peering and recovery treat it as authoritative.
3. Two OSDs — the PG's primary and one retaining replica — each keep a copy of *O@v*'s pre-delete bytes in a local vault, until their respective retention windows expire (§4.4).
4. The vault is never part of the placement group. It is invisible to peering, backfill, recovery, scrub, stray-PG removal, and PG split and merge, and can never become authoritative.
5. Design goal: an acknowledged delete survives any single OSD failure. When the client is acknowledged, the pre-delete bytes are durable on at least one OSD that keeps them — as a vault copy, or as the not-yet-removed object that its OSD vaults when it applies the delete. The prototype meets this in every single-OSD failure tested (§6.3); the general argument and a model check are planned (§5.6).
6. Restore creates *O@v+k* as a new write; it never rolls the PG log backward.

Item 5 is the guarantee that took the most work. The tested failures are the retainer and the primary, each either returning or not. The argument rests on the transaction ordering in §4.2, and the planned model check covers the delete, vault and acknowledgement protocol.

Two invariants hold at all times, and the evaluation checks them after every scenario:

- **No resurrection.** A vault copy never causes a deleted object to reappear through normal Ceph operation.
- **No durability loss.** Retention never reduces the redundancy of live data. Vault capacity and live-data capacity are accounted separately.

### 4.2 Mechanism (object deletes, as built)

**Why copying.** The original design moved deleted data into the vault without copying, by reusing BlueStore's snapshot clone machinery. The pilot showed this is not available:

- BlueStore's move-rename asserts that source and destination are in the same collection.
- Clones carry a single collection.
- Shared-blob tracking is per collection.

Keeping the vault inside the PG collection fails too, because boot-time temp cleanup, scrub cleanup and stray-PG removal all delete such entries. Extending BlueStore was out of the schedule's reach. ReplicaVault therefore copies.

**Where the vault lives.** Each OSD keeps its vault in a reserved namespace of its own **meta collection**. That collection holds OSD maps and the superblock, and none of peering, scrub, backfill, recovery, stray-PG removal, or PG split and merge ever lists it. Entry names encode pool, PG, object name, namespace, locator, version and deletion time, so repeated deletes of one name produce distinct entries. Names avoid the `osdmap.` prefix, which an OSD admin command trims.

**Where the change lives.** Three hook points, adding a small module to the OSD:

- the primary's transaction submission in `ReplicatedBackend`;
- the replica's apply path (`do_repop`);
- the recovery-delete path (`remove_missing_object`).

No replication message, peering, PG log, scrub or backfill code is changed.

**Ordering.** A single combined transaction was tried first and failed BlueStore fsck, because of per-pool space accounting. The vault copy is therefore its own transaction, queued immediately before the PG transaction on the same sequencer. BlueStore commits a sequencer's transactions in order, so the remove is never durable without the copy. The client acknowledgement waits for the primary's commit. These two facts are what item 5 rests on.

**Choosing the retainers.** The **primary** vaults every delete. The **retaining replica** is the next OSD in the acting set ordered primary-first (or the primary itself, if the acting set has one member). Both are recomputed for each delete, so retention follows the acting set through failures and remapping.

Why two, and why the primary: a single retainer fails in three cases the study found.

1. **Size 1.** With one replica there is no second OSD to retain.
2. **Primary-temp.** An attacker can use `primary-temp` to make the designated replica the primary, which never vaulted.
3. **Retainer crash.** A retainer that crashes mid-delete, is marked out, and returns after its PGs moved elsewhere is purged as a stray. The only surviving pre-delete bytes go with it.

Having the primary vault closes all three without any protocol change.

### 4.3 Reclamation authority

The OSD process holds the data, so protection must remove every path by which Ceph's command surface can cause early release. ReplicaVault does three things:

1. **Policy is local, not central.** Retention settings are read only from the root-owned policy file. They are ignored in the monitors' configuration database, and cannot be changed by `ceph config set` or `ceph tell ... injectargs`.
2. **No release command exists.** The OSD exposes no admin-socket or `tell` command that shortens retention or releases vault data. The only operation reachable from the Ceph side is *freeze*, which extends retention and is therefore safe to expose.
3. **A separate reclaimer owns expiry.** A small daemon running under its own Unix account keeps an append-only retention ledger. It authorizes the OSD to release a vault entry only after its expiry time, and the OSD refuses to release without that authorization.

Part of the contribution is methodological: an **inventory of every destructive path** in Ceph reachable from monitor, manager and librados commands. It covers deletes, pool and PG removal, size changes, snapshot trimming and stray cleanup. Each path is either routed through the vault or shown to require orchestrator or host access. The paper adds a systematic review of debug and injection options reachable through `ceph config` and `ceph tell`, since those are in the attacker's reach. The inventory is released with the paper.

### 4.4 Asymmetric retention

Two copies per delete double the capacity of a naive design. Asymmetric windows recover most of that. The two copies do different jobs, so they need not live equally long:

- **The primary's copy covers failures around the delete itself:** the window between acknowledgement and the retainer's copy becoming durable, and the failure handling that follows. That needs hours, not days.
- **The retainer's copy covers late detection.** It carries the long window — for example 24 hours to several days, set by policy.

The primary knows when a short window is safe. A replica sends its commit only after its transactions are durable, and its vault copy is ordered ahead of its remove. So receiving the retainer's commit for a delete proves the retainer's copy is durable.

- **The primary's copy starts with the short window.**
- **It is promoted to the long window whenever the primary does not receive the retainer's commit for that delete** — because of a failure, a remap, or an interval change.

This uses only messages Ceph already sends. Steady-state retained capacity is then roughly *delete rate × (long window + short window)*: close to one copy's worth when the short window is much shorter than the long one.

*To verify in code before building:* that the primary's per-op commit tracking survives interval changes well enough to decide promotion.

### 4.5 PG-level destruction

Pool deletion, size reduction and stray removal destroy whole PGs, and are the realistic large-scale attack. Copying every object of a deleted pool would be prohibitively slow, and the pilot confirmed that BlueStore has no collection-level move into the vault.

The planned approach retains **the PG collection itself**. When a PG is removed for one of these reasons, the OSD records it as *retired* in its meta collection instead of deleting its objects. The collection stays on disk untouched, its bytes count toward vault capacity, and the reclaimer removes it after the window. Retention for PG-level destruction is then zero-copy again. The cost moves to bookkeeping: boot-time collection enumeration, stray handling and fullness accounting must all recognize retired collections. That is exactly the kind of interaction the scenario suite is built to test.

*Open question:* how restore addresses objects inside a retired collection, whose pool may no longer exist.

### 4.6 Capacity and the exhaustion attack

Retention costs capacity equal to the data deleted within the window on each retaining OSD. Two effects add to this:

- A delete missed by a down retainer and later applied through recovery can be vaulted a third time. The study bounded this at three copies per delete, including under an attacker who toggles a retainer up and down.
- An attacker who knows about retention can try to fill the vault — writing and deleting repeatedly — to force early reclamation or trigger OSD full conditions.

ReplicaVault declares a policy instead of leaving this undefined. Each OSD has a vault budget. When it is reached, the default is **fail-closed**: further destructive operations on that OSD's PGs are rejected until retention expires or the defender intervenes, trading availability for recoverability. An alternative *expire-oldest* policy is available and evaluated. Either way, vault usage counts toward OSD fullness, so the vault can never silently push live data into a full condition.

Vault bytes are charged to the meta pool in BlueStore's statistics, not to the originating pool. Capacity measurement therefore uses vault-specific counters.

### 4.7 Detection, freeze and restore

Detection is deliberately simple, because the contribution is that detection can be late. The reclaimer watches local signals — delete rate, destructive-operation bursts, PG retirements — and freezes expiry automatically when a threshold is crossed. The defender can also freeze out of band. The evaluation reports how late detection can be and still recover everything.

A host-side tool lists vault entries by pool, object and time. It restores selected objects by writing them back through librados as new versions, after the defender has rotated credentials. Restored data is verified against checksums recorded at vault time. A manual version of this path already works in the prototype (§6.2).

### 4.8 Keeping the copy off the critical path

As built, a retaining OSD reads the whole object synchronously on its operation path before applying the delete. At 4 MiB this costs little. At 64–128 MiB it stalls unrelated operations served by the same OSD shard (§6.4).

The acknowledgement must still wait for the primary's copy to be durable — that is the guarantee. But the read and write need not block the shard. The candidates are:

1. **An off-shard copy.** The delete is parked, the copy runs in a separate thread pool, and the PG transaction is queued when the copy completes.
2. **A chunked copy**, interleaved with other work.
3. **A size threshold** above which one of the above applies.

The choice is made by measurement on the multi-host testbed before the full overhead evaluation. RADOS caps objects at 128 MiB by default, which bounds the worst case.

---

## 5. Evaluation

### 5.1 Testbed

- **Development and correctness.** One CloudLab node running `vstart.sh` clusters from source builds: a Debug cluster (5 OSDs) for the scenario suite, and a release build for cost probes.
- **Full evaluation.** 5–6 CloudLab c220g2 nodes: 4 OSD hosts (failure domain = host, BlueStore DB and WAL on SSD, data on HDD — a common production layout), 1 client node, and optionally a fifth OSD host for multi-failure scenarios. Fallback: d430 nodes, reported as an HDD-only cluster with emphasis on relative overhead.

### 5.2 Workloads

- **Microbenchmarks.** Protected versus vanilla deletes, object sizes from 4 KiB to 128 MiB, with and without the §4.8 mitigation.
- **Normal workloads.** Mixed put, get, overwrite and delete through librados and RGW, and a replay of public object-storage traces with realistic delete ratios. The SNIA IBM Cloud Object Storage traces are a candidate; check that they include deletes.
- **Attack workloads.**
  - Burst deletion, slow deletion below naive rate thresholds, and deletes spread across many PGs.
  - Pool deletion and pool size reduction.
  - Placement manipulation (`primary-temp`, upmap, OSD out) during deletion.
  - The capacity-exhaustion attack.
  - An end-to-end destruction scenario: wiping backup pools and images with stolen credentials.
- **Failure workloads.**
  - OSD and host crashes, primary changes, remapping and backfill during and after attacks.
  - Retainer and primary failures mid-delete.
  - Deep-scrub throughout.

### 5.3 Baselines

- **B0 — vanilla Ceph.**
- **B1 — periodic pool snapshots** every *N* minutes. Uses the same clone machinery, but the administrator can remove the snapshots. Isolates the value of the separated reclamation authority.
- **B2 — RGW versioning plus Object Lock.** Protects the S3 path; demonstrates the RADOS-level gap.
- **B4 — external backup** to a separate cluster. Compared on recovery point, capacity and recovery time.

The former B3 (copy-to-vault) is now the design and has been dropped as a baseline. Within ReplicaVault, the evaluation compares one copy, two symmetric copies, and two asymmetric copies (§4.4).

### 5.4 Metrics

- **Recovery coverage:** destroyed bytes recoverable ÷ destroyed bytes.
- **Detection tolerance:** the longest detection delay for which coverage stays at 100%.
- **Delete latency** (p50, p99) against object size; **interference** with concurrent non-delete operations; **foreground throughput** loss on normal workloads.
- **Retained capacity** against window length, retention policy and workload; vault copies per delete; behavior under the exhaustion attack.
- **Recovery time** for a restore of *N* objects or bytes.
- **Invariant checks:** scenarios and runs executed, resurrections observed (must be zero), scrub inconsistencies (must be zero), and acknowledged deletes without a surviving copy (must be zero).

Vault copies are counted from the store, not from logs. The study found that log lines both over- and under-count durable copies around crashes (§6.3).

### 5.5 Principal figures

- **Figure A — cost of retention.** Delete latency and interference against object size, 4 KiB to 128 MiB: B0 against ReplicaVault, with and without the off-path copy. The 4 MiB default object size is marked as the common operating point.
- **Figure B — detection tolerance.** Recovery coverage against detection delay for each retention policy, with B1 shown collapsing when the attacker removes the snapshots.
- **Figure C — affordability.** Retained capacity against window length on trace replays, for symmetric and asymmetric retention.
- **Figure D — attack timeline.** An attack with OSD and host failures mid-attack: live data, vault contents and recovery over time.
- **Figure E — what goes wrong without the design's safeguards.** Acknowledged deletes lost by single-retainer designs under the failure and placement scenarios of §6.3, against zero for ReplicaVault.

### 5.6 Correctness evaluation

The scenario suite from the pilot and the follow-up study is the core of the correctness evaluation. It currently has 21 scenarios:

- **Failover, backfill, scrub and recreation:** primary failures before, during and after deletes; backfill; deep-scrub; object recreation.
- **OSD lifecycle and snapshots:** OSD restart; PG split and merge; snapshots; manual restore; missed deletes.
- **Attacks:** five placement attacks.
- **Crashes:** crash consistency and read-after-queue.
- **Failure and return:** retainer and primary failure with return as a stray.

Every scenario runs on vanilla Ceph first to validate the harness. The suite is extended with each new path (PG-level destruction, the reclaimer, the off-path copy) and rerun on every change.

To strengthen item 5 from *tested* to *shown*, a TLA+ model of the delete, vault, acknowledgement and failover protocol will be checked for the single-failure property, if the schedule allows (§9).

---

## 6. Feasibility evidence

Everything in this section was run on Ceph v19.2.3, from patches published in the project repository that rebuild the exact prototype from a clean checkout. Pass/fail criteria for the pilot and for the follow-up study were committed to the repository, dated, before any prototype code was written, and were never edited. Every scenario was run on unmodified Ceph first.

### 6.1 The feasibility question

The pilot asked whether a replica can hold hidden pre-deletion data without disturbing Ceph's correctness machinery. It had a pre-registered go/no-go gate and an approved fallback project (EXODUS). The gate has passed, and the fallback is not needed.

### 6.2 Pilot (September 25–26, 2026)

- **Primitive check (from source).** Zero-copy retention outside the PG is not available in BlueStore (§4.2). Under the pre-registered decision rule, this triggered the "pass with revised hypotheses" branch: H1 was restated as a bounded copy cost before any code was built.
- **Prototype.** One retaining replica copies the object into its meta-collection vault before removing it.
- **Scenario suite.** 12 scenarios, 75 runs on the prototype after the same 75 passed on vanilla Ceph:
  - primary killed before, during and after deletes;
  - backfill after `ceph osd out`;
  - deep-scrub of every PG, with a negative control showing scrub does flag a corrupted replica;
  - object recreation and repeated delete-and-recreate;
  - OSD restart with vault data on disk;
  - PG split and merge;
  - deletes of objects with snapshot clones;
  - manual restore;
  - a delete missed by a down retainer.
- **Result.**
  - Every deleted object stayed deleted.
  - Deep-scrub found no inconsistency.
  - 646 of 646 delete-to-vault checks found an intact, checksum-verified copy.
  - 12 of 12 restores reproduced the original bytes as a new version.

### 6.3 Follow-up correctness study (September 28 – October 2, 2026)

The pilot showed the mechanism works under normal failures. The follow-up asked whether it holds when placement is manipulated, and when OSDs crash at the worst moment.

| Finding | Before the fix | After the fix |
|---|---|---|
| **Pool size 1** leaves no second OSD to retain | 24 of 24 acknowledged deletes unvaulted | 0 unvaulted; the primary retains |
| **`primary-temp`** makes the designated replica the primary, which never vaulted | 25 of 25 unvaulted on affected runs | 0 unvaulted |
| **Retainer crashes mid-delete, is marked out, returns as a stray and is purged** | **164 of 320 acknowledged deletes lost** (18 of 20 runs) | **0 of 320 lost** (20 of 20 runs), once the primary also vaults |

Other results from the study:

- **Primary failure mid-delete:** 0 of 320 lost in each of two variants — the primary returning as a stray, and never returning (20 runs each).
- **Crash consistency:** 100 runs killing the retainer under a stream of deletes. Every one of 1,600 acknowledged deletes had an intact copy after recovery, and BlueStore fsck was clean every time.
- **Read-after-queue:** 200 cases with up to four writes in flight before a delete. The vault always held the last queued write.
- **Full regression on the final prototype:** 17 scenarios, 118 of 118 runs, 1,000 of 1,000 deletes with an intact copy.
- **Placement attacks that turned out harmless:** `ceph osd out` and `pg-upmap-items` open no gap. Ceph keeps backfill targets out of the acting set, so an OSD holding the object always retains it.

Two lessons shape the evaluation:

1. **"Retained" must be checked after recovery, against the disk.** Log lines alone both missed durable copies and recorded copies a crash lost.
2. **Every failure that lost data was ordinary Ceph behavior**, such as the default 10-minute automatic mark-out followed by stray purge. None of them was exotic. This is the evidence that retention in a replicated store is subtle, and it is what distinguishes the problem from single-device retention.

### 6.4 Early cost signal

The probe used one host, a release build, and 3 file-backed OSDs sharing one disk. Only the ratios to vanilla are meaningful. Because all OSDs share one device, the primary's and the retainer's copies compete for the same disk, which overstates the cost relative to a multi-host cluster.

| Deleted object size | Delete latency p50, ÷ vanilla | p99 of concurrent 4 KiB operations, ÷ vanilla |
|---|---|---|
| 1 MiB | 1.3× | 1.1× |
| 4 MiB | 2.3× | 1.2× |
| 16 MiB | 5.0× | 1.6× |
| 64 MiB | 11.5× | 7.5× |
| 128 MiB | 22× | 11× |

At the 4 MiB default object size, the cost is modest. Above 16 MiB, the synchronous copy visibly stalls other operations, which motivates §4.8.

---

## 7. Contributions

The idea: **in a replicated store, replicas can agree on the current state while retaining old state beneath the administrator's authority — and doing so correctly requires deciding which replicas retain, and when a delete may be acknowledged.**

**Primary contributions.**

1. **Correct delayed reclamation in a replicated object store.**
   - Deletion stays authoritative under peering, backfill, recovery and scrub, while designated OSDs retain the old data.
   - The correctness conditions are stated explicitly: which OSDs retain, how retention is ordered against removal, and when acknowledgement is safe. They tolerate any single OSD failure.
   - These conditions are demonstrated by systematic failure and placement injection, including three failure modes of naive designs found and fixed along the way.
2. **Separation of reclamation authority from storage administration**, with an inventory of every destructive path reachable from Ceph's command surface and how each is closed.
3. **Asymmetric retention across replicas.** A short-lived copy covers failures around the delete; a long-lived copy covers late detection. The evaluation characterizes recoverability against capacity under realistic delete rates and under a capacity-exhaustion attack.

**Enabling, and claimed as such.** The copying vault in the OSD's meta collection; zero-copy retention of whole PGs for PG-level destruction; the off-path copy; the restore tool.

**Not claimed.** Ransomware detection. Protection against in-place overwrites, unless the stretch goal is completed. Retaining old data beneath a compromised privilege level is established at the device and single-server level; the contribution is doing it correctly inside a distributed replicated store.

---

## 8. Related work and delta

**Self-securing and time-travel storage.** S4 (Strunk et al., OSDI 2000) kept every version for a detection window on a storage server that treated client operating systems as untrusted. FlashGuard (CCS 2017), Project Almanac's TimeSSD (EuroSys 2019) and RSSD (ASPLOS 2022) retain overwritten or invalidated data inside SSD firmware by delaying garbage collection, below a compromised host. Together they establish that logical destruction and physical reclamation can be separated beneath the attacker's privilege level.

*Delta:* all of them operate on a single device or server. In a replicated store, retention must coexist with the replication protocol, whose PG log, peering, backfill and scrub all assume replicas converge. It must also choose its retainers and its acknowledgement point so that a single failure does not lose what a client was told is retained. §6.3 shows that the obvious choices get this wrong. Replicas also allow retention that differs by replica, which a single device cannot offer.

**Versioning and snapshot file systems.** CVFS (FAST 2003), ZFS and Btrfs snapshots, and NetApp snapshots retain history cheaply. *Delta:* their retention is controlled by the administrator of the same system.

**Cloud immutability features.** S3 Object Lock in compliance mode, Azure immutable blob storage, and Google Cloud Storage soft delete protect against account-level deletion within a provider whose own staff and control plane remain trusted. *Delta:* ReplicaVault provides a comparable guarantee inside a self-operated cluster, where the storage administrator is the threat.

**Ceph's own mechanisms.** RADOS snapshots, RBD trash, pool protection flags and RGW Object Lock (§2.2). *Delta:* every one is reversible by the administrator; ReplicaVault moves the authority.

**Ransomware detection.** A large literature detects ransomware by entropy, access patterns or machine learning. *Delta:* ReplicaVault is detection-agnostic. It converts a detection deadline of "before the damage" into "before the window closes."

*Citation status.* To verify before relying on details: all of the above, particularly the Ceph documentation's statements about Object Lock and RADOS, whether the IBM COS traces include deletes, and a documented AI-agent data-deletion incident for §2.3.

---

## 9. Venue and schedule

**Primary target:** FAST '28 spring cycle (expected mid-March 2027; confirm when the call appears). **Alternatives:** EuroSys 2028, or USENIX Security if the security framing leads. If timing allows, a short workshop paper on the correctness findings of §6.3 (for example at HotStorage) would establish the problem early.

| Weeks | Dates | Work |
|---|---|---|
| — | Sep 25 – Oct 2, 2026 | **Done:** pilot, follow-up correctness study, feasibility gate passed (§6) |
| 0–2 | Oct 5 – Oct 16 | Proposal defense. Prior-art close-out. Choose the off-path copy design. Capacity analysis of traces (retained bytes per window) |
| 2–6 | Oct 19 – Nov 15 | PG-level destruction (retired collections): pool deletion, size reduction, stray removal. Off-path copy. Restore tool. Suite rerun on every change |
| 6–10 | Nov 16 – Dec 13 | Reclaimer, local policy, asymmetric windows with promotion, command-surface lockdown and inventory, freeze; vault accounting and fail-closed policy |
| 10–14 | Dec 14 – Jan 10, 2027 | Deploy on the c220g2 cluster; baselines; trace replay; TLA+ model (holiday slack) |
| 14–19 | Jan 11 – Feb 14 | Attacks, failure injection, overhead, retention policies, command-surface review |
| 19–23 | Feb 15 – Mar 14 | Writing and submission |

**Cut in this order if the schedule slips:**

1. the overwrite stretch goal;
2. the TLA+ model (keep the written argument and the scenario evidence);
3. the external-backup baseline;
4. the end-to-end destruction scenario (keep scripted attacks);
5. size reduction and stray removal at full scale (keep pool deletion).

---

## 10. Risks and open questions

**Risks.**

| Risk | Status or mitigation |
|---|---|
| BlueStore has no zero-copy move into the vault | **Confirmed by the pilot.** Copying is the design for object deletes; whole-PG retention keeps PG-level destruction zero-copy (§4.5) |
| Scrub, backfill, stray cleanup, OSD boot, or PG split and merge mishandle vault data | **Retired** for object deletes: no failures in all pilot and follow-up runs. Retested for each new path |
| A single-OSD failure loses an acknowledged delete | **Found and fixed** (§6.3). Tested for retainer and primary failure; general argument in the paper; TLA+ model planned |
| Large-object deletes stall unrelated operations | **Measured** (§6.4). Off-path copy (§4.8) before the overhead evaluation |
| Two copies per delete double retained capacity | Asymmetric windows with promotion (§4.4); evaluated in Figure C |
| Single-host cost numbers mislead | Treated as indicative only; all reported numbers come from the multi-host testbed |
| Reviewers see "delayed delete" as known | Cite S4, TimeSSD and RSSD directly. The delta is replication-protocol correctness (with §6.3 as evidence), asymmetric retention and authority separation, not delay itself |
| The threat model is judged unrealistic because cephadm confers host access | State the orchestrator exclusion explicitly and report what separating it requires |
| In-place overwrites (ransomware against RBD and CephFS) are not covered | Framing is deletion-driven destruction (§2.4); overwrites are the stretch goal, reported either way |
| Debug or injection options reachable through `ceph config` or `ceph tell` undermine the lockdown | Systematic review as part of the inventory (§4.3) |
| Capacity-exhaustion attack | Declared fail-closed policy, evaluated under attack |
| The schedule is tight for OSD-level work | Correctness foundation done early; cut list; December 2027 graduation as a fallback |

**Open questions.**

1. Do retired PG collections interact safely with boot-time enumeration, pool-ID handling and fullness accounting, and how does restore address objects in a retired collection whose pool is gone?
2. Does the primary's per-op commit tracking survive interval changes well enough to decide when to promote its copy to the long window?
3. Which off-path copy design keeps acknowledgement latency acceptable while removing interference?
4. What is the right fail-closed behavior for pool deletion, a single command that affects many PGs?

---

## Appendix A — Relation to the original plan

This proposal follows the plan Lipeng Wan shared in September 2026, with these changes:

- The threat model excludes orchestrator access explicitly.
- PG-level destruction is in scope.
- Overwrites are a stretch goal.
- A capacity-exhaustion policy is specified.
- Erasure-coded pools are out of scope.
- The schedule is compressed to about twenty-four weeks, opened by a three-week feasibility gate.

The feasibility work then changed the design in four ways:

1. Object-delete retention copies rather than moving data without copying.
2. Two OSDs retain each delete instead of one.
3. Asymmetric retention takes the form of a short window on the primary's copy and a long window on the retainer's.
4. PG-level destruction keeps zero-copy by retaining whole collections.

## Appendix B — Relation to prior work in this dissertation

JANUS made cross-facility data movement resilient to loss. CephMaestro showed that an LLM agent can operate a Ceph cluster, which also means an agent can destroy one. ReplicaVault bounds the damage any holder of Ceph credentials — attacker, operator or agent — can do irreversibly.

It also follows three pre-registered pilots on DiskANN ideas (DuraVec, CorrGuard, CephVec), each stopped within days on clear evidence. Their common finding, that Vamana graphs have no structurally special regions to exploit, is why this paper moved from index structure to storage-system mechanism.

## Appendix C — Changes in revision 3

Revision 3 consolidates three design revisions recorded in the project repository, each committed before the work it governed or immediately after the finding that forced it.

- **Revision 1:** copying vault, H1 restated as a bounded copy cost, B3 dropped.
- **Revision 1a:** copy and remove ordered as separate transactions, vault accounting corrected, single-retainer coverage gap recorded.
- **Revision 1b:** coverage gaps corrected to size 1 and `primary-temp`, the primary also vaults, contract item 5 restated against the tested failure cases.

Relative to revision 2, this revision:

- **Summary and motivation (§§1–2):** drops the claim that retention costs no new copies, and frames the motivation around deletion-driven destruction (§2.4).
- **Design (§4):** rewrites §§4.1–4.2 to match the prototype. Adds asymmetric retention with promotion (§4.4), whole-PG retention for PG-level destruction (§4.5), and the off-path copy (§4.8).
- **Feasibility evidence (§6):** replaces the pilot plan with the pilot and follow-up results.
- **Evaluation, contributions and schedule (§§5, 7, 9):** updates the evaluation, figures and contributions, adds the correctness evaluation (§5.6), and moves the schedule forward by three weeks, since the gate passed early.
