# ReplicaVault: Bounded Recovery After Authorized Destruction in Replicated Object Storage

**Research proposal — paper three · Revision 4, October 2026**
Vladislav Esaulov, advised by Lipeng Wan, Georgia State University

Revision 4 replaces revision 3. Since revision 3, a zero-copy pilot (October 3–6) replaced the copying vault with a metadata-only move inside BlueStore. This revision makes that the mechanism (§4.2) and adds its evidence (§6.4–6.5). Appendix C lists every change.

---

## 1. Summary

Replication protects data against hardware. It does not protect data against the storage system itself. When an operation is *authorized* — a `rados rm`, a pool deletion, a pool size reduction — Ceph applies it faithfully to every replica. The redundancy that took three times the capacity to buy is destroyed in the same instant as the data it protected.

These operations are exactly what an attacker performs after stealing administrative credentials, and what a mistaken operator or a misbehaving automation agent issues by accident. Ceph's existing safeguards sit at the wrong layer or answer to the wrong authority. RGW Object Lock is enforced in the S3 gateway, so anything that talks to RADOS directly bypasses it. Pool flags, the pool-deletion guard, and snapshots can all be reversed by the same administrator they are meant to stop.

ReplicaVault separates **logical deletion** from **physical reclamation**:

- A destructive operation completes normally. Every replica agrees the object is gone, clients see `ENOENT`, the PG log records the deletion, and peering treats it as authoritative.
- On two OSDs — the primary and one retaining replica — the deleted object's data blocks are not freed. They are **pinned**: the object's storage-engine metadata moves, in the same transaction as the delete, into a vault outside every placement group. The blocks stay where they are.
- An extent is reusable only when it has no live references and no retention pins. Pins are held for a bounded retention window. Only a protected reclamation path, outside the reach of Ceph administrative credentials, releases them, and only after the window expires.
- Restore writes the data back as a new object version, never rolling history backward.

Detection of an attack no longer has to succeed before the damage is done — only before the retention window closes.

The idea is simple to state, but making it correct inside a replicated store is not. Three studies on Ceph v19.2.3 built and tested it.

- **Correctness.** A feasibility pilot and a correctness study found three ways a straightforward design silently loses data that clients were told was retained. Each was fixed and re-tested.
- **Zero-copy.** A third study made retention zero-copy. For objects without shared blocks, a delete with retention writes the same bytes to disk as a plain delete, and takes the same time, from 4 KiB to 128 MiB. The earlier copying design was 33× slower at 128 MiB.

The work rests on three hypotheses:

- **H1 (overhead).** For objects without shared blocks, retention costs metadata only: device writes and delete latency match vanilla Ceph at every object size. The remaining costs are proportional to an object's omap, and to the share of deletes that must fall back to copying (objects whose blocks are shared with snapshot clones).
- **H2 (coverage).** For destructive operations issued through Ceph's command surface, ReplicaVault recovers all destroyed data whenever detection occurs within the retention window. This holds under any single OSD failure during the attack.
- **H3 (affordability).** Under realistic delete rates, retention holds a small fraction of cluster capacity for windows of hours to days. Asymmetric windows bring the cost of two retained copies close to that of one. The capacity-exhaustion attack this invites is contained by a declared fail-closed policy.

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

ReplicaVault targets **destruction by deletion**: object deletes, and the PG-level operations that remove data in bulk. Ransomware that encrypts RBD or CephFS data *in place* overwrites rather than deletes. Version 1 does not cover it, and the paper says so; overwrite retention is the stretch goal (§3.3). The motivation is framed around deletion-driven destruction: backup and pool wiping, operator error, and agents.

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

The orchestrator exclusion is essential, and the paper states it plainly. In cephadm deployments, the manager holds SSH access to every host. It can deploy new container images (`ceph orch upgrade`) or wipe devices (`ceph orch device zap`); in Rook, Kubernetes control confers the same power. An attacker with orchestrator access effectively has root on the hosts, and no software on those hosts can then guarantee anything.

The realistic attacker ReplicaVault targets holds Ceph capabilities — a stolen admin keyring, a compromised automation account, an agent's credentials — but not the orchestrator. Deployments must keep the two separated, and the paper reports what that separation requires.

### 3.2 Defender

The defender retains root on the storage hosts through an out-of-band channel. The trusted computing base is:

- the OSD binary;
- the host operating system;
- a local retention policy file, owned by root and not writable by the `ceph` user.

Recovery is performed from the hosts, after the defender has revoked the compromised credentials.

### 3.3 Operations covered

- **Version 1 (core).** Object deletion (`rm`, `purge`), including deletes applied through recovery. The PG-level paths that destroy data without per-object deletes: pool deletion, pool size reduction, and removal of stray PG copies after remapping. Snapshot removal followed by snap trimming. Object deletion is built and tested (§6); the others are next (§4.5).
- **Stretch.** Destructive writes (`truncate`, `zero`, `writefull`, partial overwrites), handled by retaining an object's pre-write state once per object per retention epoch. This gives the same semantics as a snapshot taken at the start of the window.
- **Out of scope.** Erasure-coded pools, where retaining a single shard is useless. Gradual corruption that stays below any detection threshold for longer than the retention window.

