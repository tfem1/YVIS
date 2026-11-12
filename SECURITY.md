# Security

## Reporting

Please report vulnerabilities privately through GitHub's
"Report a vulnerability" (Security tab) rather than a public issue.

## Package trust model

- Repository indexes are signed with ed25519; Yone refuses unsigned or
  wrongly-signed indexes when `siglevel = required` (the default).
- Each index pins the SHA-256 and size of every package; a package whose hash
  differs is deleted from the cache and refused.
- Package metadata must match the signed index entry (no package swapping),
  and its architecture must match the system (or be `any`).
- Each index carries a signed `generated` timestamp; `yone update` refuses an
  index older than the one already trusted (replay / freeze attacks by a
  stale or hostile mirror).
- Downloads are size-capped (index size for packages, 256 MiB otherwise).
- Archive paths are validated (no absolute paths, `..`, or control
  characters) and every parent directory is checked to stay inside the
  installation root (no symlink escape); hard-link sources too.
- Temporary files are created with `O_EXCL` (a planted symlink is never
  followed), including OpenSSL scratch files in the shared temp directory.
- Release signing keys are never stored in the repository. CI signs with a key
  held in GitHub encrypted secrets, only on protected tags.

Signatures, checksums, replay protection, path and symlink escapes, rollback
and crash recovery are exercised by `yone/tests/e2e.sh`; the architecture
check, download caps and `O_EXCL` scratch files are not covered by tests yet.
