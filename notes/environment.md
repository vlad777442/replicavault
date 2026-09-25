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
| Full build time | 10 min 9 s wall (`ninja -j 28 vstart-base ceph-objectstore-tool`), plus `ceph-bluestore-tool` built separately |
| Incremental `ceph-osd` rebuild | 59 s after touching `src/osd/ReplicatedBackend.cc` (`ninja -j 28 ceph-osd`) |
| Untracked build artifact | `src/qatzip` (created by the `qatlib_ext` build step). Harmless; don't commit it. |

## Other cluster on the network (do not touch)

`/etc/ceph/ceph.conf` on this host points to a separate cephadm cluster: fsid `e9577c99-b822-11f1-8fa0-141877582589`, mon on `node0` (10.10.1.1). This is **not** the pilot cluster. Never run commands against it: no `sudo ceph`, no `ssh root@node0`, no `ceph orch`. Pilot scripts must always pass `-c /data/ceph/build/ceph.conf` explicitly, or run from `/data/ceph/build`.

## vstart cluster (the pilot cluster)

| Item | Value |
|---|---|
| **fsid** | **`224f2f2c-33fd-48ea-9d19-61f5c2df962f`**. Check this before every destructive command. |
| Started with | `cd /data/ceph/build && MON=1 MGR=1 OSD=5 MDS=0 RGW=0 NFS=0 ../src/vstart.sh --new -x --localhost --bluestore --without-dashboard` (log: `/data/vstart.log`) |
| Daemons | 1 MON (`a`), 1 MGR (`x`), 5 OSDs (`osd.0`–`osd.4`), all on host `node5`. No MDS or RGW. |
| Object store | BlueStore. `osd metadata 0`: `osd_objectstore=bluestore`. File-backed: `dev/osdN/block`, 100 GiB sparse, plus 1 GiB DB and 1 GiB WAL files. |
| CRUSH | `replicated_rule` = `take default; choose_firstn 0 type osd; emit`, so replicas go to distinct OSDs on the single host (`osd_crush_chooseleaf_type = 0`). |
| Config / keyring | `/data/ceph/build/ceph.conf`, `/data/ceph/build/keyring`. Always set `CEPH_CONF=/data/ceph/build/ceph.conf`. **Do not delete `/etc/ceph/ceph.conf`**, even though vstart warns about it: it belongs to the node0 cluster client. |
| Logs / pids | `out/osd.N.log`, `out/osd.N.pid` (under `/data/ceph/build`) |
| Test pool | `rvtest`, pool id 1: replicated, size 3, min_size 2, pg_num/pgp_num 32, `autoscale_mode off`, application `rados` |

### Bring-up problem (worked around)

`vstart.sh` failed `--mkfs` for osd.2 and osd.3: `handle_auth_bad_method ... failed to fetch mon config`, run right after `osd new`. That looks like a timing race; osd.4 hit the same message and succeeded. Their IDs and keys were already registered with the monitor. Fix: rerun the logged mkfs command with the same `--key`/`--osd-uuid`, write `dev/osdN/keyring` (`[osd.N]\n key = <secret>`), then start the OSD. After that all 5 OSDs were up and 32/32 PGs `active+clean`. If `vstart.sh --new` is ever rerun, check `ceph osd tree` for down OSDs.

### Kill / restart a single OSD (verified 2026-09-25)

```sh
cd /data/ceph/build; export CEPH_CONF=$PWD/ceph.conf
kill -9 $(cat out/osd.N.pid)          # crash-style kill; MON marks it down in ~2 s
bin/ceph-osd -i N -c ceph.conf        # restart; daemonizes, rewrites out/osd.N.pid
```

Test run: wrote 4 MiB object `probe` (acting `[1,3,0]`, PG 1.15), killed osd.1 (the primary) with SIGKILL, and restarted it. It was marked down after 2 s and all 32 PGs were `active+clean` 17 s after the kill. Read-back was byte-identical.

Stop the whole cluster: `../src/stop.sh`. Restart it without wiping: `../src/vstart.sh` without `--new`. Not yet exercised.