---

## 4. Design

### 4.1 The protected-delete contract

For a destructive operation on object *O* at version *v*:

1. *O* becomes logically deleted immediately on every replica; clients see normal semantics.
2. The PG log records the deletion normally, and peering and recovery treat it as authoritative.
3. Two OSDs — the PG's primary and one retaining replica — each retain *O@v*'s pre-delete state (data, xattrs and omap) in a local vault until their respective retention windows expire (§4.4). For objects without shared blocks, retention pins the existing blocks; it does not copy them.
4. The vault is never part of the placement group. It is invisible to peering, backfill, recovery, scrub, stray-PG removal, and PG split and merge, and can never become authoritative.
5. Design goal: an acknowledged delete survives any single OSD failure. When the client is acknowledged, the pre-delete bytes are durable on at least one OSD that keeps them — as a vault entry, or as the not-yet-removed object that its OSD vaults when it applies the delete. The prototype meets this in every single-OSD failure tested, including kills in the middle of a delete (§6.3–6.4); the general argument and a model check are planned (§5.6).
6. Restore creates *O@v+k* as a new write; it never rolls the PG log backward.

Two invariants hold at all times, and the evaluation checks them after every scenario:

- **No resurrection.** A vault entry never causes a deleted object to reappear through normal Ceph operation.
- **No durability loss.** Retention never reduces the redundancy of live data. Vault capacity and live-data capacity are accounted separately.

### 4.2 Mechanism: pinning extents below the object namespace

**The abstraction.** In BlueStore, an object's data blocks (extents) belong to its *onode*, the object's metadata record. Deleting the object normally frees them. ReplicaVault adds a second kind of owner that the object layer cannot see, a **retention pin**:

> An extent is reusable only if it has no live references and no retention pins.

A protected delete transfers ownership of the object's extents from its live onode to a retention pin, atomically with the delete. Expiry releases the pin. Nothing is copied: the cost is metadata, whatever the object's size.

**The implementation: the pin is an onode in a hidden vault.** Each OSD keeps a vault in a reserved namespace of its own **meta collection**. That collection holds OSD maps and the superblock, and none of peering, scrub, backfill, recovery, stray-PG removal, or PG split and merge ever lists it. On a protected delete, BlueStore moves the object's onode — extent map, blobs, checksums, compression state, xattrs and omap — from the PG's collection into the vault, under a name encoding pool, PG, object, version and deletion time. The PG then sees a normal delete, while the moved onode keeps the blocks allocated.

Using an ordinary onode as the pin is deliberate. A dedicated retention table, as a new RocksDB key prefix, would hide the pins even from the storage engine's own API. But every BlueStore path that decides which blocks are in use would then have to learn about it:

- the crash-time allocation rebuild, which walks onodes and shared blobs;
- fsck and repair, which would report pinned blocks as leaked and free them;
- per-pool space accounting and the offline tools.

An older OSD binary would treat pinned blocks as free, so downgrading would lose data. A vault onode is already understood by every one of those paths, so they protect it without change. Hiding the vault from Ceph's command surface is handled separately (§4.3).

**The BlueStore change** (about 370 lines; no on-disk format change, no new key prefix, no encoding change):

1. BlueStore's move-rename, which previously required source and destination in the same collection, accepts the meta collection as destination for objects that reference no shared blob.
2. The move rewrites the onode's key, its extent-map shard keys and its omap keys.
3. It re-homes the onode and its blobs in memory, reusing the logic BlueStore already uses when splitting a PG.
4. It moves the object's space accounting from its pool to the meta pool, through a second per-pool delta on the transaction.
5. It allocates and frees nothing.
6. An object that references a shared blob is refused, with nothing changed, and the caller falls back to copying.

**Ordering and atomicity.** On each retaining OSD, the move is queued in the same BlueStore transaction as the PG transaction — its log entry and its remove — and ahead of them. All three commit in a single RocksDB batch: either the object is live and unvaulted, or it is gone from the PG and present in the vault. The PG's own remove then finds nothing to remove. The client acknowledgement waits for the primary's commit, which is what contract item 5 rests on.

**When retention copies instead.** A delete is moved only if its object references no shared blob, and if the PG transaction's first operation on the object is the remove. When an object with snapshots is deleted, Ceph clones it within the same transaction before removing it, so its blocks are shared. Such deletes are copied into the vault in their own transaction, ordered before the PG transaction, as in the earlier design. In the tests, copies were 0% of vault entries in every scenario without snapshots, and 13% in a one-hour mixed workload with snapshots (§6.4). §4.8 describes how to avoid most of them.

**Choosing the retainers.** The **primary** vaults every delete. The **retaining replica** is the next OSD in the acting set ordered primary-first (or the primary itself, if the acting set has one member). Both are recomputed for each delete, so retention follows the acting set through failures and remapping.

A single retainer fails in three cases the correctness study found:

1. **Size 1.** With one replica there is no second OSD to retain.
2. **Primary-temp.** An attacker can use `primary-temp` to make the designated replica the primary, which never vaulted.
3. **Retainer crash.** A retainer that crashes mid-delete, is marked out, and returns after its PGs moved elsewhere is purged as a stray. The only surviving pre-delete bytes go with it.

