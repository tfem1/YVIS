# Notices

YVIS is © 2026 tfem1, under the GNU General Public License version 3 or
later (`LICENSE`), except the name and logo (`TRADEMARKS.md`).

## Work of others in this repository

- **Linux From Scratch and Beyond Linux From Scratch.** The build commands in
  `lfs/book/` and the BLFS pages read by `blfs/resolve.py` come from the LFS
  13.1-systemd and BLFS 13.1-systemd books (Gerard Beekmans and the LFS
  editors). The books' text is under the Creative Commons BY-NC-SA 2.0
  license and is not copied here; their computer instructions, which is
  what YVIS extracts, may be used under the MIT License (LFS appendix D):

  > Copyright © 1999-2026 Gerard Beekmans
  >
  > Permission is hereby granted, free of charge, to any person obtaining a
  > copy of this software and associated documentation files (the
  > "Software"), to deal in the Software without restriction, including
  > without limitation the rights to use, copy, modify, merge, publish,
  > distribute, sublicense, and/or sell copies of the Software, and to permit
  > persons to whom the Software is furnished to do so, subject to the
  > following conditions:
  >
  > The above copyright notice and this permission notice shall be included
  > in all copies or substantial portions of the Software.
  >
  > THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
  > OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
  > MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
  > NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
  > DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
  > OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
  > USE OR OTHER DEALINGS IN THE SOFTWARE.

## In the ISO

The ISO is a collection of programs, each under its own license (the GNU
GPL, LGPL, MIT, BSD and others); YVIS changes none of them. Their sources are
the tarballs listed with their SHA-256 in `lfs/sources.sha256`, downloaded
from the projects' own sites, and the build commands are in this repository:
together they are the corresponding source of every binary in the ISO. The
license files of each program are installed in the system, under
`/usr/share/doc` and `/usr/share/licenses` where the program provides them.
The only non-free part YVIS intends to ship is device firmware, from the
linux-firmware project, under the licenses it carries.
