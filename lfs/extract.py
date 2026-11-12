#!/usr/bin/env python3
"""Extract the build commands of the LFS book into reviewable shell scripts.

    python3 lfs/extract.py --book URL_OR_DIR --sources wget-list --out lfs/book

Like the LFS project's own jhalfs, this reads every ``<pre class="userinput">``
block of chapters 5 to 8 in book order. One script is written per section,
``<out>/chNN/NNN-<section-id>.sh``, plus ``<out>/sections.tsv``:

    chapter  order  section-id  tarball-or-dash  title

Blocks that run test suites or need a human (exec, passwd, tzselect, entering
the chroot...) are kept in the script but commented out with the reason, so a
review shows exactly what the build does and does not run. Blocks with
``<replaceable>`` placeholders are commented out too: YVIS supplies those
values in lfs/overrides/.

Only the Python standard library is used: the script also runs inside a
freshly built LFS system.
"""

import argparse
import html.parser
import os
import re
import sys
import urllib.parse
import urllib.request

CHAPTERS = ("chapter05", "chapter06", "chapter07", "chapter08")

# Test suites: skipped in CI builds (they would multiply the build time) and
# run separately by a dedicated job later.
TEST = re.compile(
    r"""(
        \bmake\b[^\n;&|]*?\s(-k\s+)?(check|test|tests|test-all)\b
      | \bninja\b[^\n;&|]*\stest\b
      | \bmeson\s+test\b
      | \bchown\s+-R\s+tester\b
      | \bsu\s+tester\b
      | \brunuser\b
      | test_summary
      | \bpytest\b
      | \btestsuite\b
      | ^\s*grep\b.*\.(sum|log)\b
    )""",
    re.X | re.M,
)

# Commands that only make sense for a person typing them.
INTERACTIVE = re.compile(
    r"""^\s*(
        exec\s
      | logout\b
      | exit\b
      | passwd\b
      | tzselect\b
      | chroot\s
      | su\s+-\s
    )""",
    re.X | re.M,
)


class Page(html.parser.HTMLParser):
    """Collect the section id, title and command blocks of one book page."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.sid = None
        self.title = ""
        self.blocks = []  # (text, has_replaceable)
        self._in_h1 = False
        self._in_pre = 0
        self._buf = []
        self._repl = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "h1" and "sect1" in (a.get("class") or ""):
            self._in_h1 = True
        elif tag == "a" and self._in_h1 and self.sid is None and a.get("id"):
            self.sid = a["id"]
        elif tag == "pre" and "userinput" in (a.get("class") or "").split():
            self._in_pre = 1
            self._buf = []
            self._repl = False
        elif self._in_pre:
            if tag == "pre":
                self._in_pre += 1
            if "replaceable" in (a.get("class") or "").split():
                self._repl = True

    def handle_endtag(self, tag):
        if tag == "h1":
            self._in_h1 = False
        elif tag == "pre" and self._in_pre:
            self._in_pre -= 1
            if self._in_pre == 0:
                self.blocks.append(("".join(self._buf).strip("\n"), self._repl))

    def handle_data(self, data):
        if self._in_h1:
            self.title += data
        if self._in_pre:
            self._buf.append(data)


class Links(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hrefs = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            h = dict(attrs).get("href")
            if h:
                self.hrefs.append(h)


def read(base, rel):
    """Read a page from a URL base or a local mirror directory."""
    if re.match(r"https?://", base):
        url = urllib.parse.urljoin(base.rstrip("/") + "/", rel)
        req = urllib.request.Request(url, headers={"User-Agent": "yvis-lfs-extract"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read().decode("utf-8"), url
    path = os.path.join(base, rel)
    with open(path, encoding="utf-8") as f:
        return f.read(), path


def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def find_tarball(title, tarballs):
    """Map a section title such as 'Libstdc++ from GCC-16.2.0' to its tarball."""
    for tok in re.findall(r"[A-Za-z][\w+.-]*?-\d[\w.]*", title):
        n = norm(tok)
        hits = [t for t in tarballs if norm(t).startswith(n)]
        if hits:
            # the shortest name wins: tcl8.6.18-src before tcl8.6.18-html
            return min(hits, key=len)
    return None


def classify(text, replaceable):
    if replaceable:
        return "needs a value from lfs/overrides"
    if INTERACTIVE.search(text):
        return "interactive"
    if TEST.search(text):
        return "test suite"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--book", required=True, help="book URL or local HTML directory")
    ap.add_argument("--sources", required=True, help="the book's wget-list")
    ap.add_argument("--out", required=True)
    o = ap.parse_args()

    with open(o.sources) as f:
        tarballs = [
            os.path.basename(urllib.parse.urlparse(l.strip()).path)
            for l in f
            if l.strip() and not l.strip().endswith(".patch")
        ]

    index, _ = read(o.book, "index.html")
    lp = Links()
    lp.feed(index)
    pages = []
    for h in lp.hrefs:
        rel = h.split("#")[0]
        rel = re.sub(r"^.*?(chapter\d\d/)", r"\1", rel)
        if rel.split("/")[0] in CHAPTERS and rel.endswith(".html") and rel not in pages:
            pages.append(rel)
    if not pages:
        sys.exit("no chapter pages found in the book index")

    rows = []
    for order, rel in enumerate(pages, 1):
        text, src = read(o.book, rel)
        p = Page()
        p.feed(text)
        if not p.blocks:
            continue
        chapter = rel.split("/")[0].replace("chapter", "ch")
        title = " ".join(p.title.split())
        sid = p.sid or os.path.splitext(os.path.basename(rel))[0]
        tb = find_tarball(title, tarballs)
        d = os.path.join(o.out, chapter)
        os.makedirs(d, exist_ok=True)
        lines = [
            "# Generated by lfs/extract.py -- do not edit; use lfs/overrides/.",
            f"# {title}",
            f"# source: {src}",
            f"# package: {tb or '-'}",
        ]
        for i, (block, repl) in enumerate(p.blocks, 1):
            why = classify(block, repl)
            lines.append("")
            if why:
                lines.append(f"# --- block {i}: SKIPPED ({why})")
                lines += ["# " + l if l else "#" for l in block.split("\n")]
            else:
                lines.append(f"# --- block {i}")
                lines.append(block)
        name = os.path.join(d, f"{order:03d}-{sid}.sh")
        with open(name, "w") as f:
            f.write("\n".join(lines) + "\n")
        rows.append((chapter, f"{order:03d}", sid, tb or "-", title))

    with open(os.path.join(o.out, "sections.tsv"), "w") as f:
        f.write("# chapter\torder\tsection\ttarball\ttitle\n")
        for r in rows:
            f.write("\t".join(r) + "\n")
    print(f"{len(rows)} sections with commands written to {o.out}")


if __name__ == "__main__":
    main()