Having the primary vault closes all three without any protocol change.

### 4.3 Reclamation authority

The OSD process holds the data, so protection must remove every path by which Ceph's command surface can cause early release. ReplicaVault does four things:

1. **Policy is local, not central.** Retention settings are read only from the root-owned policy file. They are ignored in the monitors' configuration database, and cannot be changed by `ceph config set` or `ceph tell ... injectargs`.
2. **No release command exists.** The OSD exposes no admin-socket or `tell` command that shortens retention or releases vault data. The only operation reachable from the Ceph side is *freeze*, which extends retention and is therefore safe to expose.
3. **The vault namespace is guarded.** A small number of existing OSD commands operate on meta-collection objects; one, for example, trims stored OSD maps by name prefix. A guard in the OSD's transaction path rejects any operation on the vault namespace not issued by ReplicaVault itself, and vault names avoid every prefix an existing command matches.
4. **A separate reclaimer owns expiry.** A small daemon running under its own Unix account keeps an append-only retention ledger. It authorizes the OSD to release a vault entry only after its expiry time, and the OSD refuses to release without that authorization.

Part of the contribution is methodological: an **inventory of every destructive path** in Ceph reachable from monitor, manager and librados commands. It covers deletes, pool and PG removal, size changes, snapshot trimming and stray cleanup, together with every command that reaches the meta collection. Each path is either routed through the vault, guarded, or shown to require orchestrator or host access. The inventory also covers debug and injection options reachable through `ceph config` and `ceph tell`, since those are in the attacker's reach. It is released with the paper.

If the audit finds meta-collection exposure that cannot be guarded, the fallback is a dedicated retention table below the ObjectStore API, with the format and recovery-path changes that implies (§4.2).

### 4.4 Asymmetric retention

Zero-copy removes the I/O cost of two retained copies, but not the capacity cost: each pinned extent stays allocated until its pin is released. Asymmetric windows recover most of that capacity. The two retained copies do different jobs, so they need not live equally long:

- **The primary's copy covers failures around the delete itself:** the window between acknowledgement and the retainer's copy becoming durable, and the failure handling that follows. That needs hours, not days.
- **The retainer's copy covers late detection.** It carries the long window — for example 24 hours to several days, set by policy.

The primary knows when a short window is safe. A replica sends its commit only after its transaction is durable, and its vault move commits in the same transaction as its remove. So receiving the retainer's commit for a delete proves the retainer's vault entry is durable.

- **The primary's entry starts with the short window.**
- **It is promoted to the long window whenever the primary does not receive the retainer's commit for that delete** — because of a failure, a remap, or an interval change.

This uses only messages Ceph already sends. Steady-state retained capacity is then roughly *delete rate × (long window + short window)*: close to one copy's worth when the short window is much shorter than the long one.

*To verify in code before building:* that the primary's per-op commit tracking survives interval changes well enough to decide promotion.

### 4.5 PG-level destruction

Pool deletion, size reduction and stray removal destroy whole PGs, and are the realistic large-scale attack. In each case, Ceph removes the PG's objects one by one before removing its collection. The same move used for object deletes can therefore be applied to each object: instead of being removed, each unshared onode moves into the vault.

- **Cost.** This is proportional to the number of objects and omap keys, not to the bytes destroyed. Vanilla Ceph already pays a per-object metadata cost to remove a PG, so retention adds only key rewrites. That is inferred from the object-delete results, and not yet measured.
- **Fallback.** If per-object moves prove too slow for very large pools, the alternative is to retain the PG's collection itself: record it as *retired* in the meta collection and leave it on disk until the reclaimer removes it. That keeps the work O(1) per PG, at the price of teaching boot-time enumeration and stray handling about retired collections.

*Open questions:* which of the two to build, and how restore names objects whose pool no longer exists.

### 4.6 Capacity and the exhaustion attack

Retention costs capacity equal to the data deleted within the window on each retaining OSD. Two effects add to this:

- A delete missed by a down retainer and later applied through recovery can be vaulted a third time. The correctness study bounded this at three entries per delete, including under an attacker who toggles a retainer up and down.
- An attacker who knows about retention can try to fill the vault — writing and deleting repeatedly — to force early reclamation or trigger OSD full conditions. Zero-copy makes such churn cheap for the attacker in I/O as well, so the capacity bound matters more, not less.

ReplicaVault declares a policy instead of leaving this undefined. Each OSD has a vault budget. When it is reached, the default is **fail-closed**: further destructive operations on that OSD's PGs are rejected until retention expires or the defender intervenes, trading availability for recoverability. An alternative *expire-oldest* policy is available and evaluated. Either way, vault usage counts toward OSD fullness, so the vault can never silently push live data into a full condition.

Vault bytes are charged to the meta pool in BlueStore's statistics, not to the originating pool. Capacity measurement therefore uses vault-specific counters.

### 4.7 Detection, freeze and restore

Detection is deliberately simple, because the contribution is that detection can be late. The reclaimer watches local signals — delete rate, destructive-operation bursts, PG retirements — and freezes expiry automatically when a threshold is crossed. The defender can also freeze out of band. The evaluation reports how late detection can be and still recover everything.

