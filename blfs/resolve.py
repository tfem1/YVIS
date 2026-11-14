#!/usr/bin/env python3
"""Resolve what BLFS packages a set of targets needs, in build order.

    python3 -I blfs/resolve.py --book URL_OR_DIR --choices blfs/choices \\
        --targets blfs/targets [--cache DIR] [page ...] > order.tsv

A target is a book page relative to the book's root, such as
``kde/plasma-all.html``. Every page is read once (and kept in --cache), its
"Required" and "Recommended" dependencies are followed, and the result is
printed in an order where each package comes after what it needs:

    page  version  tarball-url  md5  deps(comma separated)

Optional dependencies are not followed: YVIS adds the ones it wants through
blfs/choices, which also removes recommendations it does not want and breaks
the circular dependencies the book resolves by building a package twice.
Packages of the LFS book itself are already in the base system and are left
out. Only the Python standard library is used.
"""

import argparse
import html.parser
import os
import re
import sys
import time
import urllib.parse
import urllib.request

KINDS = ("required", "recommended")


class Page(html.parser.HTMLParser):
    """The version, download and dependencies of one BLFS page."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title = ""
        self.md5 = None
        self.deps = {k: [] for k in KINDS}
        self._h = None          # heading being read
        self._htext = []
        self._section = ""      # text of the current h3
        self._kind = None       # Required / Recommended / Optional / Runtime
        self._p_kind = None     # inside <p class="required|recommended">
        self._li = 0            # inside a list item of the dependency list
        self._paren = 0         # links inside "(required for ...)" are not dependencies
        self._admon = 0         # inside a note: links are not dependencies
        self._depth = 0
        self._text = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = (a.get("class") or "").split()
        if tag in ("h1", "h2", "h3", "h4"):
            self._h, self._htext = tag, []
            return
        if tag == "div" and "admon" in cls:
            self._admon += 1
        elif tag == "div" and self._admon:
            self._admon += 1
        if tag == "p" and cls and cls[0] in KINDS + ("optional",):
            self._p_kind = cls[0]
            self._paren = 0
        if tag == "li" and self._kind in KINDS:
            self._li += 1
            self._paren = 0
        if tag == "a" and a.get("class") == "xref" and not self._admon:
            href = a.get("href", "")
            if self._kind in KINDS and self._paren == 0 and (self._p_kind == self._kind or self._li):
                self.deps[self._kind].append(href)

    def handle_endtag(self, tag):
        if tag == self._h:
            text = " ".join("".join(self._htext).split())
            if tag == "h1":
                self.title = text
            elif tag in ("h2", "h3"):
                if text != "Note" and text != "Important" and text != "Warning":
                    self._section = text.lower()
                    self._kind = None
            elif tag == "h4":
                k = text.lower()
                self._kind = k if k in KINDS else "other"
            self._h = None
        elif tag == "p":
            self._p_kind = None
        elif tag == "li" and self._li:
            self._li -= 1
        elif tag == "div" and self._admon:
            self._admon -= 1

    def handle_data(self, data):
        if self._h:
            self._htext.append(data)
        if self._li or self._p_kind:
            self._paren = max(0, self._paren + data.count("(") - data.count(")"))
        if "package information" in self._section:
            m = re.search(r"Download MD5 sum:\s*([0-9a-f]{32})", " ".join(data.split()))
            if m and self.md5 is None:
                self.md5 = m.group(1)


class Download(html.parser.HTMLParser):
    """The first "Download (HTTP)" link of the page."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.url = None
        self._armed = False

    def handle_data(self, data):
        if "Download (HTTP)" in data and self.url is None:
            self._armed = True

    def handle_starttag(self, tag, attrs):
        if tag == "a" and self._armed and self.url is None:
            self.url = dict(attrs).get("href")
            self._armed = False


