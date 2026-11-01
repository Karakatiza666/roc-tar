#!/usr/bin/env python3
# Mutation check of the L0 tests: each mutant changes one tricky rule of
# package/Tar.roc, runs `roc test` on each tests/*.roc, records which files
# have a failed expect (a run of more than 120 s counts as a fail), and restores
# the file. A mutant that no test kills (or that only gives compile errors) exits 1.
# Usage: python3 -I scripts/mutants.py ROC [ID...]
import pathlib, re, signal, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent.parent
SRC = HERE / "package" / "Tar.roc"
ROC = sys.argv[1]
ONLY = set(sys.argv[2:])

MUTANTS = [
    ("M1", "chunk split: a partial header takes a whole block from the next chunk",
     "take = U64.min(block_size - have, n - $i)", "take = U64.min(block_size, n - $i)"),
    ("M2", "512 padding: a size that is a multiple of 512 gets one more block",
     "pad = (block_size - size % block_size) % block_size", "pad = block_size - size % block_size"),
    ("M3", "checksum: the last checksum byte is not counted as a space",
     "v = if ($k >= 148 and $k < 156) ' ' else b", "v = if ($k >= 148 and $k < 155) ' ' else b"),
    ("M4", "pax length: the value keeps the newline",
     "kv = rest.sublist({ start: space + 1, len: len - space - 2 })", "kv = rest.sublist({ start: space + 1, len: len - space - 1 })"),
    ("M5", "pax: an empty x value does not delete the g value",
     "\t\tClear => after_pax(header)\n", "\t\tClear => after_pax(pick_global(global, header))\n"),
    ("M6", "end: a byte after the two zero blocks is accepted",
     "Ok(k) => return Err(DataAfterEnd({ offset: $t.offset + k }))", "Ok(_) => {\n\t\t\t\t\t\t\t$t = { ..$t, offset: $t.offset + (n - $i) }\n\t\t\t\t\t\t\t$i = n\n\t\t\t\t\t\t}"),
    ("M7", "end: a lone zero block, then a header, is read as a member",
     "OneZero => Err(LoneZeroBlock({ offset: t.at }))", "OneZero => on_header({ ..t, phase: Header }, block, choose)"),
    ("M8", "ustar: the prefix and the name are joined with no '/'",
     "prefix.concat(['/']).concat(name)", "prefix.concat(name)"),
    ("M9", "truncation: an input that ends in the padding is a clean end",
     "Pad(_) => Err(Truncated({ offset: tar.offset, inside: Padding }))", "Pad(_) => summary(NoZeroBlock)"),
    ("M10", "collect: a member of limit + 1 bytes is collected",
     "if size > limit {", "if size > limit + 1 {"),
    ("M11", "portable path: a backslash does not end a part",
     "if b == '/' or b == '\\\\' {", "if b == '/' {"),
    ("M12", "portable path: a reserved name is the whole part, not the part before the first '.'",
     "base = c_until(part, '.')", "base = part"),
    ("M13", "portable path: 256 bytes are good",
     "if bytes.len() > 255 {", "if bytes.len() > 256 {"),
    ("M14", "state: max_meta_bytes does not count the kept pax and GNU values",
     "kept = meta_bytes(t.local) + meta_bytes(t.global)", "kept = 0"),
    ("M15", "type byte: NUL is given as '0' (the byte of the kind, not of the header)",
     "offset: at, type_byte: type }", "offset: at, type_byte: if (type == 0) '0' else type }"),
    ("M16", "roc_accepts: '7' is accepted, as its kind is File",
     "if !(type == '0' or type == 0 or type == '5' or type == '2') {", "if !(type == '0' or type == 0 or type == '7' or type == '5' or type == '2') {"),
    ("M17", "roc_accepts: a link target is checked with '/' as the only separator",
     "for part in parts(bytes) {\n\t\tif part == ['.', '.'] {\n\t\t\treturn Err(ParentDir)\n\t\t}\n\t\tif part == ['.'] {\n\t\t\treturn Err(DotPart)\n\t\t}\n\t}\n\tOk({})",
     "for part in bytes.split_on('/') {\n\t\tif part == ['.', '.'] {\n\t\t\treturn Err(ParentDir)\n\t\t}\n\t\tif part == ['.'] {\n\t\t\treturn Err(DotPart)\n\t\t}\n\t}\n\tOk({})"),
]
HELPER = "\npick_global = |g, h| match g {\n\tSet(x) => x\n\t_ => h\n}\n"

orig = SRC.read_text()
# A stop (Ctrl-C, kill) also restores the file.
signal.signal(signal.SIGTERM, lambda *_: sys.exit(2))
tests = sorted((HERE / "tests").glob("*.roc"))
survived = []
print("| Id | Mutant | Files with a failed test |")
print("| --- | --- | --- |")
try:
    for mid, what, old, new in MUTANTS:
        if ONLY and mid not in ONLY:
            continue
        assert orig.count(old) == 1, f"{mid}: the text is not in Tar.roc once"
        text = orig.replace(old, new)
        if mid == "M5":
            text += HELPER
        SRC.write_text(text)
        failed = []
        for t in tests:
            try:
                r = subprocess.run([ROC, "test", str(t), "--no-cache"], cwd=HERE, capture_output=True, text=True, timeout=120)
            except subprocess.TimeoutExpired:
                failed.append(f"{t.name} (timeout)")
                continue
            out = r.stdout + r.stderr
            # A warning (for example an unconditional if) also gives a nonzero
            # exit, so count only a failed expect or a compile error.
            if re.search(r"^\s*[1-9][0-9]* failed", out, re.M):
                failed.append(f"{t.name} (fail)")
            elif re.search(r"^\s*[1-9][0-9]* compiler error|Compilation failed|── ✗", out, re.M):
                failed.append(f"{t.name} (compile error)")
        if not failed or all("compile error" in f for f in failed):
            survived.append(mid)
        print(f"| {mid} | {what} | {', '.join(failed) if failed else 'NONE: survived'} |", flush=True)
finally:
    SRC.write_text(orig)
print()
print("ALL KILLED" if not survived else f"SURVIVED: {' '.join(survived)}")
sys.exit(1 if survived else 0)