A host-side tool lists vault entries by pool, object and time. It restores selected objects by writing them back through librados as new versions, after the defender has rotated credentials. Restored data is verified against checksums.

- **Already working.** A manual version of this path works today: 24 of 24 moved entries were restored with their original bytes (§6.4).
- **Planned: zero-copy restore.** The two OSDs that hold vault entries could restore by moving the onode back into the PG instead of rewriting the data. The third replica holds no entry and still receives the data over the network, so restore is cheap but not free.

### 4.8 The remaining copy cost

Copying remains only for deletes whose blocks are shared, which in practice means objects with snapshots. Two measures address it.

1. **Vault at snap-trim time instead.** When an object with snapshots is deleted, Ceph first clones it, so the snapshot clone already holds the same bytes. For these deletes, ReplicaVault could record the delete without copying, and vault the clone when snapshot removal would trim it. Snap trimming is on the destructive-path inventory anyway (§3.3). By trim time the blocks may no longer be shared, so the move could be zero-copy. *To verify in code before building.*
2. **Take any remaining copy off the critical path.** The copy currently reads the object synchronously on the OSD's operation path, which stalls unrelated operations at large object sizes. Running it off the operation shard — or chunking it — keeps the acknowledgement waiting for a durable entry without blocking other work. This is built only if snapshot-heavy workloads show a material fallback share after measure 1.

---

## 5. Evaluation

### 5.1 Testbed

- **Development and correctness.** One CloudLab node running `vstart.sh` clusters from source builds: a Debug cluster (5 OSDs, BlueStore DB and WAL on SSD) for the scenario suite, and a release build for cost probes.
- **Full evaluation.** 5–6 CloudLab c220g2 nodes: 4 OSD hosts (failure domain = host, BlueStore DB and WAL on SSD, data on HDD — a common production layout), 1 client node, and optionally a fifth OSD host for multi-failure scenarios. Fallback: d430 nodes, reported as an HDD-only cluster with emphasis on relative overhead.

### 5.2 Workloads

- **Microbenchmarks.** Protected versus vanilla deletes, object sizes from 4 KiB to 128 MiB, omap sizes from 0 to 20,000 keys, with and without snapshots.
- **Normal workloads.** Mixed put, get, overwrite and delete through librados and RGW, and a replay of public object-storage traces with realistic delete ratios. The SNIA IBM Cloud Object Storage traces are a candidate; check that they include deletes. RBD with periodic snapshots, to measure the copy-fallback share in a realistic snapshot workload. RGW bucket-index churn, for omap-heavy deletes.
- **Attack workloads.**
  - Burst deletion, slow deletion below naive rate thresholds, and deletes spread across many PGs.
  - Pool deletion and pool size reduction.
  - Snapshot removal followed by trimming.
  - Placement manipulation (`primary-temp`, upmap, OSD out) during deletion.
  - The capacity-exhaustion attack.
  - An end-to-end destruction scenario: wiping backup pools and images with stolen credentials.
- **Failure workloads.**
  - OSD and host crashes, primary changes, remapping and backfill during and after attacks.
  - Retainer and primary failures mid-delete, with kill timing scaled to the delete's duration (§6.4).
  - Deep-scrub throughout.

### 5.3 Baselines

- **B0 — vanilla Ceph.**
- **B1 — periodic pool snapshots** every *N* minutes. Uses the same clone machinery, but the administrator can remove the snapshots. Isolates the value of the separated reclamation authority.
- **B2 — RGW versioning plus Object Lock.** Protects the S3 path; demonstrates the RADOS-level gap.
- **B4 — external backup** to a separate cluster. Compared on recovery point, capacity and recovery time.

Within ReplicaVault, the evaluation compares:
- the copying vault against the zero-copy vault;
- one retaining OSD, two with symmetric windows, and two with asymmetric windows (§4.4).

### 5.4 Metrics

- **Recovery coverage:** destroyed bytes recoverable ÷ destroyed bytes.
- **Detection tolerance:** the longest detection delay for which coverage stays at 100%.
- **Delete latency** (p50, p99) against object size and omap size; **interference** with concurrent non-delete operations; **foreground throughput** loss on normal workloads.
- **Device bytes written per delete**, data device and DB/WAL separately.
- **Copy-fallback share** of vault entries per workload.
- **Retained capacity** against window length, retention policy and workload; vault entries per delete; behavior under the exhaustion attack.
- **Recovery time** for a restore of *N* objects or bytes.
- **Invariant checks:** scenarios and runs executed, resurrections observed (must be zero), scrub inconsistencies (must be zero), acknowledged deletes without a surviving entry (must be zero), and vault extents found on the allocator's free list (must be zero).

Vault entries are counted from the store, not from logs. The correctness study found that log lines both over- and under-count durable entries around crashes (§6.3).

### 5.5 Principal figures

