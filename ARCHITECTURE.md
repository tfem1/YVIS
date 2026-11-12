# YVIS OS — Architecture

## 1. Principles

1. **Built from source, reproducibly.** Every binary package comes from a
   `YONEBUILD` recipe with pinned source checksums. Builds use a fixed
   `SOURCE_DATE_EPOCH`, sorted archive entries and normalised ownership, so the
   same recipe produces the same bytes (checked in the Yone e2e suite).
2. **Small trusted base.** Yone has no third-party Rust crates. It relies only
   on tools already in an LFS base system: OpenSSL (ed25519), xz/zstd, curl.
3. **Transparent like Arch, not a copy of it.** Plain-text metadata, one
   package manager, simple recipes. Yone is not pacman, APT or DNF.
4. **Nothing claimed without a test.** Features are documented as working only
   once a test exercises them.

## 2. System decisions

| Area | Decision | Reason |
|---|---|---|
| Base | LFS (systemd edition) + selected BLFS | Plasma, SDDM, logind, Flatpak portals and PipeWire integration all assume systemd |
| Init / session | systemd, systemd-logind | required by SDDM Wayland sessions and portals |
| Kernel | upstream LTS, YVIS config | AMDGPU built in, NVIDIA via out-of-tree module package |
| Boot (installed) | systemd-boot on UEFI | ships with systemd, simple, signable |
| Boot (ISO) | GRUB EFI image + El Torito, `xorriso` | UEFI x86_64 target; BIOS is a non-goal for v0.x |
| Root on ISO | SquashFS, zstd level 19, overlayfs for the live session | best size/speed trade-off for a 2 GiB budget |
| Graphics | Wayland only; Mesa (radeonsi, RADV); NVIDIA proprietary optional | per project brief |
| Desktops | KDE Plasma (default, on ISO); Hyprland, COSMIC installable via Yone | keeps the ISO under budget |
| Display manager | SDDM with an original YVIS theme | per project brief |
| Audio | PipeWire + WirePlumber | Plasma/Hyprland/COSMIC and Steam expect it |
| Apps | native Yone packages + Flatpak/Flathub | sandboxed third-party apps |
| Arch | x86_64 only | |

### ISO size budget (2 GiB hard limit)

These are **targets to be measured**, not results. The real size is reported by
the ISO workflow and the release is blocked if it exceeds 2 GiB.

| Part | Budget (compressed) |
|---|---|
| Kernel + initramfs + firmware subset | 250 MiB |
| LFS base + systemd + networking | 200 MiB |
| Mesa, Vulkan, Wayland, PipeWire | 150 MiB |
| KDE Plasma (minimal) + SDDM + Qt 6 | 700 MiB |
| Flatpak, portals, installer, branding | 100 MiB |
| Headroom | ~600 MiB |

Kept **off** the ISO and installed by the installer from the network:
Hyprland, COSMIC, gaming stack (Steam, Gamescope, MangoHud…), NVIDIA
proprietary driver.

## 3. Yone

### 3.1 Files on a system

```
/etc/yone/yone.conf          configuration (repos, channel, parallelism, siglevel)
/etc/yone/keys/*.pem         trusted ed25519 public keys
/var/lib/yone/sync/          verified repository indexes (+ .sig)
/var/lib/yone/local/<pkg>/   info (metadata + install reason), files (type, mode, sha256, path)
/var/lib/yone/journal        present only during a transaction
/var/lib/yone/local/.staged/ database changes waiting for the commit point
/var/lib/yone/db.lck         flock(2) lock (released by the kernel if yone dies)
/var/cache/yone/pkg/         downloaded packages (offline installs reuse them)
```

### 3.2 Package format (`.yon`)

A tar stream compressed with zstd (default) or xz. The first entry is
`.YONEINFO` (`key = value` metadata: name, version `ver-rel`, depends,
provides, conflicts, backup, isize…). Everything else is the file tree relative
to `/`. Ownership is always root:root.

### 3.3 Trust chain

```
trusted key (/etc/yone/keys) ──verifies──▶ <repo>.index.sig
<repo>.index header `generated` ──must not go back in time──▶ previously trusted index
<repo>.index (signed) ──contains sha256 + csize──▶ every package of the repo
package .YONEINFO name/version ──must equal──▶ index entry
```

A signature is ed25519 over the statement
`yone-signature-v1\n<sha256>  <filename>\n`, which binds the file name and
keeps signing constant-memory for large packages. Local `.yon` files must carry
their own `.sig` unless `--allow-unsigned` is given.

### 3.4 Transactions

`install` / `upgrade`:

1. lock → resolve dependencies (versioned deps, `provides`, cycles tolerated) →
   check that the *final* system has every dependency met and no conflict;
2. parallel download into the cache (mirrors tried in order) with an
   aggregated progress line (speed, ETA);
3. SHA-256 of every package against the signed index;
4. list every archive, validate paths (no absolute paths, no `..`, no control
   characters), detect file conflicts with other packages and unowned files;
5. extract under a write-ahead journal: each file is written to
   `<path>.yone-new`, the old file is moved to `<path>.yone-old`, then the new
   one is renamed into place. Parent directories are canonicalised and must stay
   inside the root, which blocks symlink-escape tricks;
6. on any error the journal is replayed backwards and the filesystem returns to
   its exact prior state;
7. commit point: the new database entries are staged in `local/.staged`, files
   and directories the new versions dropped are journaled (`S`), the
   filesystem is flushed (`syncfs`) and `C` is written to the journal;
8. after the commit point: publish the staged database, delete `.yone-old`
   backups and the dropped files, run triggers (`ldconfig`).

After a crash, `yone recover` reads the journal: without `C` it rolls back
(step 6), with `C` it rolls forward (step 8). Both are idempotent, so files
and database always agree whenever the machine died. The e2e suite kills
yone on both sides of the commit point (`YONE_TEST_CRASH`, debug builds).

Configuration files listed in `backup` are never overwritten when the
administrator changed them: the new version lands as `<file>.yonenew`; on
removal a modified one is kept as `<file>.yonesave`.

`--root DIR` makes every operation work on another tree; it is how the build
system populates the root filesystem of the ISO.

### 3.5 Recipes (`YONEBUILD`)

```
name = zlib
version = 1.3.1
release = 1
depends = glibc
source = https://zlib.net/zlib-1.3.1.tar.xz
sha256 = <64 hex>
@build
cd zlib-$PKGVER && ./configure --prefix=/usr && make
@package
cd zlib-$PKGVER && make DESTDIR="$PKGDIR" install
```

Every downloaded source needs a checksum (`SKIP` is only accepted for files
shipped next to the recipe). Scripts run with `bash -eo pipefail` and get
`SRCDIR`, `PKGDIR`, `PKGNAME`, `PKGVER`, `SOURCE_DATE_EPOCH`, `MAKEFLAGS`.

### 3.6 Known limitations (v0.1)

- No package-provided install scripts yet; only built-in triggers.
- File data is flushed once per transaction (`syncfs` before the commit
  point), not per file: a power cut *before* the commit point is rolled back,
  so a half-written new file is never kept, but an original renamed aside
  shortly before the cut may itself not have reached the disk yet on
  filesystems without rename ordering guarantees.
- Network downloads depend on the system `curl`.
- Builds run as the invoking user without isolation; a sandboxed build
  (namespaces/chroot) is planned before public repositories open.

## 4. Release channels

`dev` → `testing` → `stable`, selected with `channel =` in `yone.conf` and
mapped onto repository URLs (`$channel`). Each channel has its own index
signed by the release key.
