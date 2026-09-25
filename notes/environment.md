# Environment inventory (Phase 0)

Host: `node5-link-1` (CloudLab; 10.10.1.6, public 155.98.36.138). Surveyed 2026-09-25.

## Host

| Item | Value |
|---|---|
| OS | Ubuntu 24.04, kernel 6.8.0-138-generic |
| Cores / RAM | 32 cores, 62 GiB RAM, 8 GiB swap |
| Disk | `/` (sda3) 63 GiB (54 GiB free). `/dev/sdb` 932 GiB XFS, label `rvdata`, mounted at `/data` (fstab, `nofail`). Formatted for the pilot on 2026-09-25 with Vlad's OK. `/dev/sdc` untouched. |
| Toolchain | g++ 13.3.0, cmake 3.28.3, ninja, Python 3.12.3 |

## Ceph source and build

| Item | Value |
|---|---|
| Source | `/data/ceph`, cloned `--depth 1` at tag `v19.2.3` |
| Commit | `c92aebb279828e9c3c1f5d24613efca272649e62` (same as installed `ceph-common` 19.2.3) |
| Branch | `replicavault-pilot` |
| Build dir | `/data/ceph/build` (Ninja) |
| Build type | `Debug` |
| cmake flags | `./do_cmake.sh -DCMAKE_BUILD_TYPE=Debug -DWITH_PYTHON3=3.12 -DWITH_RADOSGW=OFF -DWITH_MGR_DASHBOARD_FRONTEND=OFF -DWITH_TESTS=OFF -DWITH_MANPAGE=OFF -DWITH_SPDK=OFF -G Ninja`. `-DWITH_PYTHON3=3.12` is needed because `do_cmake.sh` picks 3.10 on this OS. |
| Build command | `ninja -j 28 vstart-base ceph-objectstore-tool` (log: `/data/build.log`) |
| Dependencies | `sudo ./install-deps.sh` (log: `/data/install-deps.log`), exit 0 |
| Full build time | TBD |
| Incremental `ceph-osd` rebuild | TBD |

## Other cluster on the network (do not touch)

`/etc/ceph/ceph.conf` on this host points to a separate cephadm cluster: fsid `e9577c99-b822-11f1-8fa0-141877582589`, mon on `node0` (10.10.1.1). This is **not** the pilot cluster. Never run commands against it: no `sudo ceph`, no `ssh root@node0`, no `ceph orch`. Pilot scripts must always pass `-c /data/ceph/build/ceph.conf` explicitly, or run from `/data/ceph/build`.

## vstart cluster

Still to do once the build finishes: start command, MON/MGR/OSD counts, BlueStore confirmation, fsid, OSD kill/restart commands (verified), and the test pool.
