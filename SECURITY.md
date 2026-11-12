# Security

## Reporting

Please report vulnerabilities privately through GitHub's
"Report a vulnerability" (Security tab) rather than a public issue.

## Package trust model

- Repository indexes are signed with ed25519; Yone refuses unsigned or
  wrongly-signed indexes when `siglevel = required` (the default).
- Each index pins the SHA-256 and size of every package; a package whose hash
  differs is deleted from the cache and refused.
- Package metadata must match the signed index entry (no package swapping).
- Archive paths are validated (no absolute paths, `..`, or control
  characters) and every parent directory is checked to stay inside the
  installation root (no symlink escape).
- Release signing keys are never stored in the repository. CI signs with a key
  held in GitHub encrypted secrets, only on protected tags.

All of the above is covered by `yone/tests/e2e.sh`.
