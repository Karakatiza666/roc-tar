#!/bin/bash
# Compares the member list of tests/tools/tarlist.roc (this package) with
# GNU `tar -tv` (scripts/tvlist.sh) for the tar fixtures and for each
# .tar.zst bundle in the roc cache (or the files given). Exit 0 when all are
# the same. Usage: scripts/bundles.sh [ROC] [FILE.tar.zst...]. Needs GNU tar
# and zstd.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROC=${1:-roc}
shift || true
W=$HERE/.work/bundles
mkdir -p "$W"
"$ROC" build --opt=speed "$HERE/tests/tools/tarlist.roc" --output="$W/tarlist" >/dev/null || { echo "build failed"; exit 1; }
FAIL=0
N=0
check() { # name, command that writes the tar to stdout
	local name=$1
	shift
	"$@" | "$W/tarlist" > "$W/ours" 2>&1
	"$@" | "$HERE/scripts/tvlist.sh" > "$W/theirs" 2>&1
	end=$(tail -1 "$W/ours")
	sed -i '$s/^end .*/end/' "$W/ours"
	N=$((N + 1))
	if cmp -s "$W/ours" "$W/theirs"; then
		echo "same $(($(wc -l < "$W/ours") - 1)) members ($end) $name"
	else
		echo "DIFFERENT $name"
		diff "$W/ours" "$W/theirs" | head -10
		FAIL=1
	fi
}
for t in "$HERE"/tests/fixtures/*.tar; do
	check "$(basename "$t")" cat "$t"
done
if [ $# -gt 0 ]; then files=("$@"); else files=("${ROC_CACHE_DIR:-$HOME/.cache/roc}"/packages/*/*.tar.zst); fi
for f in "${files[@]}"; do
	check "$(basename "$f")" zstd -dcq "$f"
done
echo
[ $FAIL = 0 ] && echo "ALL $N SAME" || { echo "SOME DIFFERENT"; exit 1; }