- **Figure A — cost of retention.** Delete latency, interference and device bytes against object size, 4 KiB to 128 MiB: vanilla, copying vault and zero-copy vault. The zero-copy curves are expected to lie on vanilla's, as in the single-host results of §6.5. The 4 MiB default object size is marked as the common operating point.
- **Figure B — detection tolerance.** Recovery coverage against detection delay for each retention policy, with B1 shown collapsing when the attacker removes the snapshots.
- **Figure C — affordability.** Retained capacity against window length on trace replays, for symmetric and asymmetric retention.
- **Figure D — attack timeline.** An attack with OSD and host failures mid-attack: live data, vault contents and recovery over time.
- **Figure E — what goes wrong without the design's safeguards.** Acknowledged deletes lost by single-retainer designs under the failure and placement scenarios of §6.3, against zero for ReplicaVault.

### 5.6 Correctness evaluation

The scenario suite built during the three studies is the core of the correctness evaluation. It currently has 27 scenarios:

- **Failover, backfill, scrub and recreation:** primary failures before, during and after deletes; backfill; deep-scrub; object recreation.
- **OSD lifecycle and snapshots:** OSD restart; PG split and merge; snapshots; manual restore; missed deletes.
- **Attacks:** five placement attacks.
- **Crashes:** crash consistency, read-after-queue, and retainer and primary failure with return as a stray.
- **Storage engine:** allocation rebuild after a crash with disk fills, shared-blob fallback, compression, restore, omap-heavy objects, and a one-hour soak with repeated OSD kills.

Every scenario runs on vanilla Ceph first to validate the harness. The suite is extended with each new path (PG-level destruction, snap-trim retention, the reclaimer) and rerun on every change.

Two methodology rules came out of the studies:
- crash timing must scale with the duration of the operation under test, and every run records whether its kill actually landed mid-operation;
- any check of the allocator after a crash compares vault extents directly against the persisted free list, which BlueStore's own offline fsck does not do in its default allocation mode.

To strengthen item 5 from *tested* to *shown*, a TLA+ model of the delete, vault, acknowledgement and failover protocol will be checked for the single-failure property, if the schedule allows (§9).

---

## 6. Feasibility evidence

Everything in this section was run on Ceph v19.2.3, from patch series published in the project repository that rebuild each prototype exactly from a clean checkout. Pass/fail criteria for each study were committed to the repository, dated, before any of its prototype code was written, and were never edited. Every scenario was run on unmodified Ceph first.

### 6.1 The feasibility question

The pilot asked whether a replica can hold hidden pre-deletion data without disturbing Ceph's correctness machinery. It had a pre-registered go/no-go gate and an approved fallback project (EXODUS). The gate passed, and the fallback is not needed.

### 6.2 Pilot (September 25–26, 2026)

- **Primitive check (from source).** BlueStore's move-rename required source and destination in the same collection, so zero-copy retention outside the PG was not available without changing BlueStore. Under the pre-registered decision rule, the pilot proceeded with a copying vault and restated H1 as a bounded copy cost. The zero-copy study (§6.4) later lifted this restriction.
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

### 6.3 Correctness study (September 28 – October 2, 2026)

The pilot showed the mechanism works under normal failures. This study asked whether it holds when placement is manipulated, and when OSDs crash at the worst moment.

| Finding | Before the fix | After the fix |
|---|---|---|
| **Pool size 1** leaves no second OSD to retain | 24 of 24 acknowledged deletes unvaulted | 0 unvaulted; the primary retains |
| **`primary-temp`** makes the designated replica the primary, which never vaulted | 25 of 25 unvaulted on affected runs | 0 unvaulted |
| **Retainer crashes mid-delete, is marked out, returns as a stray and is purged** | **164 of 320 acknowledged deletes lost** (18 of 20 runs) | **0 of 320 lost** (20 of 20 runs), once the primary also vaults |

Other results from the study:

- **Primary failure mid-delete:** 0 of 320 lost in each of two variants — the primary returning as a stray, and never returning (20 runs each).
- **Crash consistency:** 100 runs killing the retainer under a stream of deletes. Every one of 1,600 acknowledged deletes had an intact copy after recovery, and BlueStore fsck was clean every time.
- **Read-after-queue:** 200 cases with up to four writes in flight before a delete. The vault always held the last queued write.
- **Full regression:** 17 scenarios, 118 of 118 runs, 1,000 of 1,000 deletes with an intact copy.
- **Placement attacks that turned out harmless:** `ceph osd out` and `pg-upmap-items` open no gap. Ceph keeps backfill targets out of the acting set, so an OSD holding the object always retains it.

Two lessons shape the evaluation:

1. **"Retained" must be checked after recovery, against the disk.** Log lines alone both missed durable copies and recorded copies a crash lost.
2. **Every failure that lost data was ordinary Ceph behavior**, such as the default 10-minute automatic mark-out followed by stray purge. None of them was exotic. This is the evidence that retention in a replicated store is subtle, and it is what distinguishes the problem from single-device retention.

### 6.4 Zero-copy study (October 3–6, 2026)

This study asked whether BlueStore's same-collection restriction is fundamental. A code reading found it was in-memory and accounting bookkeeping, which can be handled for objects without shared blobs without changing the on-disk format. The change is described in §4.2; with the ReplicaVault integration and unit tests, it spans 9 files (+971 / −84 lines). It was tested on a cluster whose DB and WAL sit on an SSD. That configuration matters: only there does BlueStore rebuild its allocator from onodes after a crash, which is the path a pin must survive.

