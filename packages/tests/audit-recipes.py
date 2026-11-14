#!/usr/bin/env python3
"""List the commands of generated recipes that still name an absolute path
outside $PKGDIR (outside quotes and heredocs). Symlink targets of `ln -s`
are expected; anything else is a write to the build machine.

    packages/tests/audit-recipes.py <recipes dir>      exit 1 if any
"""
import os
import re
import sys

HEREDOC = re.compile(r"""<<-?\s*(['"]?)(\w+)\1""")
ABS = re.compile(r"(?:^|[\s>=])(/(?:usr|etc|var|lib|lib64|bin|sbin|opt|boot|run|tmp|root|home|srv|media|mnt)\b[^\s;)]*)")


def findings(path):
    body = open(path).read().split("\n@package\n", 1)[1]
    here = None
    for line in body.split("\n"):
        if here:
            if line.strip() == here:
                here = None
            continue
        m = HEREDOC.search(line)
        if m:
            here = m.group(2)
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        t = s.replace('"$PKGDIR"', "PKG").replace('"$PKGDIR/', '"PKG/')
        t = re.sub(r"'[^']*'", "''", t)
        t = re.sub(r'"[^"]*"', '""', t)
        words = t.split()
        # ln -s TARGET LINK: the target is a path on the installed system
        if words[:1] == ["ln"] and any(re.match(r"-\w*s", w) for w in words[1:]) \
                and not any(re.match(r"-\w*r", w) for w in words[1:]):
            args = [w for w in words[1:] if not w.startswith("-")]
            t = " ".join(["ln"] + args[1:])
        # configure-style options name the installed system's paths
        t = re.sub(r"(?:^|\s)-{1,2}[\w-]+=\S+", " ", t)
        t = re.sub(r"(?:^|\s)\w+=/\S+", " ", t)
        for hit in ABS.findall(t):
            yield hit, s


def main():
    root = sys.argv[1]
    bad = 0
    for name in open(os.path.join(root, "order")).read().split():
        for hit, line in findings(os.path.join(root, name, "YONEBUILD")):
            print(f"{name:16s} {hit:40s} {line[:110]}")
            bad += 1
    print(f"{bad} unprefixed absolute path(s)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
