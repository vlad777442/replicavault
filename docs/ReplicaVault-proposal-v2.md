# ReplicaVault: Bounded Recovery After Authorized Destruction in Replicated Object Storage

**Draft research proposal — paper three · Revision 2, September 2026**
Vladislav Esaulov, advised by Lipeng Wan, Georgia State University

---

## 1. Summary

Replication protects data against hardware. It does not protect data against the storage system itself. When an operation is *authorized* — a `rados rm`, a pool deletion, a pool size reduction — Ceph applies it faithfully to every replica, and the redundancy that took three times the capacity to buy is destroyed in the same instant as the data it protected.

The operations that cause this are exactly the ones an attacker performs after stealing administrative credentials, and exactly the ones a mistaken operator or a misbehaving automation agent issues by accident. Ceph's existing safeguards sit at the wrong layer or answer to the wrong authority. RGW Object Lock is enforced in the S3 gateway, so anything that talks to RADOS directly bypasses it. Pool flags such as `nodelete`, the `mon_allow_pool_delete` guard, and pool snapshots are all reversible by the same administrator they are meant to stop.

ReplicaVault separates **logical deletion** from **physical irreversibility**. A destructive operation completes normally: every replica agrees the object is gone, clients see `ENOENT`, the PG log records the deletion, and peering treats it as authoritative. But a designated replica does not reclaim the old data. It moves it — without copying, using the same BlueStore clone machinery that backs RADOS snapshots — into a local vault outside the placement group, where it stays for a bounded retention window. Only a protected reclamation path, outside the reach of Ceph administrative credentials, can release it, and only after the window expires. Restore writes the data back as a new object version rather than rolling history backward.

Because the cluster already holds several replicas, retention can be *asymmetric*: one replica reclaims immediately, a second keeps the old data for 30 minutes, a third for 24 hours. The system gains temporal redundancy from spatial redundancy it already paid for. Detection of an attack no longer has to succeed before the damage is done — only before the retention window closes.

The work rests on one feasibility gate and three hypotheses.

**Feasibility (gate).** A replica can hold hidden pre-deletion data without disturbing Ceph's correctness machinery: under primary failover, backfill, deep-scrub, and object recreation, no deleted object is ever resurrected and scrub reports no inconsistency. This is an engineering question, and it is answered first.

**H1 (overhead).** Retention adds little to the cost of normal operation, because the vault move is a metadata operation whose cost is independent of object size.

**H2 (coverage).** For destructive operations issued through Ceph's command surface, ReplicaVault recovers all destroyed data whenever detection occurs within the retention window, including when OSDs and hosts fail during the attack.

**H3 (affordability).** Under realistic delete rates, the capacity held by retention is a small fraction of cluster capacity for windows of hours, and the capacity-exhaustion attack this invites is contained by a declared fail-closed policy.

---

## 2. Motivation

### 2.1 Replication multiplies data, not history

Three-way replication turns one object into three copies and one delete into three deletes. Erasure coding does the same with shards. Neither provides a way to undo an operation the system accepted as legitimate. That job is left to snapshots, versioning, and external backups — mechanisms that cost capacity, need management, and in Ceph's case are controlled by the same administrative authority an attacker would hold.

### 2.2 Ceph's safeguards answer to the attacker

| Safeguard | Why it does not stop an administrator |
|---|---|
| RGW Object Lock and versioning | Enforced in the gateway; direct RADOS operations bypass it |
| Pool `nodelete` / `nosizechange` flags | The administrator can unset them |
| `mon_allow_pool_delete = false` | The administrator can set it to true |
| Pool and self-managed snapshots | The administrator can remove them (`rmsnap`), after which the snap trimmer reclaims the data |
| RBD trash | A deferred delete for images, purgeable by the same administrator |
| External backups | Effective, but outside the cluster, with their own cost and recovery-point gap |

The gap is not that Ceph lacks protection mechanisms. It is that every one of them can be switched off by whoever holds the admin keyring.

### 2.3 Who holds the admin keyring

Three kinds of actor issue authorized destructive operations:

- **Attackers with stolen credentials.** Ransomware operators increasingly destroy or encrypt backups and storage before encrypting endpoints, so that recovery is impossible without paying.
- **Human operators making mistakes.** Deleting the wrong pool, reducing the wrong pool's size, or running a cleanup script against the wrong cluster.
- **Automation and AI operations agents.** Agents that operate infrastructure with administrative credentials — including LLM-driven Ceph operations agents such as CephMaestro — can issue destructive commands because of a model error, a misread instruction, or prompt injection. Public incidents of AI coding agents deleting production data have made this concrete. *(Cite a specific documented incident after verification.)*