- **Unit tests.** 7 of 7 new BlueStore tests pass, each with a deep fsck and an exact check that the space accounting moved from pool to meta:
  - small and large objects;
  - fragmented objects with sharded extent maps;
  - 20,000 omap keys;
  - forced compression;
  - a move queued right after uncommitted writes;
  - 50 moves in one transaction;
  - the shared-blob refusal.

  Ceph's existing ObjectStore suite also passes (129 tests, 4 skipped by design, 0 failures).
- **Allocator after a crash (30 of 30 runs).** Each run has five steps:
  1. Delete objects, moving them into the vault.
  2. Kill the OSD, forcing the allocator rebuild.
  3. Fill the disk with new data (8 GiB; up to 70% of the disk in 6 runs).
  4. Check that no vault extent appears on the persisted free list.
  5. Run a deep fsck, and verify every vault entry byte for byte.

  No vault block was ever freed or overwritten. The checker itself was shown to catch an injected free-list overlap, a missing entry and a corrupted entry.
- **Full regression.** Every scenario from §6.2–6.3 passed on the zero-copy build, with a disk scan and fsck of every OSD after each run.
- **Crashes in the middle of a move.** The pre-registered crash scenarios kill an OSD 0–1.5 s into a run. With zero-copy, deletes finish in about 25 ms, so in 0 of 60 runs did a kill land while deletes were still in flight. Those runs passed as specified but tested nothing. Rerun with kills at 0–40 ms:
  - 26 runs killed an OSD mid-delete;
  - 398 deletes were acknowledged after the kill;
  - every one had an intact vault entry, and every fsck was clean.
- **New scenarios.**
  - **Shared-blob fallback:** correctly copied, with both the clone and the entry intact.
  - **Compression:** 140 MiB of compressed data, all moved and intact.
  - **Restore:** 24 of 24 entries restored with their original bytes.
  - **Omap-heavy objects:** see §6.5.
  - **One-hour soak:** 5,574 deletes, 14 OSD kills, 19,659 vault entries intact afterwards; copies were 13% of entries in that snapshot-heavy mix, 0% in every other scenario.

### 6.5 Cost

The probe used one host, a release build, and 3 OSDs sharing one disk. Absolute latencies are inflated by that setup, so only comparisons between builds are meaningful. Each row is the range over two interleaved repetitions of 20 deletes, with a background workload of 4 KiB reads and writes.

| Deleted object | Delete p50 (ms): vanilla / copy / **zero-copy** | Data written per delete (MiB, 3 OSDs): vanilla / copy / **zero-copy** |
|---|---|---|
| 4 KiB | 141–151 / 167–181 / **153–174** | 0.6–0.7 / 0.7 / **0.6–0.7** |
| 1 MiB | 143–167 / 278–292 / **134–149** | 0.6–0.7 / 2.7 / **0.7** |
| 4 MiB | 157–158 / 425–448 / **160–164** | 0.6 / 8.6 / **0.6** |
| 16 MiB | 159–166 / 938–971 / **151–157** | 0.6 / 32.7 / **0.6** |
| 64 MiB | 142–153 / 2,790–2,975 / **164–173** | 0.6 / 128.7 / **0.6** |
| 128 MiB | 158–160 / 5,168–5,223 / **140–178** | 0.6–0.7 / 256.7 / **0.6** |

The data written per delete is the background workload; the copying vault adds twice the object size.

- **Latency and bytes.** Zero-copy delete latency and data-device bytes match vanilla at every size. The copying vault writes twice the object size and is 33× slower at 128 MiB.
- **Interference.** The p99 latency of concurrent 4 KiB operations stays at vanilla levels up to 64 MiB. At 128 MiB, one repetition reached 583 ms (the other 266 ms; vanilla 233–277 ms), to be checked on the multi-host testbed. The copying vault reached 4.6–4.9 s.
- **DB/WAL.** Writes rise slightly with object size (1.0 → 1.5 MiB per delete), as larger objects have more extent-map keys to rewrite.
- **Omap.** The remaining size-dependent cost is omap, because every key is rewritten where vanilla deletes a range. Delete latency rises 16–24% at 2,000 keys and 37–53% at 20,000 keys; there is no difference at 100 keys.

---

## 7. Contributions

The idea: **in a replicated store, replicas can agree that an object is gone while the storage engine beneath them keeps its blocks pinned, out of the administrator's reach — and doing so correctly requires deciding which replicas pin, how pinning is ordered against removal, and when a delete may be acknowledged.**

**Primary contributions.**

1. **Correct delayed reclamation in a replicated object store.**
   - Deletion stays authoritative under peering, backfill, recovery and scrub, while designated OSDs retain the old data.
   - The correctness conditions are stated explicitly: which OSDs retain, how retention is ordered against removal, and when acknowledgement is safe. They tolerate any single OSD failure.
   - They are demonstrated by systematic failure and placement injection, including three failure modes of naive designs found and fixed along the way.
2. **Zero-copy retention by extent pinning.**
   - A retention pin is realized as a hidden onode in the storage engine, moved atomically with the delete. Retention then costs metadata, not data: device writes and delete latency match an unprotected delete at every object size tested.
   - Because the pin is an ordinary onode, the storage engine's existing crash recovery, allocator rebuild and consistency checks protect it without change, and no on-disk format change is needed.
