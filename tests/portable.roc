app [main!] { pkg: "../package/main.roc" }

import pkg.Tar
import "fixtures/portable.tsv" as oracle : Str

main! = |_args| Ok({})

# Rule sources:
# - ROC: `pathInvalidReason` in src/unbundle/unbundle.zig of roc-lang/roc,
#   commit 76258c1267204e31e58d8edcdd3ede6163ef60db (`roc unbundle` refuses
#   such a path, `roc bundle` does not write it), with the backslash rule of
#   Linux and macOS. TAR_PATH_MAX_LENGTH (255) is in src/unbundle/format.zig.
# - ORACLE: tests/fixtures/portable.tsv, the verdicts of `roc bundle`
#   (nightly-2026-10-31-f7bef6b) for real files, from scripts/portable-oracle.sh.
# - REG8: Talon slice 111, Registry R-PU38, Design R-PK8.

check = Tar.check_portable_path

# ROC rule 1: empty
expect check("") == Err(EmptyPath)

# ROC rule 2: 255 bytes are good, 256 are TooLong (bytes, not characters)
expect check(Str.from_utf8(List.repeat('a', 255)) ?? "") == Ok({})
expect check(Str.from_utf8(List.repeat('a', 256)) ?? "") == Err(TooLong)
expect check("${Str.from_utf8(List.repeat('a', 253)) ?? ""}é") == Ok({})
expect check("${Str.from_utf8(List.repeat('a', 254)) ?? ""}é") == Err(TooLong)

# ROC rule 2 comes before the others
expect check("/${Str.from_utf8(List.repeat('a', 300)) ?? ""}") == Err(TooLong)

# ROC rule 3: a leading `/` or `\`
expect check("/a") == Err(Absolute)
expect check("\\a") == Err(Absolute)

# ROC rule 4: `:` as the second byte, whatever the first byte is
expect check("C:x") == Err(DriveLetter)
expect check("1:") == Err(DriveLetter)
expect check("c:/x") == Err(DriveLetter)

# ROC rule 5: a `..` part, with `/` or `\` as the separator
expect check("..") == Err(ParentDir)
expect check("a/../b") == Err(ParentDir)
expect check("a\\..\\b") == Err(ParentDir)
expect check("a/..") == Err(ParentDir)

# ROC rule 6: a `.` part
expect check(".") == Err(DotPart)
expect check("./a") == Err(DotPart)
expect check("a/./b") == Err(DotPart)
expect check("a\\.\\b") == Err(DotPart)

# ROC: empty parts are skipped (`tokenizeAny`), so `//` is good
expect check("a//b") == Ok({})
expect check("a/b/") == Ok({})

# ROC rule 7: a Windows device name before the first `.` of a part, any case
expect check("CON") == Err(ReservedName)
expect check("con.roc") == Err(ReservedName)
expect check("dir/aux.tar.gz") == Err(ReservedName)
expect check("Lpt9") == Err(ReservedName)
expect check("com1") == Err(ReservedName)
expect check("CON\\x") == Err(ReservedName)
expect check("x.CON") == Ok({})
expect check("COM0") == Ok({})
expect check("COM10") == Ok({})
expect check("CONX") == Ok({})
expect check("CON .roc") == Ok({})

# ROC rules 8 and 9: a part that ends with a space or a `.`
expect check("x ") == Err(EndsWithSpace)
expect check("dir /a") == Err(EndsWithSpace)
expect check("a.") == Err(EndsWithPeriod)
expect check("...") == Err(EndsWithPeriod)
expect check("a./b") == Err(EndsWithPeriod)
expect check(".hidden") == Ok({})
expect check("a..b") == Ok({})

# ROC rule 10: each reserved byte, and NUL
expect ['<', '>', ':', '"', '|', '?', '*', 0].all(|b| check(Str.from_utf8(['a', 'b', b, 'c']) ?? "") == Err(ReservedChar(b)))

# ROC rule 11: a backslash that is not a reason before
expect check("a\\b") == Err(Backslash)

# ROC: rules 10 and 11 give the first such byte
expect check("a?\\b") == Err(ReservedChar('?'))
expect check("a\\?b") == Err(Backslash)

# ROC: the part rules (5 to 9) come before the byte rules (10, 11)
expect check("a?/..") == Err(ParentDir)

# REG8: check_path does not change: it accepts what check_portable_path refuses
expect Tar.check_path("CON") == Ok({})
expect Tar.check_path("a\\..\\b") == Ok({})

# ORACLE: each path has the verdict of roc bundle. roc names rule 4
# "absolute path", and rule 10 for any byte "reserved character".
expect {
	lines = oracle.trim_end().split_on("\n")
	bad = lines.keep_if(
		|line| {
			match line.split_first("\t") {
				Ok({ before: want, after: path }) => verdict(check(path)) != want
				Err(_) => Bool.True
			}
		},
	)
	lines.len() == 46 and bad == []
}

verdict : Try({}, _) -> Str
verdict = |r| match r {
	Ok({}) => "ok"
	Err(EmptyPath) => "EmptyPath"
	Err(TooLong) => "TooLong"
	Err(Absolute) | Err(DriveLetter) => "Absolute"
	Err(ParentDir) => "ParentDir"
	Err(DotPart) => "DotPart"
	Err(ReservedName) => "ReservedName"
	Err(EndsWithSpace) => "EndsWithSpace"
	Err(EndsWithPeriod) => "EndsWithPeriod"
	Err(ReservedChar(_)) => "ReservedChar"
	Err(Backslash) => "Backslash"
}