All three have Ceph credentials. None needs root on the storage hosts. ReplicaVault is designed for exactly that gap.

### 2.4 Temporal redundancy from spatial redundancy

The replicas already exist. Letting them disagree about *when* old data is reclaimed — while never disagreeing about *what* the current state is — costs no new copies at delete time, and turns an irreversible operation into one that is reversible for a bounded, configurable time.

---

## 3. Threat model and scope

### 3.1 Attacker

| Capability | In scope? |
|---|---|
| Any librados operation, including `rm`, `purge`, `truncate`, `writefull` | Yes |
| Any monitor or manager command: pool delete, size reduction, flag changes, config changes, `ceph tell` to OSDs | Yes |
| Marking OSDs out, destroyed, or purged in the cluster map | Yes |
| Orchestrator access (cephadm SSH keys, Rook/Kubernetes control) | **No** — see below |
| Root on OSD hosts, raw device access, physical destruction | **No** |
| Modifying the OSD binary | **No** |

The orchestrator exclusion is essential, and the paper states it plainly. In cephadm deployments the manager holds SSH access to every host and can deploy new container images (`ceph orch upgrade`) or wipe devices (`ceph orch device zap`); in Rook, Kubernetes control confers the same power. An attacker with orchestrator access effectively has root on the hosts, and no software on those hosts can then guarantee anything. The realistic attacker ReplicaVault targets holds Ceph capabilities — a stolen admin keyring, a compromised automation account, an agent's credentials — but not the orchestrator. Deployments must keep the two separated, and the paper reports what that separation requires.

### 3.2 Defender

The defender retains root on the storage hosts through an out-of-band channel. The trusted computing base is the OSD binary, the host operating system, and a local retention policy file owned by root and not writable by the `ceph` user. Recovery is performed from the hosts, after the defender has revoked the compromised credentials.

### 3.3 Operations covered

- **Version 1 (core):** object deletion (`rm`, `purge`) and the PG-level paths that destroy data without per-object deletes: pool deletion, pool size reduction, and removal of stray PG copies after remapping.
- **Stretch:** destructive writes (`truncate`, `zero`, `writefull`, partial overwrites), handled by cloning an object's pre-write state onto the retaining replica once per object per retention epoch — the same semantics as a snapshot taken at the start of the window.
- **Out of scope:** erasure-coded pools (retaining a single shard is useless), and gradual corruption that stays below any detection threshold for longer than the retention window.

The overwrite case matters: ransomware against RBD and CephFS mostly overwrites data rather than deleting it. Version 1 targets the deletion-heavy object-storage case and the operator and agent failure modes; the stretch mechanism and its cost are reported honestly either way.

---

## 4. Design

### 4.1 The protected-delete contract

For a destructive operation on object *O* at version *v*:

1. *O* becomes logically deleted immediately on every replica; clients see normal semantics.
2. The PG log records the deletion normally, and peering and recovery treat it as authoritative.
3. A designated replica retains *O@v*'s physical data in a local vault until time *T*.
4. The vault copy is never part of the placement group: it is invisible to peering, backfill, and scrub, and can never become authoritative.
5. Restore creates *O@v+k* as a new write; it never rolls the PG log backward.

Two invariants hold at all times, and the evaluation checks them after every scenario:

- **No resurrection:** a vault copy never causes a deleted object to reappear through normal Ceph operation.
- **No durability loss:** retention never reduces the redundancy of live data. Vault capacity and live-data capacity are accounted separately.

### 4.2 Mechanism

**Where the change lives.** A delete is handled in `PrimaryLogPG` and shipped to replicas by `ReplicatedBackend`, where each OSD applies it as an ObjectStore transaction. On a retaining replica, the remove is rewritten as a move of the object into a per-OSD vault collection outside every PG collection, keyed by pool, PG, object name, version, and deletion time.

**Zero-copy by reuse, not invention.** BlueStore already retains object data without copying through shared blobs and reference counts — the machinery behind RADOS snapshot clones. The vault reuses it, so a protected delete is a metadata operation whose cost does not grow with object size. This is claimed as an implementation choice, not a contribution.

