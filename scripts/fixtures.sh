#!/bin/bash
# Makes tests/fixtures/{ustar,gnu,pax}.tar with GNU tar, and copies two small
# real roc bundles (decompressed) from the roc cache. Each .tar has a .list
# file: the output of `tar -tv`, in the form of tests/tools/tarlist.roc.
# Usage: scripts/fixtures.sh. Needs GNU tar and zstd.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
F=$HERE/tests/fixtures
T=$HERE/.work/fixture-tree
rm -rf "$T" && mkdir -p "$T"
cd "$T"
mid=$(printf 'm%.0s' $(seq 1 60))
long=$(printf 'L%.0s' $(seq 1 120))
mkdir -p "pkg/$mid/$mid/deep" "pkg/$long"
printf 'app [main!] {}\n' > pkg/main.roc
printf 'deep\n' > "pkg/$mid/$mid/deep/Deep.roc"
printf 'long\n' > "pkg/$long/Long.roc"
head -c 1000 /dev/zero | tr '\0' 'z' > pkg/zeta.bin
ln -s main.roc pkg/link.roc
ln pkg/zeta.bin pkg/hard.bin
chmod 755 pkg/main.roc
common=(--owner=0 --group=0 --numeric-owner --mtime=@0 --sort=name)
tar "${common[@]}" --format=gnu -cf "$F/gnu.tar" pkg
tar "${common[@]}" --format=pax --pax-option=delete=atime,delete=ctime -cf "$F/pax.tar" pkg
# ustar cannot hold the 120-byte part: leave that directory out.
tar "${common[@]}" --format=ustar --exclude="pkg/$long" -cf "$F/ustar.tar" pkg
P=${ROC_CACHE_DIR:-$HOME/.cache/roc}/packages
# roc-base58 0.1.0 and roc-app-header 0.1.0: bundles that roc bundle made.
for h in BgUuQGqWY94NikfEx4rBkWkgxYhngMim3ZEnD8wpM4NS HDQnwrX2Bcm8Jsf8RMC9ZdbVGwPiqD2nCLP7Zf1osfgU; do
	zstd -dcq "$P/$h/$h.tar.zst" > "$F/roc-$h.tar"
done
for t in "$F"/*.tar; do
	"$HERE/scripts/tvlist.sh" < "$t" > "${t%.tar}.list"
done
ls -l "$F"
