#!/usr/bin/env python3
"""Compare a system installed from packages with the reference system.

    packages/compare.py <reference> <installed> <report directory>

Every path is compared: present in both, type, mode, owner, link target and,
for regular files, content. A missing or extra path, or a different type,
mode, owner or link, is a difference in what the packages install (exit 1);
different content is reported but expected for some files (build paths in
binaries, caches, Python bytecode).
"""
import hashlib
import json
import os
import stat
import sys
from collections import Counter

# Not part of the comparison: build state, runtime and the kernel (not
# packaged yet).
EXCLUDE = (
    ".yvis", "sources", "packages", "target", "tmp/", "var/tmp/", "run/", "dev/",
    "proc/", "sys/", "boot/", "usr/lib/modules/", "var/lib/yone/", "var/cache/yone/",
    "var/log/yone.log", "etc/yone/", "usr/local/bin/yone", "root/.cache/",
    "var/log/journal/", "etc/machine-id",
)


def excluded(rel):
    return any(rel == e.rstrip("/") or rel.startswith(e if e.endswith("/") else e + "/") or rel == e
               for e in EXCLUDE)


def scan(top):
    out = {}
    for base, dirs, files in os.walk(top):
        rel_base = os.path.relpath(base, top)
        rel_base = "" if rel_base == "." else rel_base
        for name in sorted(dirs + files):
            rel = f"{rel_base}/{name}" if rel_base else name
            if excluded(rel) or excluded(rel + "/"):
                if name in dirs:
                    dirs.remove(name)
                continue
            p = os.path.join(base, name)
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                kind, extra = "link", os.readlink(p)
                if name in dirs:
                    dirs.remove(name)
            elif stat.S_ISDIR(st.st_mode):
                kind, extra = "dir", None
            elif stat.S_ISREG(st.st_mode):
                kind, extra = "file", st.st_size
            else:
                kind, extra = "other", None
            out[rel] = (kind, stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, extra, p)
    return out


def digest(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def group(paths, depth=3):
    c = Counter("/".join(p.split("/")[:depth]) for p in paths)
    return c.most_common()


def main():
    ref, new, report = sys.argv[1:4]
    os.makedirs(report, exist_ok=True)
    a, b = scan(ref), scan(new)
    missing = sorted(set(a) - set(b))
    extra = sorted(set(b) - set(a))
    kind, mode, owner, link, content = [], [], [], [], []
    for rel in sorted(set(a) & set(b)):
        x, y = a[rel], b[rel]
        if x[0] != y[0]:
            kind.append(f"{rel}: {x[0]} -> {y[0]}")
            continue
        if x[0] != "link" and x[1] != y[1]:
            mode.append(f"{rel}: {x[1]:o} -> {y[1]:o}")
        if (x[2], x[3]) != (y[2], y[3]):
            owner.append(f"{rel}: {x[2]}:{x[3]} -> {y[2]}:{y[3]}")
        if x[0] == "link" and x[4] != y[4]:
            link.append(f"{rel}: {x[4]} -> {y[4]}")
        if x[0] == "file" and (x[4] != y[4] or digest(x[5]) != digest(y[5])):
            content.append(rel)
    sections = [
        ("missing (in the reference, not installed by any package)", missing),
        ("extra (installed, not in the reference)", extra),
        ("type differs", kind), ("mode differs", mode), ("owner differs", owner),
        ("link target differs", link), ("content differs (informative)", content),
    ]
    summary = {"reference": len(a), "installed": len(b)}
    with open(os.path.join(report, "compare.txt"), "w") as f:
        for title, items in sections:
            summary[title.split(" (")[0]] = len(items)
            f.write(f"== {title}: {len(items)}\n")
            for item in items:
                f.write(f"  {item}\n")
            f.write("\n")
    with open(os.path.join(report, "compare.json"), "w") as f:
        json.dump(summary, f, indent=1)
    print(f"paths: reference {len(a)}, installed {len(b)}")
    for title, items in sections:
        print(f"  {len(items):6d}  {title}")
        if items and "informative" not in title:
            for g, n in group([i.split(":")[0] for i in items])[:12]:
                print(f"            {n:5d}  {g}")
    print(f"details: {report}/compare.txt")
    hard = missing or extra or kind or mode or owner or link
    sys.exit(1 if hard else 0)


if __name__ == "__main__":
    main()