**The assumption to check first.** BlueStore's clone and move-rename transactions may require the source and destination to be in the same collection, with shared blobs tracked per collection. If a zero-copy move into a collection outside the PG is not available, there are three options, each of which changes the paper: (a) a copying move, which weakens H1 and Figure A; (b) extending BlueStore to support it, which the schedule cannot absorb; or (c) keeping the vault inside the PG collection under a hidden namespace, which puts vault entries in the path of scrub and backfill and requires restating item 4 of the contract in §4.1. The pilot answers this before anything else (§6, step 1).

**Choosing the retainers.** Each replica decides locally, from the object's hash and its own rank in the acting set at the time of the delete, whether it retains and for how long. Retention times per rank come from the local policy file, for example rank 0 reclaims immediately, rank 1 retains 30 minutes, rank 2 retains 24 hours.

**PG-level destruction.** When a PG is removed from an OSD — because its pool was deleted, its size was reduced, or it migrated away after remapping — retaining OSDs move its objects to the vault rather than deleting them. Whether this can be done collection-wide or must be done per object, and at what cost for large pools, is an open design question (§10).

### 4.3 Reclamation authority

The OSD process holds the data, so protection must remove every path by which Ceph's command surface can cause early release. ReplicaVault does three things:

1. **Policy is local, not central.** Retention settings are read only from the root-owned policy file. They are ignored in the monitors' configuration database and cannot be changed by `ceph config set` or `ceph tell ... injectargs`.
2. **No release command exists.** The OSD exposes no admin-socket or `tell` command that shortens retention or releases vault data. The only operation reachable from the Ceph side is *freeze*, which extends retention and is therefore safe to expose.
3. **A separate reclaimer owns expiry.** A small daemon running under its own Unix account keeps an append-only retention ledger and authorizes the OSD to release a vault entry only after its expiry time. The OSD refuses to release without that authorization.

Part of the contribution is methodological: an **inventory of every destructive path** in Ceph reachable from monitor, manager, and librados commands — deletes, pool and PG removal, size changes, snapshot trimming, stray cleanup — with each one either routed through the vault or shown to require orchestrator or host access. The inventory is released with the paper.

### 4.4 Capacity and the exhaustion attack

Retention costs capacity equal to the data deleted within the window on each retaining replica. An attacker who knows this can try to fill the vault — writing and deleting repeatedly — to force early reclamation or trigger OSD full conditions.

ReplicaVault declares a policy instead of leaving this undefined. Each OSD has a vault budget. When it is reached, the default is **fail-closed**: further destructive operations on that OSD's PGs are rejected until retention expires or the defender intervenes, trading availability for recoverability. An alternative *expire-oldest* policy is available and evaluated. Either way, vault usage counts toward OSD fullness, so the vault can never silently push live data into a full condition.

### 4.5 Detection and freeze

Detection is deliberately simple, because the contribution is that detection can be late. The reclaimer watches local signals — delete rate, destructive-operation bursts, pool-level removals — and freezes expiry automatically when a threshold is crossed. The defender can also freeze out of band. Detection sophistication is not a contribution; the evaluation reports how late detection can be and still recover everything.

### 4.6 Restore

A host-side tool lists vault entries by pool, object, and time, and restores selected objects by writing them back through librados as new versions, after the defender has rotated credentials. Restored data is verified against checksums recorded at vault time.

---

## 5. Evaluation

### 5.1 Testbed

- **Development and feasibility:** one CloudLab d430 running a `vstart.sh` cluster from a source build (6 OSDs, BlueStore, size-3 replicated pool).
- **Full evaluation:** 5–6 CloudLab c220g2 nodes — 4 OSD hosts (failure domain = host, BlueStore DB and WAL on the SSD, data on the HDDs, a common production layout), 1 client node, and optionally a fifth OSD host for multi-failure scenarios. Fallback: d430 nodes, reported as an HDD-only cluster with emphasis on relative overhead.

### 5.2 Workloads

- **Microbenchmarks:** protected versus vanilla deletes, object sizes from 4 KiB to 1 GiB.
- **Normal workloads:** mixed put, get, overwrite, and delete through librados and RGW, and a replay of public object-storage traces with realistic delete ratios (the SNIA IBM Cloud Object Storage traces are a candidate; check that they include deletes).
- **Attack workloads:** burst deletion, slow deletion below naive rate thresholds, overwrite-then-delete, pool deletion, pool size reduction, and deletes spread across many PGs; plus an end-to-end ransomware emulation driven by MITRE Caldera.
- **Failure workloads:** OSD and host crashes, primary changes, remapping, and backfill during and after attacks; deep-scrub throughout.

