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
