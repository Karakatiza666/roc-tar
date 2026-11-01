#!/bin/bash
# Makes tests/fixtures/portable.tsv: for each path of the list below, the
# verdict of `roc bundle` (which applies `pathInvalidReason` of roc
# src/unbundle/unbundle.zig to each path that it writes). Each line is
# "<verdict>\t<path>", where <verdict> is "ok" or the tag of
# Tar.check_portable_path that the roc message names. A path that has `.`
# or `..` parts or a leading `/` is not in the list: roc bundle makes the
# archive path from the file path, so the file system changes such a path.
# tests/portable.roc tests those rules from the source.
# Usage: scripts/portable-oracle.sh [ROC]
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROC=${1:-roc}
W=$HERE/.work/portable
rm -rf "$W" && mkdir -p "$W/out"
cd "$W"
printf 'package [] {}\n' > main.roc
d100=$(printf 'd%.0s' $(seq 1 99))
paths=(
	"a.roc" "dir/b.roc" ".hidden" "a b/c.roc" "x-.roc" "x.CON" "CONX.roc" "COM0.roc" "COM10" "LPT" "é.roc" "a..b"
	"con.roc" "CON" "Nul" "aux.tar.gz" "LPT9.txt" "com1" "dir/PRN.roc" "CON .roc"
	"x " "dir /a" "a." "a./b" "..." "x.roc."
	"C:x" "1:" "ab:c" "a<b" "a>b" 'a"b' "a|b" "a?b" "a*b"
	'a\b' '\x' 'a\..\b' 'a\.\b' 'CON\x' 'x \y' 'a?\b' 'a\?b' 'a\:b'
	"$d100/$d100/$(printf 'f%.0s' $(seq 1 55))"
	"$d100/$d100/$(printf 'f%.0s' $(seq 1 56))"
)
for p in "${paths[@]}"; do
	mkdir -p -- "$(dirname -- "$p")"
	: > "$p"
	if msg=$("$ROC" bundle main.roc "$p" --output-dir out 2>&1); then
		v=ok
	else
		case "$msg" in
			*"exceeds maximum length"*) v=TooLong ;;
			*"Absolute paths"*) v=Absolute ;;
			*"traversal"*) v=ParentDir ;;
			*"Current directory"*) v=DotPart ;;
			*"reserved device name"*) v=ReservedName ;;
			*"end with space"*) v=EndsWithSpace ;;
			*"end with period"*) v=EndsWithPeriod ;;
			*"directory separator on Windows"*) v=Backslash ;;
			*"colon"*|*"asterisk"*|*"question mark"*|*"quote"*|*"less-than"*|*"greater-than"*|*"pipe"*) v=ReservedChar ;;
			*) echo "unknown message for '$p': $msg" >&2; exit 1 ;;
		esac
	fi
	printf '%s\t%s\n' "$v" "$p"
	rm -f out/*
	top=${p%%/*}
	rm -rf -- "$top"
done > "$HERE/tests/fixtures/portable.tsv"
"$ROC" version >&2
cat "$HERE/tests/fixtures/portable.tsv" | cut -c1-60