### 5.3 Baselines

- **B0 — vanilla Ceph.**
- **B1 — periodic pool snapshots** every *N* minutes. The same clone machinery, but the administrator can remove the snapshots. Isolates the value of the separated reclamation authority.
- **B2 — RGW versioning plus Object Lock.** Protects the S3 path; demonstrates the RADOS-level gap.
- **B3 — copy-to-vault.** A naive implementation that copies deleted data. Isolates the value of zero-copy retention.
- **B4 — external backup** to a separate cluster. Compared on recovery point, capacity, and recovery time.

### 5.4 Metrics

- **Recovery coverage:** destroyed bytes recoverable ÷ destroyed bytes.
- **Detection tolerance:** the longest detection delay for which coverage stays at 100%.
- **Delete latency** (p50, p99) against object size; **foreground throughput** loss on normal workloads.
- **Retained capacity** against window length and workload; behavior under the exhaustion attack.
- **Recovery time** for a restore of *N* objects or bytes.
- **Invariant checks:** number of failure scenarios run, resurrections observed (must be zero), scrub inconsistencies (must be zero).

### 5.5 Principal figures

- **Figure A — zero-copy.** Delete latency against object size for B0, B3, and ReplicaVault: flat for ReplicaVault, rising with size for copy-to-vault.
- **Figure B — detection tolerance.** Recovery coverage against detection delay for each retention policy, with B1 shown collapsing when snapshots are removed by the attacker.
- **Figure C — affordability.** Retained capacity against window length on trace replays.
- **Figure D — attack timeline.** An attack with host failures mid-attack: live data, vault contents, and recovery over time.
- **Figure E — overhead.** Throughput and tail latency on normal workloads, B0 against ReplicaVault.

---

## 6. Pilot and go/no-go

Three weeks, from late September to mid-October 2026. The pass criteria below are committed to the repository, dated, before the prototype is built. The steps are ordered so that the cheapest question that could end the project is answered first, and answered before the proposal defense.

**Step 1 — primitive check (days 1–2, from source; no cluster needed).** Read BlueStore's transaction handling for `OP_COLL_MOVE_RENAME`, `OP_CLONE`, and `OP_CLONERANGE`; how shared blobs are scoped; and how `split_collection` and `merge_collection` move objects between collections. Answer one question: can an object be moved or cloned into a collection outside its PG without copying data? Record the answer and which option in §4.2 follows from it. The debug build for step 2 compiles in the background.

**Step 2 — environment (days 1–3).** Pin the latest stable Ceph release, build from source in a debug configuration, and bring up a `vstart.sh` cluster. Confirm puts, deletes, OSD kills, OSD restarts, and deep-scrub on the unmodified build.

**Step 3 — trace the destructive paths (days 3–7).** Follow a delete from `PrimaryLogPG` through `ReplicatedBackend` to BlueStore; read how snapshot clones are retained and trimmed, how scrub builds per-replica object maps, how stray PGs are removed after remapping, how the OSD enumerates collections at boot and what it does with temp, stray, or unrecognized ones, and how PG split and merge rewrite collections. Write the design note and begin the destructive-path inventory.

**Step 4 — minimal prototype (week 2).** On one deterministically chosen replica, rewrite object removal as a move into the vault, using the mechanism chosen in step 1. Script the scenario suite.

**Step 5 — scenario suite (week 3).**

- Primary killed before, during, and after a delete.
- Backfill after `ceph osd out`.
- Deep-scrub on every PG.
- The same object name recreated after deletion; repeated delete and recreate of one object.
- OSD restart with vault entries on disk: the vault is not deleted, not treated as a stray PG, does not trip an assert, and its entries remain intact.
- A pg_num change with the autoscaler on — both split and merge — while vault entries exist for the affected PGs.
- Deletion of an object that has snapshot clones (head, snapdir, and whiteout handling).

**Step 6 — capacity input (in parallel, offline).** From public object-storage traces, compute retained bytes for windows of 30 minutes, 6 hours, and 24 hours. This is a design input for H3, not a gate.

**Step 7 — prior-art close-out (in parallel; not a gate, but not deferrable).** Read S4, FlashGuard, Project Almanac (TimeSSD), and RSSD in full; search for delayed reclamation or admin-proof retention in distributed storage; confirm the Ceph documentation's statements on Object Lock and RADOS. The delta against S4, TimeSSD, and RSSD must be settled before writing begins.

