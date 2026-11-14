# GraveyardOS

A lightweight x86_64 Linux distribution built from source on
[Linux From Scratch](https://www.linuxfromscratch.org/), with its own package
manager, **Yone**, written in Rust.

> **Status: early development (pre-v0.1.0).** Nothing here is a usable
> operating system yet. See [ROADMAP.md](ROADMAP.md) for what exists and what
> does not. This README only states things that have been built and tested.

## What works today

| Component | State | Evidence |
|---|---|---|
| Yone package manager (`yone/`) | functional core | 8 unit tests + 42-check end-to-end suite (`yone/tests/e2e.sh`) |
| CI for Yone | written, not yet run on GitHub | `.github/workflows/yone.yml` |
| LFS toolchain build | not started | — |
| Bootable ISO | not started | — |

## Yone at a glance

```sh
sudo yone update            # update everything: fresh signed indexes, then every package
sudo yone install firefox   # resolve deps, download in parallel, install atomically
sudo yone remove firefox
yone search browser         # names and descriptions
yone list                   # every package of the repositories, [installed] marked
yone list --installed       # what is installed (--explicit, --deps)
yone info firefox
sudo yone autoremove        # orphaned dependencies
sudo yone verify            # SHA-256 of every installed file vs the database
sudo yone clean
sudo yone recover           # roll back a transaction interrupted by a crash
```

Packagers:

```sh
yone keygen ~/keys/graveyard                       # ed25519 key pair
yone build pkgs/zlib --sign ~/keys/graveyard.key   # YONEBUILD recipe -> zlib-1.3.1-1-x86_64.yon
yone repo-index ./repo --name core --sign ~/keys/graveyard.key
```

## Repository layout

```
yone/            Rust package manager (zero third-party crates)
  src/           sources
  tests/e2e.sh   end-to-end suite against a throw-away root
config/          default system configuration shipped by GraveyardOS
.github/         CI workflows
ARCHITECTURE.md  design decisions
ROADMAP.md       milestones and current status
BUILDING.md      how to build and test
SECURITY.md      trust model and how to report vulnerabilities
```

Directories for the LFS build, package recipes, installer, desktop
configuration and branding are added when their first working component lands,
not before.
