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

YVIS-specific choices live outside the generated files:

| File | Purpose |
|---|---|
| `lfs/values` | values for the book's placeholders (timezone UTC, paper size A4) |
| `lfs/skip` | sections or single blocks that are never run |
| `lfs/edits` | `sed` edits of a section's commands; an edit that no longer matches stops the build |
| `lfs/tests-enabled` | the test suites that are run (GMP, MPFR, MPC) |
| `lfs/overrides/<section>.sh`, `.post` | replacement commands, or commands run after the book's |

### How a section runs

Like the tools that build packages for a living (jhalfs, Debian's sbuild,
Arch's makechrootpkg), a section runs **detached from the terminal**: in its
own session with no controlling terminal, stdin on `/dev/null`, all output
in `$LFS/.yvis/logs/<section>.log`. The console shows one line per section
and the end of the log if it fails; the logs are uploaded as the
`lfs-system-logs` artifact. A section that does not end within
`YVIS_SECTION_TIMEOUT` (60 minutes) is killed and fails the build.

An unattended build must never wait for a person. The book is written for
a reader at a keyboard and a few of its commands are interactive
(`passwd root`, `tzselect`, `vim -c ':options'`): `lfs/extract.py` comments
them out, and the timeout turns any that slips through into a failure with
its log instead of a job that hangs for hours.

### A system for other machines

The book builds a system for the machine it is built on. YVIS is built in
CI and installed elsewhere, so the cases the book flags for that
(section 8.2.3) are applied through `lfs/edits`: GMP is configured with
`--host=none-linux-gnu` and Libffi with `--with-gcc-arch=x86-64`. Without
them both libraries use the build machine's CPU extensions and die with
"Illegal instruction" on older processors. The baseline is plain x86-64.

### Verification

`sudo lfs/build.sh verify` (last step of the `lfs` workflow, or the
`lfs-verify` workflow on the artifact of an earlier run) checks that every
section of the book was built, then runs `lfs/verify.sh` inside the system:

- the toolchain sanity checks the book asks the reader to compare by eye at
  the end of the GCC section (interpreter, start files, header and linker
  search paths, libc, dynamic linker);
- nothing left of the temporary toolchain;
- no program or library with a missing shared library;
- the main programs start, Python can load its C modules;
- GMP, MPFR, MPC and Libffi contain no instruction beyond the x86-64
  baseline;
- owners and modes that must survive the archive handed between CI jobs
  (stored with numeric ids, xattrs and ACLs).

Not covered yet: the long test suites the book calls critical (Glibc,
Binutils, GCC). They take hours and have known failures to compare against
the book's list, so they belong to a separate verification run (ROADMAP).

The `lfs-debug` workflow reruns one section on a saved `$LFS` the old way
(on sudo's terminal) under `strace` and reports what stopped; it exists to
confirm the cause of a hang, not to build.

Local checks (root, no network):

```bash
python3 -m unittest discover -s lfs/tests
sudo YVIS_LFS_NO_APT=1 bash lfs/tests/build-runner.sh
sh tools/tests/gpu-detect.sh
```
