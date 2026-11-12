"""python3 -m unittest discover -s lfs/tests"""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
EXTRACT = os.path.join(HERE, "..", "extract.py")

INDEX = """<html><body><ul>
<li><a href="chapter05/binutils-pass1.html">Binutils</a></li>
<li><a href="chapter05/binutils-pass1.html#x">again</a></li>
<li><a href="chapter08/gcc.html">GCC</a></li>
<li><a href="chapter08/glibc.html">Glibc</a></li>
<li><a href="chapter08/sqlite.html">SQLite</a></li>
<li><a href="chapter09/network.html">not extracted</a></li>
</ul></body></html>"""

BINUTILS = """<html><body><h1 class="sect1"><a id="ch-tools-binutils-pass1"
name="ch-tools-binutils-pass1"></a>5.2 Binutils-2.47 - Pass 1</h1>
<pre class="userinput"><kbd class="command">mkdir -v build
cd       build</kbd></pre>
<pre class="userinput"><kbd class="command">../configure --prefix=$LFS/tools \\
             --target=$LFS_TGT &amp;&amp; echo ok</kbd></pre>
</body></html>"""

GCC = """<html><body><h1 class="sect1"><a id="ch-system-gcc"></a>8.30 GCC-16.2.0</h1>
<pre class="userinput"><kbd class="command">make</kbd></pre>
<pre class="userinput"><kbd class="command">chown -R tester .
su tester -c "PATH=$PATH make -k check"</kbd></pre>
<pre class="userinput"><kbd class="command">make install</kbd></pre>
</body></html>"""

GLIBC = """<html><body><h1 class="sect1"><a id="ch-system-glibc"></a>8.5 Glibc-2.44</h1>
<pre class="userinput"><kbd class="command">ln -sfv /usr/share/zoneinfo/<em class="replaceable"><code>&lt;xxx&gt;</code></em> /etc/localtime</kbd></pre>
<pre class="userinput"><kbd class="command">exec /usr/bin/bash --login</kbd></pre>
<pre class="userinput"><kbd class="command">cat &gt; /etc/nsswitch.conf &lt;&lt; "EOF"
passwd: files systemd
exit
EOF</kbd></pre>
<pre class="userinput"><kbd class="command">./configure --disable-runuser \\
            --docdir=/usr/share/doc/check</kbd></pre>
<pre class="userinput"><kbd class="command">PAGE=A4 make -k check</kbd></pre>
</body></html>"""

SQLITE = """<html><body><h1 class="sect1"><a id="ch-system-sqlite"></a>8.52 Sqlite-3530400</h1>
<pre class="userinput"><kbd class="command">./configure</kbd></pre>
<pre class="userinput"><kbd class="command">cp -r doc <em class="replaceable"><code>&lt;dir&gt;</code></em>/sqlite</kbd></pre>
</body></html>"""

WGET = """https://sourceware.org/pub/binutils/releases/binutils-2.47.tar.xz
https://ftpmirror.gnu.org/gcc/gcc-16.2.0/gcc-16.2.0.tar.xz
https://ftpmirror.gnu.org/glibc/glibc-2.44.tar.xz
https://www.linuxfromscratch.org/patches/lfs/13.1/glibc-fhs-1.patch
https://sqlite.org/2026/sqlite-autoconf-3530400.tar.gz
https://sqlite.org/2026/sqlite-doc-3530400.zip
"""


class Extract(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        book = os.path.join(self.t, "book")
        for rel, txt in {
            "index.html": INDEX,
            "chapter05/binutils-pass1.html": BINUTILS,
            "chapter08/gcc.html": GCC,
            "chapter08/glibc.html": GLIBC,
            "chapter08/sqlite.html": SQLITE,
        }.items():
            os.makedirs(os.path.dirname(os.path.join(book, rel)), exist_ok=True)
            with open(os.path.join(book, rel), "w") as f:
                f.write(txt)
        with open(os.path.join(self.t, "wget-list"), "w") as f:
            f.write(WGET)
        with open(os.path.join(self.t, "values"), "w") as f:
            f.write("# section placeholder value\nch-system-sqlite <dir> /usr/share/doc\n")
        self.out = os.path.join(self.t, "out")
        subprocess.run(
            [sys.executable, "-I", EXTRACT, "--book", book,
             "--sources", os.path.join(self.t, "wget-list"), "--out", self.out,
             "--values", os.path.join(self.t, "values")],
            check=True, capture_output=True)

    def read(self, rel):
        with open(os.path.join(self.out, rel)) as f:
            return f.read()

    def test_manifest_order_and_tarballs(self):
        rows = [l.split("\t") for l in self.read("sections.tsv").splitlines()[1:]]
        self.assertEqual([r[2] for r in rows],
                         ["ch-tools-binutils-pass1", "ch-system-gcc", "ch-system-glibc",
                          "ch-system-sqlite"])
        self.assertEqual([r[3] for r in rows],
                         ["binutils-2.47.tar.xz", "gcc-16.2.0.tar.xz", "glibc-2.44.tar.xz",
                          "sqlite-autoconf-3530400.tar.gz"])
        self.assertNotIn("ch09", os.listdir(self.out))

    def test_commands_kept_verbatim(self):
        s = self.read("ch05/001-ch-tools-binutils-pass1.sh")
        self.assertIn("mkdir -v build\ncd       build", s)
        self.assertIn("--target=$LFS_TGT && echo ok", s)  # entities decoded
        self.assertNotIn("SKIPPED", s)

    def test_tests_and_interactive_are_commented_out(self):
        s = self.read("ch08/002-ch-system-gcc.sh")
        self.assertIn("SKIPPED (test suite)", s)
        self.assertIn('# su tester -c "PATH=$PATH make -k check"', s)
        self.assertIn("\nmake install", s)
        g = self.read("ch08/003-ch-system-glibc.sh")
        self.assertIn("SKIPPED (needs a value from lfs/overrides)", g)
        self.assertIn("SKIPPED (interactive)", g)
        self.assertIn("# ln -sfv /usr/share/zoneinfo/<xxx> /etc/localtime", g)

    def test_placeholder_values(self):
        s = self.read("ch08/004-ch-system-sqlite.sh")
        self.assertIn("(YVIS values from lfs/values: <dir>=/usr/share/doc)\ncp -r doc /usr/share/doc/sqlite", s)
        g = self.read("ch08/003-ch-system-glibc.sh")  # no value given: stays skipped
        self.assertIn("SKIPPED (needs a value from lfs/overrides)", g)

    def test_heredocs_and_options_are_not_commands(self):
        g = self.read("ch08/003-ch-system-glibc.sh")
        self.assertIn("\ncat > /etc/nsswitch.conf << \"EOF\"\npasswd: files systemd", g)
        self.assertIn("\n./configure --disable-runuser", g)
        self.assertIn("SKIPPED (test suite)\n# PAGE=A4 make -k check", g)


if __name__ == "__main__":
    unittest.main()
