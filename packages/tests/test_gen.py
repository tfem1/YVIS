"""Tests of the rewriting rules of packages/gen-base.py."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gen", os.path.join(HERE, "..", "gen-base.py"))
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)
P = '"$PKGDIR"'


class Rewrite(unittest.TestCase):
    def r(self, text):
        return gen.rewrite(text)

    def test_destinations_are_prefixed(self):
        self.assertEqual(self.r("cp -v services protocols /etc"), f"cp -v services protocols {P}/etc")
        self.assertEqual(self.r("rm -fv /usr/lib/{a,b}.a"), f"rm -fv {P}/usr/lib/{{a,b}}.a")
        self.assertEqual(self.r("cp --remove-destination -av dest/* /"), f"cp --remove-destination -av dest/* {P}/")
        self.assertEqual(self.r("mv -v /usr/{,s}bin/ifconfig"), f"mv -v {P}/usr/{{,s}}bin/ifconfig")

    def test_program_and_options_are_not(self):
        for line in ("./configure --prefix=/usr --sysconfdir=/etc", "/usr/bin/foo bar",
                     "zic -L /dev/null -d x y", "sed -e 's|/usr|x|' -i file", 'echo "/etc/vimrc" >> f'):
            self.assertEqual(self.r(line), line)

    def test_symlinks(self):
        self.assertEqual(self.r("ln -sfv /usr/share/zoneinfo/UTC /etc/localtime"),
                         f"ln -sfv /usr/share/zoneinfo/UTC {P}/etc/localtime")
        self.assertEqual(self.r("ln -svr /usr/bin/cpp /usr/lib"), f"ln -svr {P}/usr/bin/cpp {P}/usr/lib")
        self.assertEqual(self.r("ln -sv vim /usr/bin/vi"), f"ln -sv vim {P}/usr/bin/vi")
        self.assertEqual(self.r("ln -sfvr $(gcc -print-prog-name=x.so) /usr/lib/bfd-plugins/"),
                         f"ln -sfvr {P}$(gcc -print-prog-name=x.so) {P}/usr/lib/bfd-plugins/")

    def test_redirections_and_heredocs(self):
        text = 'cat > /etc/x << "EOF"\n/usr/local/lib\nEOF\ncat >> /etc/x << EOF\ninclude /etc/y\nEOF'
        self.assertEqual(self.r(text), f'cat > {P}/etc/x << "EOF"\n/usr/local/lib\nEOF\n'
                                        f'cat >> {P}/etc/x << EOF\ninclude /etc/y\nEOF')
        self.assertEqual(self.r("make foo 2>/dev/null"), "make foo 2>/dev/null")

    def test_installation_commands(self):
        self.assertEqual(self.r("make install"), 'make install DESTDIR="$PKGDIR"')
        self.assertEqual(self.r("make -C doc install-html docdir=/usr/x"),
                         'make -C doc install-html docdir=/usr/x DESTDIR="$PKGDIR"')
        self.assertEqual(self.r("make DESTDIR=$PWD/dest install"), "make DESTDIR=$PWD/dest install")
        self.assertEqual(self.r("make"), "make")
        self.assertEqual(self.r("ninja install"), 'DESTDIR="$PKGDIR" ninja install')
        self.assertEqual(self.r("pip3 install --no-index --find-links dist meson"),
                         'pip3 install --root="$PKGDIR" --ignore-installed --no-deps --no-index --find-links dist meson')
        self.assertEqual(self.r("localedef -i C -f UTF-8 C.UTF-8"),
                         'localedef --prefix="$PKGDIR" -i C -f UTF-8 C.UTF-8')

    def test_continuations_and_loops(self):
        text = "tar -xf x.tar \\\n    -C /usr/share/man\nrm -rfv /usr/lib/a.a \\\n        /usr/share/doc/g/"
        self.assertEqual(self.r(text), f"tar -xf x.tar \\\n    -C {P}/usr/share/man\n"
                                        f"rm -rfv {P}/usr/lib/a.a \\\n        {P}/usr/share/doc/g/")
        loop = "for i in /usr/bin/{a,b}; do\n  ln -sfv bzip2 $i\ndone"
        self.assertEqual(self.r(loop), f"for i in {P}/usr/bin/{{a,b}}; do\n  ln -sfv bzip2 $i\ndone")
        self.assertEqual(self.r("ZONEINFO=/usr/share/zoneinfo"), f"ZONEINFO={P}/usr/share/zoneinfo")

    def test_system_setup_is_not_package_content(self):
        for line in ("systemctl preset-all", "pwconv", "install-info --dir-file=/usr/share/info/dir x"):
            self.assertTrue(self.r(line).startswith("# GraveyardOS: not package content"), line)

    def test_names_and_versions(self):
        self.assertEqual(gen.version_of("8.89 Libelf from Elfutils-0.195"), "0.195")
        self.assertEqual(gen.version_of("8.57 Tcl-8.6.18"), "8.6.18")
        self.assertEqual(gen.package_name("ch-system-Python"), "python")
        self.assertEqual(gen.topdir("tcl8.6.18-src.tar.gz", None), "tcl8.6.18")


if __name__ == "__main__":
    unittest.main()