3. **Separation of reclamation authority from storage administration**, with an inventory of every destructive path reachable from Ceph's command surface and how each is closed.
4. **Asymmetric retention across replicas.** A short-lived pin covers failures around the delete; a long-lived pin covers late detection. The evaluation characterizes recoverability against capacity under realistic delete rates and under a capacity-exhaustion attack.

**Enabling, and claimed as such.** The copy fallback for shared blobs, retention at snap-trim time, PG-level retention, and the restore tool.

**Not claimed.** Ransomware detection. Protection against in-place overwrites, unless the stretch goal is completed. Retaining old data beneath a compromised privilege level is established at the device and single-server level; the contribution is doing it correctly, and without copying, inside a distributed replicated store.

---

## 8. Related work and delta

**Self-securing and time-travel storage.** S4 (Strunk et al., OSDI 2000) kept every version for a detection window on a storage server that treated client operating systems as untrusted. FlashGuard (CCS 2017), Project Almanac's TimeSSD (EuroSys 2019) and RSSD (ASPLOS 2022) retain overwritten or invalidated data inside SSD firmware by delaying garbage collection, below a compromised host. Together they establish that logical destruction and physical reclamation can be separated beneath the attacker's privilege level. ReplicaVault's pinning is the storage-engine analogue of delayed garbage collection.

*Delta:* all of them operate on a single device or server. In a replicated store, retention must coexist with the replication protocol, whose PG log, peering, backfill and scrub all assume replicas converge. It must also choose its retainers and its acknowledgement point so that a single failure does not lose what a client was told is retained; §6.3 shows that the obvious choices get this wrong. ReplicaVault also pins in a general-purpose storage engine, whose crash recovery and consistency checking it must survive (§6.4), rather than in firmware it controls entirely. Replicas also allow retention that differs by replica, which a single device cannot offer.

**Versioning and snapshot file systems.** CVFS (FAST 2003), ZFS and Btrfs snapshots, and NetApp snapshots retain history cheaply, also by sharing blocks. *Delta:* their retention is controlled by the administrator of the same system.

**Cloud immutability features.** S3 Object Lock in compliance mode, Azure immutable blob storage, and Google Cloud Storage soft delete protect against account-level deletion within a provider whose own staff and control plane remain trusted. *Delta:* ReplicaVault provides a comparable guarantee inside a self-operated cluster, where the storage administrator is the threat.

**Ceph's own mechanisms.** RADOS snapshots, RBD trash, pool protection flags and RGW Object Lock (§2.2). *Delta:* every one is reversible by the administrator; ReplicaVault moves the authority.

**Ransomware detection.** A large literature detects ransomware by entropy, access patterns or machine learning. *Delta:* ReplicaVault is detection-agnostic. It converts a detection deadline of "before the damage" into "before the window closes."

*Citation status.* To verify before relying on details: all of the above, particularly the Ceph documentation's statements about Object Lock and RADOS, whether the IBM COS traces include deletes, and a documented AI-agent data-deletion incident for §2.3.

---

## 9. Venue and schedule

**Primary target:** FAST '28 spring cycle (expected mid-March 2027; confirm when the call appears). **Alternatives:** EuroSys 2028, or USENIX Security if the security framing leads. If timing allows, a short workshop paper on the correctness findings of §6.3 (for example at HotStorage) would establish the problem early.

| Weeks | Dates | Work |
|---|---|---|
| — | Sep 25 – Oct 6, 2026 | **Done:** pilot, correctness study, zero-copy study (§6) |
| 0–2 | Oct 7 – Oct 16 | Proposal defense. Prior-art close-out. Capacity analysis of traces (retained bytes per window). Small fixes from the zero-copy study (§10) |
| 2–6 | Oct 19 – Nov 15 | PG-level destruction (per-object moves; §4.5). Snap-trim retention (§4.8). Vault namespace guard. Restore tool, zero-copy restore. Suite rerun on every change |
| 6–10 | Nov 16 – Dec 13 | Reclaimer, local policy, asymmetric windows with promotion, command-surface audit and inventory, freeze; vault accounting and fail-closed policy |
| 10–14 | Dec 14 – Jan 10, 2027 | Deploy on the c220g2 cluster; baselines; trace replay; TLA+ model (holiday slack) |
| 14–19 | Jan 11 – Feb 14 | Attacks, failure injection, overhead, retention policies |
| 19–23 | Feb 15 – Mar 14 | Writing and submission |

**Cut in this order if the schedule slips:**

1. the overwrite stretch goal;
2. the off-path copy (§4.8, measure 2);
3. the TLA+ model (keep the written argument and the scenario evidence);
4. the external-backup baseline;
5. the end-to-end destruction scenario (keep scripted attacks);
6. size reduction and stray removal at full scale (keep pool deletion).

---

## 10. Risks and open questions

**Risks.**

