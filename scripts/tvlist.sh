#!/bin/bash
# Reads a tar from standard input and prints `tar -tv` in the form of
# tests/tools/tarlist.roc: "<type><mode> <size> <path>", then "end". GNU tar
# gives no end form and no member count, so the last line is "end".
set -euo pipefail
LC_ALL=C TZ=UTC tar --quoting-style=literal -tvf - | awk '{ perms = $1; size = $3; $1 = $2 = $3 = $4 = $5 = ""; sub(/^ +/, ""); print perms, size, $0 }'
echo end