def read(base, rel, cache):
    path = os.path.join(cache, rel) if cache else None
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return f.read()
    if re.match(r"https?://", base):
        url = urllib.parse.urljoin(base.rstrip("/") + "/", rel)
        req = urllib.request.Request(url, headers={"User-Agent": "yvis-blfs-resolve"})
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    text = r.read().decode("utf-8", "replace")
                break
            except OSError:
                if attempt == 4:
                    raise
                time.sleep(2 ** attempt)
    else:
        with open(os.path.join(base, rel), encoding="utf-8") as f:
            text = f.read()
    if path:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
    return text


def page_id(current, href):
    """A dependency link as a page id ("x/mesa.html", or with "#anchor" for
    one module of a page that holds several), or None for links that do not
    name a BLFS package (the LFS book, other sites)."""
    if href.startswith(("http:", "https:", "mailto:")):
        return None
    joined = os.path.normpath(os.path.join(os.path.dirname(current), href.split("#")[0] or os.path.basename(current)))
    if joined.startswith(".."):
        return None
    anchor = href.split("#", 1)[1] if "#" in href else ""
    return joined + ("#" + anchor if anchor else "")


def load_choices(path):
    """blfs/choices: per package, dependencies to drop or add.

        x/mesa.html  -general/llvm.html        # drop a recommendation
        x/mesa.html  +general/libdisplay-info.html   # add an optional one
        *            -general/doxygen.html     # drop everywhere
    """
    drop, add = {}, {}
    if not path:
        return drop, add
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0] if " #" in line or line.startswith("#") else line
            words = line.split()
            if not words:
                continue
            pkg, *changes = words
            for c in changes:
                (drop if c[0] == "-" else add).setdefault(pkg, set()).add(c[1:])
    return drop, add


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--book", required=True)
    ap.add_argument("--cache")
    ap.add_argument("--choices")
    ap.add_argument("--targets", help="file of target pages, one per line (# comments)")
    ap.add_argument("pages", nargs="*", help="target pages")
    args = ap.parse_args()
    targets = list(args.pages)
    if args.targets:
        with open(args.targets) as f:
            targets += [line.split("#")[0].strip() for line in f if line.split("#")[0].strip()]
    if not targets:
        ap.error("no target page")
    drop, add = load_choices(args.choices)

    info = {}

    def parse(pid):
        if pid in info:
            return info[pid]
        rel = pid.split("#")[0]
        text = read(args.book, rel, args.cache)
        p = Page()
        p.feed(text)
        d = Download()
        d.feed(text)
        deps = []
        for kind in KINDS:
            for href in p.deps[kind]:
                dep = page_id(rel, href)
                if dep and dep.split("#")[0] != rel and dep not in deps:
                    deps.append(dep)
        removed = drop.get(pid, set()) | drop.get("*", set())
        deps = [x for x in deps if x not in removed and x.split("#")[0] not in removed]
        deps += sorted(add.get(pid, set()) - set(deps))
        version = re.sub(r"^.*?-(?=\d)", "", p.title) if re.search(r"-\d", p.title) else ""
        info[pid] = dict(title=p.title, version=version, url=d.url or "-", md5=p.md5 or "-", deps=deps)
        return info[pid]

    order, state, cycles = [], {}, []

    def visit(pid, stack):
        if state.get(pid) == "done":
            return
        if state.get(pid) == "active":
            cycles.append(stack[stack.index(pid):] + [pid])
            return
        state[pid] = "active"
        for dep in parse(pid)["deps"]:
            visit(dep, stack + [pid])
        state[pid] = "done"
        order.append(pid)

    for t in targets:
        visit(t, [])

    print("# page\tversion\ttarball-url\tmd5\tdeps")
    for pid in order:
        i = info[pid]
        print(f"{pid}\t{i['version'] or '-'}\t{i['url']}\t{i['md5']}\t{','.join(i['deps']) or '-'}")
    for c in cycles:
        print("cycle: " + " -> ".join(c), file=sys.stderr)
    print(f"{len(order)} packages, {len(cycles)} cycles", file=sys.stderr)


if __name__ == "__main__":
    main()
