# Building

## Yone

Requirements: Rust ≥ 1.75 (no crates are downloaded), and at runtime
`openssl`, `xz` and/or `zstd`, `tar`, `curl`.

```sh
cd yone
cargo build --release          # target/release/yone
cargo test                     # unit tests
cargo build && ./tests/e2e.sh  # end-to-end suite (needs a debug build)
YONE_TEST_COMPRESSION=zstd ./tests/e2e.sh
```

The e2e suite builds real signed packages, publishes a signed repository over
`file://` and runs install, upgrade, conflict detection, fault-injected
rollback, removal, verification, tampering and path-escape tests inside a
temporary root. It never touches the host system.

Fault injection (`YONE_TEST_FAIL_AFTER=N`) exists only in debug builds.

## The distribution

The LFS/ISO build runs in GitHub Actions; nothing has to be built locally.
Those workflows are added in milestone 5 (see ROADMAP.md).

## LFS base system

The base system follows LFS 13.1-systemd (pinned in `lfs/config`), using the
book's own commands rather than a rewrite of them:

1. `lfs-book` workflow (manual): `lfs/extract.py` reads the book and writes
   one script per section to `lfs/book/` (test suites, interactive commands
   and placeholders stay visible but commented out, with the reason);
   `lfs/fetch-sources.sh` downloads every source, checks the book's MD5 and
   records SHA-256s. The result is pushed to the branch
   `lfs-book/<version>`, reviewed, then merged.
2. `lfs` workflow (manual): `lfs/build.sh` runs chapters 5-7 (job
   `toolchain`) then chapter 8 (job `system`), each section in the context
   the book expects (user `lfs`, root on the host, or the chroot).

YVIS-specific choices live outside the generated files: `lfs/values`
(timezone UTC, paper size A4), `lfs/skip`, `lfs/overrides/<section>.sh`.

Local checks (root, no network):

```bash
python3 -m unittest discover -s lfs/tests
sudo YVIS_LFS_NO_APT=1 bash lfs/tests/build-runner.sh
sh tools/tests/gpu-detect.sh
```
