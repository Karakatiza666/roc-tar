#!/usr/bin/env python3
# Prints one line for each .tar.zst file: the type bytes, the magic forms, the
# longest path, and if a member uses the ustar prefix field. Reads the
# decompressed tar from `zstd -dc`. Usage: tarscan.py FILE.tar.zst...
import subprocess, sys
from collections import Counter

for f in sys.argv[1:]:
    data = subprocess.run(["zstd", "-dc", f], capture_output=True, check=True).stdout
    pos, types, magics, longest, prefix, n = 0, Counter(), Counter(), 0, 0, 0
    zeros = 0
    while pos + 512 <= len(data):
        h = data[pos:pos + 512]
        if h == bytes(512):
            zeros += 1
            pos += 512
            continue
        n += 1
        types[chr(h[156]) if h[156] else "NUL"] += 1
        magics[h[257:265]] += 1
        name = h[0:100].split(b"\0")[0]
        pre = h[345:500].split(b"\0")[0]
        if pre:
            prefix += 1
        longest = max(longest, len(name) + (len(pre) + 1 if pre else 0))
        size = int(h[124:136].strip(b"\0 ") or b"0", 8)
        pos += 512 + (size + 511) // 512 * 512
    tail = len(data) - pos
    print(f"{f.split('/')[-1][:12]} members={n} types={dict(types)} magic={[m for m in magics]} longest={longest} prefix_used={prefix} zero_blocks={zeros} tail={tail} bytes={len(data)}")