**Checkpoint at the proposal defense (Oct 9 or 16).** Step 1 is answered and step 3 is substantially done. The proposal presents ReplicaVault with the step 1 outcome stated, and EXODUS as the declared fallback.

**Gate.**
- **Pass** if, across every scenario in step 5, no deleted object reappears, deep-scrub reports no inconsistency, the vault copy exists and is intact on the designated replica — including after OSD restart and PG split or merge — and a manual restore produces a new object version with matching content.
- **Fail** if any scenario requires changing how peering decides authority; if step 1 leaves extending BlueStore (option b) as the only viable mechanism; or if the prototype is not passing within the three-week time box.
- **Pass with revised hypotheses** if step 1 leaves only a copying move (option a). H1 is restated as a bounded copy cost, Figure A is reframed around that cost, and baseline B3 is dropped because it becomes the design. The revision is committed before building.

**Decision rule.** Pass: proceed as written. Pass with revised hypotheses: proceed with the committed revisions. Fail: switch to EXODUS, the approved fallback, and run its pilot immediately.

---

## 7. Contributions

The idea: **in a replicated store, replicas can agree on the current state while disagreeing on when old state is destroyed — and the authority to destroy it can be taken away from the administrator.**

**Primary.**

1. **Delayed physical reclamation in a replicated object store that preserves placement-group semantics** — deletion stays authoritative under peering, backfill, and scrub while one or more replicas retain the old data — with correctness demonstrated by systematic failure injection.
2. **Separation of reclamation authority from storage administration**, together with an inventory of every destructive path reachable from Ceph's command surface and how each is closed.
3. **Asymmetric retention across replicas**, with a characterization of recoverability against capacity under realistic delete rates and under a capacity-exhaustion attack.

**Enabling, and claimed as such.** Zero-copy retention by reusing BlueStore's clone machinery; the restore tool.

**Not claimed.** Ransomware detection. Retaining old data beneath a compromised privilege level is established at the device and single-server level; the contribution is doing it inside a distributed replicated store.

---

## 8. Related work and delta

**Self-securing and time-travel storage.** S4 (Strunk et al., OSDI 2000) kept every version for a detection window on a storage server that treated client operating systems as untrusted. FlashGuard (CCS 2017), Project Almanac's TimeSSD (EuroSys 2019), and RSSD (ASPLOS 2022) retain overwritten or invalidated data inside SSD firmware by delaying garbage collection, below a compromised host. These establish the principle that logical destruction and physical reclamation can be separated beneath the attacker's privilege level. *Delta:* all of them operate on a single device or server. In a replicated store, retention must coexist with the replication protocol — the PG log, peering, backfill, and scrub all assume replicas converge — and the replicas themselves offer something a single device cannot: retention that differs by replica, paid for with capacity already allocated.

**Versioning and snapshot file systems.** CVFS (FAST 2003), ZFS and Btrfs snapshots, and NetApp snapshots retain history cheaply. *Delta:* their retention is controlled by the administrator of the same system.

**Cloud immutability features.** S3 Object Lock in compliance mode, Azure immutable blob storage, and Google Cloud Storage soft delete protect against account-level deletion within a provider whose own staff and control plane remain trusted. *Delta:* ReplicaVault provides a comparable guarantee inside a self-operated cluster, where the storage administrator is the threat.

**Ceph's own mechanisms.** RADOS snapshots, RBD trash, pool protection flags, and RGW Object Lock (§2.2). *Delta:* every one is reversible by the administrator; ReplicaVault reuses their machinery but moves the authority.

**Ransomware detection.** A large literature detects ransomware by entropy, access patterns, or machine learning. *Delta:* ReplicaVault is detection-agnostic; it converts a detection deadline of "before the damage" into "before the window closes."

*Citation status.* To verify before relying on details: all of the above, particularly the Ceph documentation's statements about Object Lock and RADOS, whether the IBM COS traces include deletes, and a documented AI-agent data-deletion incident for §2.3.

---

## 9. Venue and schedule

Primary target: **FAST '28 spring cycle** (expected mid-March 2027; confirm when the call appears). Alternatives: EuroSys 2028, or USENIX Security if the security framing leads. If the build runs long and graduation moves to December 2027, the FAST '28 fall cycle becomes available.

