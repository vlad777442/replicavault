# ReplicaVault zero-copy vault pilot — pre-registered criteria

- Date: 2026-10-03
- Base commit: `05289b51c83c54c095a92b4c249373c8fb22e47f` (Ceph branch `replicavault-p2`, F1). Zero-copy work is on branch `replicavault-zc`, created from it.
- Source: `CLAUDE.md` (zero-copy pilot), Phase 0. The fsck rule was changed by Vlad before commit (2026-10-03): deep fsck after every run only for z01 and z06; elsewhere, a regular fsck after every run plus one deep fsck per scenario batch. The disk scan with checksums still runs after every run. This file is frozen after its first commit.

```
Zero-copy pilot gate

Pass if all of the following hold on the zero-copy build:
- the new BlueStore unit tests and the existing ceph_test_objectstore suite
  (BlueStore instance) pass;
- the allocation-rebuild test (z01) shows zero corrupted or missing vault
  entries and a clean deep fsck in every run (at least 30 runs);
- the full scenario suite (smoke, s01-s12, a01-a05, c01 x30, c03 x10, c04 A/B x10)
  passes with disk-scan checks after every run, a clean regular fsck after every
  run, and a clean deep fsck once per scenario batch;
- z02-z05 and the soak test (z06) pass, with a clean deep fsck after every z06
  run (and every z01 run, above);
- for unshared objects, bytes written to the device per vaulted delete are
  independent of object size (metadata only).

Fail if any data corruption or fsck error cannot be explained and fixed within
the time box; if the change requires an on-disk format change; or if the gate is
not passing within three working days of the end of Phase 1.

Fallback on fail: keep the copying vault and proceed with the off-path copy
(proposal section 4.8).
```
