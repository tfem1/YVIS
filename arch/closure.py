#!/usr/bin/env python3
"""What a set of Arch Linux packages needs: the dependency closure, from the
archlinux.org package API (runtime dependencies, and with --make the build
dependencies too), minus what the GraveyardOS base already has.

    python3 arch/closure.py [--make] [--cache DIR] [--base FILE] target ...

A target is a package name or @group (e.g. @plasma). Prints one package
base per line in build order (dependencies first), then a summary.
"""
import argparse, json, os, re, sys, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

API = "https://archlinux.org/packages/search/json/?"

def get(url, cache):
    key = os.path.join(cache, re.sub(r"[^A-Za-z0-9._-]", "_", url)[-200:])
    if os.path.exists(key):
        return open(key).read()
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "graveyardos-closure"})
            with urllib.request.urlopen(req, timeout=60) as r:
                text = r.read().decode()
            break
        except OSError:
            time.sleep(2 ** attempt)
    else:
        raise SystemExit(f"cannot fetch {url}")
    open(key, "w").write(text)
    return text

def bare(dep):
    return re.split(r"[<>=]", dep, 1)[0]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--make", action="store_true")
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/graveyard-arch"))
    ap.add_argument("--base", help="file: Arch names the base provides, one per line")
    ap.add_argument("targets", nargs="+")
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)
    base = set()
    if a.base:
        base = {l.split("#")[0].strip() for l in open(a.base) if l.split("#")[0].strip()}

    by_name, provides = {}, {}

    def lookup(name):
        if name in by_name:
            return by_name[name]
        d = json.loads(get(API + urllib.parse.urlencode({"name": name, "arch": ["x86_64", "any"]}, doseq=True), a.cache))
        res = [r for r in d["results"] if r["repo"] in ("core", "extra")]
        by_name[name] = res[0] if res else None
        return by_name[name]

    def group(g):
        out, page = [], 1
        while True:
            d = json.loads(get(API + urllib.parse.urlencode({"q": "", "repo": ["Core", "Extra"], "arch": "x86_64", "page": page}, doseq=True) + f"&groups={g}", a.cache))
            out += [r["pkgname"] for r in d["results"] if g in r.get("groups", [])]
            if page >= d.get("num_pages", 1):
                return out
            page += 1

    todo = []
    for t in a.targets:
        todo += group(t[1:]) if t.startswith("@") else [t]
    seen, unresolved, order = set(), set(), []
    while todo:
        batch = [n for n in dict.fromkeys(todo) if n not in seen and n not in base]
        todo = []
        seen.update(batch)
        with ThreadPoolExecutor(8) as ex:
            found = list(ex.map(lookup, batch))
        for n, r in zip(batch, found):
            if not r:
                unresolved.add(n)
                continue
            order.append(r)
            deps = r["depends"] + (r["makedepends"] if a.make else [])
            todo += [bare(x) for x in deps if bare(x) not in base]
    bases = {}
    for r in order:
        bases.setdefault(r["pkgbase"], []).append(r["pkgname"])
    for b, names in sorted(bases.items()):
        print(b + ("" if names == [b] else "\t" + " ".join(sorted(names))))
    size = sum(r["installed_size"] for r in order)
    print(f"# {len(order)} packages from {len(bases)} package bases, {size/2**30:.1f} GiB installed; "
          f"{len(unresolved)} names not found as packages (virtual: provided by another): "
          + " ".join(sorted(unresolved))[:600], file=sys.stderr)

if __name__ == "__main__":
    main()
