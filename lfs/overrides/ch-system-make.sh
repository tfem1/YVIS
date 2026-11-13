# 8.70 Make: the book's commands, built serially. A parallel build of make
# 4.4.1 by the temporary make hung for 90 min in lib/ on GitHub Actions
# (run 43311808077); a serial build takes a few seconds.
./configure --prefix=/usr
make -j1
make install