| Risk | Status or mitigation |
|---|---|
| BlueStore has no zero-copy move into the vault | **Overcome** (§6.4): about 370 lines of BlueStore change, no format change |
| The BlueStore change has a latent bug that frees or corrupts pinned blocks | Unit tests, 30 allocator-rebuild runs with disk fills, mid-move crash kills and a one-hour soak, all clean (§6.4). Rerun on every change; the same checks run on the multi-host testbed |
| The change has to be carried to newer Ceph releases | Kept small and confined to the move path and accounting; the patch series rebuilds from a clean checkout. Reported as a maintenance cost |
| Scrub, backfill, stray cleanup, OSD boot, or PG split and merge mishandle vault data | **Retired** for object deletes in all three studies. Retested for each new path |
| A single-OSD failure loses an acknowledged delete | **Found and fixed** (§6.3). Tested for retainer and primary failure, including mid-move kills; general argument in the paper; TLA+ model planned |
| Snapshot-heavy workloads fall back to copying | Snap-trim retention (§4.8); fallback share measured on an RBD snapshot workload |
| Omap-heavy deletes cost more (up to +53% at 20,000 keys) | Reported as the remaining size-dependent cost; measured on RGW bucket-index churn |
| Vault omap keys are filed under pool id 0 | Harmless today (fsck clean, no key collisions), but a real pool 0's omap usage figures could include vault omap. Fix by rekeying to a vault-specific prefix, or state as a limitation |
| Commands that reach the meta collection undermine the vault | Namespace guard and audit (§4.3); a dedicated retention table is the fallback |
| Two retained copies double the retained capacity | Asymmetric windows with promotion (§4.4); evaluated in Figure C |
| Single-host numbers mislead | Treated as indicative only; reported numbers come from the multi-host testbed |
| Reviewers see "delayed delete" as known | Cite S4, TimeSSD and RSSD directly. The delta is replication-protocol correctness, zero-copy pinning in a general storage engine, asymmetric retention and authority separation, not delay itself |
| The threat model is judged unrealistic because cephadm confers host access | State the orchestrator exclusion explicitly and report what separating it requires |
| In-place overwrites (ransomware against RBD and CephFS) are not covered | Framing is deletion-driven destruction (§2.4); overwrites are the stretch goal, reported either way |
| Capacity-exhaustion attack | Declared fail-closed policy, evaluated under attack |
| The schedule is tight for OSD-level work | Correctness and zero-copy foundations done early; cut list; December 2027 graduation as a fallback |

**Open questions.**

1. For PG-level destruction, are per-object moves fast enough for large pools, or should whole collections be retired? How does restore address objects whose pool is gone?
2. Can snap-trim retention replace the copy fallback for objects with snapshots, and are their blocks unshared by trim time?
3. Does the primary's per-op commit tracking survive interval changes well enough to decide when to promote its pin to the long window?
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

The three studies then changed the design in four ways:

1. Retention is zero-copy for objects without shared blocks: the original goal, reached by moving the onode inside BlueStore after the first pilot ruled out an unmodified clone. Framing it as extent pinning follows Lipeng Wan's suggestion.
2. Two OSDs retain each delete instead of one.
3. Asymmetric retention takes the form of a short window on the primary's pin and a long window on the retainer's.
4. PG-level destruction reuses the same per-object move, with retired collections as the fallback.

## Appendix B — Relation to prior work in this dissertation

JANUS made cross-facility data movement resilient to loss. CephMaestro showed that an LLM agent can operate a Ceph cluster, which also means an agent can destroy one. ReplicaVault bounds the damage any holder of Ceph credentials — attacker, operator or agent — can do irreversibly.

It also follows three pre-registered pilots on DiskANN ideas (DuraVec, CorrGuard, CephVec), each stopped within days on clear evidence. Their common finding, that Vamana graphs have no structurally special regions to exploit, is why this paper moved from index structure to storage-system mechanism.

## Appendix C — Changes in revision 4

Revision 4 follows the zero-copy study (`results/zc/ZC_REPORT.md`, pre-registered in `ZC_CRITERIA.md`). Relative to revision 3, it:

- **Summary and hypotheses (§1):** describes retention as extent pinning, and restates H1 as metadata-only cost for objects without shared blocks.
- **Mechanism (§4.2):** replaces the copying vault with the zero-copy move, explains why the pin is an onode rather than a dedicated table, and keeps copying only as the fallback for shared blobs.
- **Authority, capacity and PG-level destruction (§§4.3–4.6):**
  - adds the vault namespace guard to §4.3;
  - notes in §4.4 that asymmetric windows now matter for capacity, not I/O;
  - reuses the per-object move for PG-level destruction in §4.5, with retired collections as the fallback;
  - notes in §4.6 that zero-copy makes vault churn cheap for an attacker.
- **Restore and remaining copy cost (§§4.7–4.8):** adds zero-copy restore; replaces the off-path copy section with the remaining copy cost and snap-trim retention.
- **Evaluation (§5):** adds the copy versus zero-copy comparison, device bytes, copy-fallback share and omap size as dimensions; adds snapshot and omap-heavy workloads; adds the storage-engine scenarios and two methodology rules.
- **Feasibility evidence (§6):** adds the zero-copy study (§6.4) and replaces the early cost signal with the three-way cost comparison (§6.5).
- **Contributions, schedule and risks (§§7, 9, 10):** adds zero-copy pinning as a primary contribution, updates the schedule and cut list, and updates the risks and open questions.