| Weeks | Dates | Work |
|---|---|---|
| 0–3 | Sep 28 – Oct 18, 2026 | Pilot and feasibility gate (§6); primitive check answered before the proposal defense |
| 3–7 | Oct 19 – Nov 15 | Complete version 1 deletion paths, including PG-level removal; restore tool; scenario suite run on every change |
| 7–11 | Nov 16 – Dec 13 | Reclaimer, local policy, command-surface lockdown, freeze; vault accounting and fail-closed policy |
| 11–15 | Dec 14 – Jan 10, 2027 | Deploy the custom build on the c220g2 cluster; baselines; trace replay (holiday slack) |
| 15–20 | Jan 11 – Feb 14 | Attacks, failure injection, overhead, retention policies |
| 20–24 | Feb 15 – Mar 14 | Writing and submission |

**Cut in this order if the schedule slips:** the overwrite stretch goal; the Caldera end-to-end emulation (keep scripted attacks); the external-backup baseline; the second retaining replica (report single-replica retention).

---

## 10. Risks and open questions

| Risk | Mitigation |
|---|---|
| BlueStore does not support a zero-copy move or clone across collections | Answered first, from source, in days 1–2 of the pilot; the fallback options and their consequences are declared in §4.2 and in the gate |
| Scrub, backfill, or stray-PG cleanup interacts with vault data in ways the design did not anticipate | The vault lives outside every PG collection; the feasibility gate tests exactly this before anything else is built |
| OSD boot or PG split and merge mishandle the vault collection | OSD restart and pg_num changes are in the pilot scenario suite |
| Reviewers see "delayed delete" as known | Cite S4, TimeSSD and RSSD directly; the delta is replication-protocol correctness, asymmetric retention, and authority separation, not delay itself |
| The threat model is judged unrealistic because cephadm confers host access | State the orchestrator exclusion explicitly and report what separating it requires |
| Ransomware against RBD overwrites rather than deletes | Scope version 1 to deletions and PG-level destruction; implement overwrite retention as a stretch goal and report its cost either way |
| Capacity-exhaustion attack | Declared fail-closed policy, evaluated under attack |
| Pool deletion at scale is slow to vault if done per object | Open question; measure, and consider a collection-level move |
| The 24-week schedule is tight for OSD-level work | Three-week time box on feasibility; cut list; December 2027 graduation as a fallback |

**Open questions.**

1. Can BlueStore move an entire PG collection into the vault as one metadata operation, or does it require per-object moves? PG split and merge already move objects between collections through `split_collection` and `merge_collection`; they are the first place to look.
2. How should vault entries be named so the same object deleted many times within a window is retained correctly for each version?
3. Should the retaining replica be chosen per object, per PG, or per OSD, given that acting sets change during recovery?
4. What is the right fail-closed behavior for pool deletion, which is a single command affecting many PGs?

---

## Appendix A — Relation to the original plan

This proposal follows the plan Lipeng Wan shared in September 2026, with these changes: the threat model now excludes orchestrator access explicitly; retention reuses BlueStore's snapshot clone machinery rather than adding new reference-counting code, so zero-copy is an implementation choice rather than a contribution; PG-level destruction paths (pool deletion, size reduction, stray removal) are in scope; overwrites are a stretch goal; a capacity-exhaustion policy is specified; erasure-coded pools are out of scope; and the schedule is compressed from twelve months to about twenty-four weeks, with a three-week feasibility gate first.

## Appendix B — Relation to prior work in this dissertation

JANUS made cross-facility data movement resilient to loss. CephMaestro showed that an LLM agent can operate a Ceph cluster, which also means an agent can destroy one. ReplicaVault bounds the damage any holder of Ceph credentials — attacker, operator, or agent — can do irreversibly. It also follows three pre-registered pilots on DiskANN ideas (DuraVec, CorrGuard, CephVec), each stopped within days on clear evidence; their common finding, that Vamana graphs have no structurally special regions to exploit, is why this paper moved from index structure to storage-system mechanism.

## Appendix C — Changes in revision 2

The pilot now opens with a two-day check, from source, of whether BlueStore can move or clone an object into a collection outside its PG without copying (§6, step 1), and the design states what follows if it cannot (§4.2). The scenario suite adds OSD restart with vault data on disk, pg_num split and merge, and deletion of objects with snapshot clones. The gate adds a pass-with-revised-hypotheses outcome for a copying vault. The primitive check is scheduled to finish before the proposal defense, and the prior-art close-out is marked as not deferrable.
