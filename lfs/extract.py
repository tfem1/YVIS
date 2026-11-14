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
``<replaceable>`` placeholders are commented out too: GraveyardOS supplies those
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

# Classification looks at commands only: the first word of every simple
# command (after VAR=value prefixes), outside heredoc bodies. Matching option
# text would misfire (`--disable-runuser` is not `runuser`).
TEST_TARGETS = {"check", "test", "tests", "test-all", "check-root", "test_harness"}
INTERACTIVE_CMDS = {"exec", "logout", "exit", "passwd", "tzselect", "chroot"}
# Full-screen or prompting programs (the book shows `vim -c ':options'` as a
# way to read Vim's options: unattended, it never ends).
SCREEN_PROGRAMS = {"nano", "less", "more", "top", "visudo", "vipw", "vigr", "fdisk", "cfdisk"}
KCONFIG_UIS = {"menuconfig", "nconfig", "xconfig", "gconfig", "config"}
HEREDOC = re.compile(r"""<<-?\s*(['"]?)(\w+)\1""")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def commands(text):
    """Yield the word list of every simple command of a block."""
    lines = text.replace("\\\n", " ").split("\n")
    end = None
    for line in lines:
        if end is not None:
            if line.strip() == end:
                end = None
            continue
        m = HEREDOC.search(line)
        if m:
            end = m.group(2)
        for cmd in re.split(r"&&|\|\||;|\|", line):
            words = cmd.split()
            while words and ASSIGN.match(words[0]):
                words.pop(0)
            if words:
                yield words


def is_test(words):
    w0 = os.path.basename(words[0])
    if w0 in ("make", "ninja", "meson") and TEST_TARGETS & set(words[1:]):
        return True
    if w0 == "chown" and "tester" in words:
        return True
    if w0 in ("su", "runuser") and "tester" in words:
        return True
    if w0 == "unshare" and "test" in words:
        return True
    if w0 in ("test_summary", "pytest") or words[:3] == ["python3", "-m", "pytest"]:
        return True
    if w0 in ("grep", "cat") and any(re.search(r"\.(log|sum)\b|^\$\(find", x) for x in words[1:]):
        return True
    if any(re.match(r"(\./)?tests?/run", x) for x in words[:2]):
        return True
    return False


def is_interactive(words):
    """A command that waits for a person: it would hang an unattended build."""
    w0 = os.path.basename(words[0])
    if w0 in INTERACTIVE_CMDS or w0 in SCREEN_PROGRAMS:
        return True
    if w0 in ("vim", "vi", "view", "ex"):
        # full screen, unless run as a silent ex script (-es, -Es)
        return not any(re.fullmatch(r"-[eE]s", x) for x in words[1:])
    if w0 == "make" and KCONFIG_UIS & set(words[1:]):
        return True
    return False


class Page(html.parser.HTMLParser):
    """Collect the section id, title and command blocks of one book page."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.sid = None
        self.title = ""
        self.blocks = []  # (text, [placeholders])
        self._in_h1 = False
        self._in_pre = 0
        self._buf = []
        self._repl = []
        self._in_repl = 0
        self._rbuf = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "h1" and "sect1" in (a.get("class") or ""):
            self._in_h1 = True
        elif tag == "a" and self._in_h1 and self.sid is None and a.get("id"):
            self.sid = a["id"]
        elif tag == "pre" and "userinput" in (a.get("class") or "").split():
            self._in_pre = 1
            self._buf = []
            self._repl = []
        elif self._in_pre:
            if tag == "pre":
                self._in_pre += 1
            if self._in_repl:
                self._in_repl += 1
            elif "replaceable" in (a.get("class") or "").split():
                self._in_repl = 1
                self._rbuf = []

    def handle_endtag(self, tag):
        if tag == "h1":
            self._in_h1 = False
        elif self._in_repl:
            self._in_repl -= 1
            if self._in_repl == 0:
                self._repl.append("".join(self._rbuf))
        elif tag == "pre" and self._in_pre:
            self._in_pre -= 1
            if self._in_pre == 0:
                self.blocks.append(("".join(self._buf).strip("\n"), self._repl))

    def handle_data(self, data):
        if self._in_h1:
            self.title += data
        if self._in_pre:
            self._buf.append(data)
        if self._in_repl:
            self._rbuf.append(data)


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
        req = urllib.request.Request(url, headers={"User-Agent": "graveyard-lfs-extract"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read().decode("utf-8"), url
    path = os.path.join(base, rel)
    with open(path, encoding="utf-8") as f:
        return f.read(), path


def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def find_tarball(title, tarballs):
    """Map a section title such as 'Libstdc++ from GCC-16.2.0' to its tarball."""
    toks = re.findall(r"[A-Za-z][\w+.-]*?-\d[\w.]*", title)
    for tok in toks:
        n = norm(tok)
        hits = [t for t in tarballs if norm(t).startswith(n)]
        if hits:
            # the shortest name wins: tcl8.6.18-src before tcl8.6.18-html
            return min(hits, key=len)
    # 'Sqlite-3530400' is shipped as sqlite-autoconf-3530400.tar.gz
    for tok in toks:
        name, ver = tok.rsplit("-", 1)
        hits = [t for t in tarballs
                if norm(t).startswith(norm(name)) and norm(ver) in norm(t)
                and not re.search(r"-(doc|html|docs)", t)]
        if hits:
            return min(hits, key=len)
    return None


def classify(text, replaceable):
    cmds = list(commands(text))
    if any("..." in c for c in cmds):
        return "example"  # e.g. `ABI=32 ./configure ...`
    if any(is_test(c) for c in cmds):
        return "test suite"
    if any(is_interactive(c) for c in cmds):
        return "interactive"
    if replaceable:
        return "needs a value from lfs/overrides"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--book", required=True, help="book URL or local HTML directory")
    ap.add_argument("--sources", required=True, help="the book's wget-list")
    ap.add_argument("--out", required=True)
    ap.add_argument("--values", help="placeholder values: section <placeholder> value")
    o = ap.parse_args()

    with open(o.sources) as f:
        tarballs = [
            os.path.basename(urllib.parse.urlparse(l.strip()).path)
            for l in f
            if l.strip() and not l.strip().endswith(".patch")
        ]

    values = {}
    if o.values:
        with open(o.values) as f:
            for l in f:
                l = l.strip()
                if l and not l.startswith("#"):
                    sec, ph, val = l.split(None, 2)
                    values[(sec, ph)] = val

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
            why = classify(block, bool(repl))
            lines.append("")
            if why and why.startswith("needs") and all((sid, r) in values for r in repl):
                for r in repl:
                    block = block.replace(r, values[(sid, r)])
                lines.append(f"# --- block {i} (GraveyardOS values from lfs/values: "
                             + ", ".join(f"{r}={values[(sid, r)]}" for r in repl) + ")")
                lines.append(block)
                continue
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
