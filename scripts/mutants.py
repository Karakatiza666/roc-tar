#!/usr/bin/env python3
# Mutation check of the L0 tests: each mutant changes one tricky rule of
# package/Tar.roc, runs `roc test` on each tests/*.roc, records which files
# fail (a run of more than 120 s counts as a fail), and restores the file. A mutant that no test kills exits 1.
# Usage: python3 -I scripts/mutants.py ROC [ID...]
import pathlib, signal, subprocess, sys

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
            if r.returncode != 0:
                tail = (r.stdout + r.stderr).strip().splitlines()[-4:]
                kind = "compile error" if any("compiler error" in l and not l.strip().startswith("0 compiler") for l in tail) else "fail"
                failed.append(f"{t.name} ({kind})")
        if not failed or all("compile error" in f for f in failed):
            survived.append(mid)
        print(f"| {mid} | {what} | {', '.join(failed) if failed else 'NONE: survived'} |", flush=True)
finally:
    SRC.write_text(orig)
print()
print("ALL KILLED" if not survived else f"SURVIVED: {' '.join(survived)}")
sys.exit(1 if survived else 0)
