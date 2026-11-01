app [main!] { pkg: "../package/main.roc" }

import pkg.Tar
import lib/Mk as Mk

main! = |_args| Ok({})

# Rule sources:
# - USTAR: POSIX.1-1988 ustar header (IEEE Std 1003.1, pax "ustar Interchange Format").
# - GNU: the old GNU header (magic "ustar  \0", no prefix field).
# - REG<n>: requirement n of the registry Worker (Talon slice 111, Registry R-PU38).
# - API: the rules of README.md "API".

one : Mk.H -> Try({ events : List(Tar.Event), summary : Tar.Summary }, Tar.Error)
one = |h| Mk.run([Mk.member(h, List.repeat('d', h.size)).concat(Mk.end)], Mk.skip)

entry_of : Mk.H -> Try(Tar.Entry, [NoEntry])
entry_of = |h| match one(h) {
	Ok({ events: [Entry(e), ..], .. }) => Ok(e)
	_ => Err(NoEntry)
}

error_of : List(U8) -> Try(Tar.Error, [NoError])
error_of = |bytes| match Mk.run([bytes], Mk.skip) {
	Err(e) => Ok(e)
	Ok(_) => Err(NoError)
}

# USTAR, REG2: the fields of a regular file
expect
	entry_of(Mk.H.{ name: "src/main.roc", size: 12, mode: 0o755 })
		== Ok({ path: "src/main.roc", kind: File, size: 12, mode: 0o755, link: "", offset: 0 })

# USTAR, REG6: each type byte gives its kind; a link has its target
expect entry_of(Mk.H.{ name: "d/", type: '5' }).map_ok(|e| e.kind) == Ok(Dir)
expect entry_of(Mk.H.{ name: "s", type: '2', link: "../x" }).map_ok(|e| (e.kind, e.link)) == Ok((Symlink, "../x"))
expect entry_of(Mk.H.{ name: "h", type: '1', link: "a" }).map_ok(|e| (e.kind, e.link)) == Ok((HardLink, "a"))
expect entry_of(Mk.H.{ name: "f", type: 0 }).map_ok(|e| e.kind) == Ok(File)
expect entry_of(Mk.H.{ name: "f", type: '7', size: 3 }).map_ok(|e| e.kind) == Ok(File)
expect entry_of(Mk.H.{ name: "c", type: '3' }).map_ok(|e| e.kind) == Ok(Other('3'))
expect entry_of(Mk.H.{ name: "p", type: '6' }).map_ok(|e| e.kind) == Ok(Other('6'))
expect entry_of(Mk.H.{ name: "v", type: 'V', size: 2 }).map_ok(|e| e.kind) == Ok(Other('V'))

# USTAR, REG2: the path is prefix, "/", name
expect
	entry_of(Mk.H.{ name: "Name.roc", prefix: "a/b" }).map_ok(|e| e.path)
		== Ok("a/b/Name.roc")

# USTAR, REG2: a name of 100 bytes has no NUL; a prefix of 155 bytes has no NUL
expect {
	name = Str.from_utf8(List.repeat('n', 100)) ?? ""
	prefix = Str.from_utf8(List.repeat('p', 155)) ?? ""
	entry_of(Mk.H.{ name, prefix }).map_ok(|e| e.path.count_utf8_bytes()) == Ok(256)
}

# GNU: the old GNU magic has no prefix field, so bytes there are not a path
expect
	entry_of(Mk.H.{ name: "g.roc", prefix: "junk", magic: ['u', 's', 't', 'a', 'r', ' ', ' ', 0] }).map_ok(|e| e.path)
		== Ok("g.roc")

# USTAR: a header with no ustar magic (V7 tar) is NotUstar
expect error_of(Mk.header(Mk.H.{ name: "a", magic: [0, 0, 0, 0, 0, 0, 0, 0] })) == Ok(NotUstar({ offset: 0 }))
expect error_of(Mk.header(Mk.H.{ name: "a", magic: ['u', 's', 't', 'a', 'r', ' ', 0, 0] })) == Ok(NotUstar({ offset: 0 }))

# USTAR, REG6: a checksum that is one off is BadChecksum
expect {
	h = Mk.header(Mk.H.{ name: "a" })
	bad = Mk.put(h, 0, ['b'])
	error_of(bad) == Ok(BadChecksum({ offset: 0 }))
}

# USTAR: the checksum counts the 8 checksum bytes as spaces, so its own digits do not count
expect {
	h = Mk.header(Mk.H.{ name: "a" })
	# Leading spaces and a NUL end, as the Zig writer of roc bundle makes them.
	sum = h.sublist({ start: 148, len: 6 })
	zig = Mk.put(h, 148, [' '].concat(sum.drop_first(1)).concat([0, ' ']))
	Mk.run([zig.concat(Mk.end)], Mk.skip).is_ok()
}

# USTAR: the checksum of signed bytes (old writers) is also good
expect {
	h0 = Mk.header(Mk.H.{ name: "\u(e9)" })
	# The name has the bytes 0xC3 0xA9. Signed, they count 256 less each.
	unsigned = h0.fold(0.U64, |acc, b| acc + b.to_u64()) - h0.sublist({ start: 148, len: 8 }).fold(0.U64, |acc, b| acc + b.to_u64()) + 256
	signed = unsigned - 512
	octal6 = oct(signed, 6)
	h = Mk.put(h0, 148, octal6.concat([0, ' ']))
	Mk.run([h.concat(Mk.end)], Mk.skip).is_ok()
}

# USTAR, REG6: a size that is not octal is BadNumber
expect error_of(Mk.put(Mk.header(Mk.H.{ name: "a" }), 124, ['9']) |> Mk.fix_sum(0)) == Ok(BadNumber({ offset: 0, field: "size" }))
expect error_of(Mk.put(Mk.header(Mk.H.{ name: "a" }), 130, ['x']) |> Mk.fix_sum(0)) == Ok(BadNumber({ offset: 0, field: "size" }))

# USTAR: a digit after the NUL end of a number is BadNumber
expect error_of(Mk.put(Mk.header(Mk.H.{ name: "a" }), 100, [0, '1']) |> Mk.fix_sum(0)) == Ok(BadNumber({ offset: 0, field: "mode" }))

# API: a base-256 number (GNU, first byte 0x80) is BadNumber
expect error_of(Mk.put(Mk.header(Mk.H.{ name: "a" }), 124, [0x80]) |> Mk.fix_sum(0)) == Ok(BadNumber({ offset: 0, field: "size" }))

# USTAR: each number field is checked
expect error_of(Mk.put(Mk.header(Mk.H.{ name: "a" }), 108, ['8']) |> Mk.fix_sum(0)) == Ok(BadNumber({ offset: 0, field: "uid" }))
expect error_of(Mk.put(Mk.header(Mk.H.{ name: "a" }), 116, ['8']) |> Mk.fix_sum(0)) == Ok(BadNumber({ offset: 0, field: "gid" }))
expect error_of(Mk.put(Mk.header(Mk.H.{ name: "a" }), 136, ['8']) |> Mk.fix_sum(0)) == Ok(BadNumber({ offset: 0, field: "mtime" }))

# USTAR: leading spaces, a space end, and a field of only NUL are good numbers
expect {
	h = Mk.put(Mk.header(Mk.H.{ name: "a", size: 0 }), 124, [' ', ' ', ' ', '1', '2', ' ', 0, 0, 0, 0, 0, 0]) |> Mk.fix_sum(0)
	(Mk.run([h.concat(List.repeat('z', 10)).concat(List.repeat(0, 502)).concat(Mk.end)], Mk.skip) ?? crash "x").summary.total_size == 10
}
expect {
	h = Mk.put(Mk.header(Mk.H.{ name: "a" }), 108, List.repeat(0, 16)) |> Mk.fix_sum(0)
	Mk.run([h.concat(Mk.end)], Mk.skip).is_ok()
}

# REG6, API: a link, directory or device with a size is UnexpectedData
expect error_of(Mk.header(Mk.H.{ name: "d/", type: '5', size: 1 })) == Ok(UnexpectedData({ offset: 0, size: 1 }))
expect error_of(Mk.header(Mk.H.{ name: "s", type: '2', size: 512, link: "x" })) == Ok(UnexpectedData({ offset: 0, size: 512 }))

# API: an empty path is BadPath(Empty); a path that is not UTF-8 is BadPath(NotUtf8)
expect error_of(Mk.header(Mk.H.{ name: "" })) == Ok(BadPath({ offset: 0, problem: Empty }))
expect error_of(Mk.put(Mk.header(Mk.H.{ name: "ab" }), 0, [0xFF]) |> Mk.fix_sum(0)) == Ok(BadPath({ offset: 0, problem: NotUtf8 }))

# REG8: the path is as given: no change of "./", "//" or ".."
expect entry_of(Mk.H.{ name: "./a//b/../c" }).map_ok(|e| e.path) == Ok("./a//b/../c")
expect entry_of(Mk.H.{ name: "/etc/passwd" }).map_ok(|e| e.path) == Ok("/etc/passwd")

# REG8: check_path
expect Tar.check_path("main.roc") == Ok({})
expect Tar.check_path("a/b/c.roc") == Ok({})
expect Tar.check_path("a/..b/c..") == Ok({})
expect Tar.check_path("") == Err(EmptyPath)
expect Tar.check_path("/main.roc") == Err(Absolute)
expect Tar.check_path("..") == Err(ParentDir)
expect Tar.check_path("a/../b") == Err(ParentDir)
expect Tar.check_path("a/..") == Err(ParentDir)

# API: each error has a text that starts with "tar: "
expect {
	errors : List(Tar.Error)
	errors = [
		BadChecksum({ offset: 1 }),
		BadNumber({ offset: 1, field: "size" }),
		NotUstar({ offset: 1 }),
		BadPax({ offset: 1 }),
		BadPath({ offset: 1, problem: Empty }),
		BadPath({ offset: 1, problem: NotUtf8 }),
		BadPath({ offset: 1, problem: HasNul }),
		PathTooLong({ offset: 1, bytes: 2, limit: 1 }),
		UnexpectedData({ offset: 1, size: 1 }),
		MetaWithoutMember({ offset: 1 }),
		MetaTooLarge({ offset: 1, size: 2, limit: 1 }),
		TooManyMembers({ offset: 1, limit: 1 }),
		TooManyPathBytes({ offset: 1, limit: 1 }),
		TotalSizeTooLarge({ offset: 1, limit: 1 }),
		ContentTooLarge({ offset: 1, size: 2, limit: 1 }),
		CollectTooLarge({ offset: 1, limit: 1 }),
		LoneZeroBlock({ offset: 1 }),
		DataAfterEnd({ offset: 1 }),
		Truncated({ offset: 1, inside: Header }),
		Truncated({ offset: 1, inside: Data }),
		Truncated({ offset: 1, inside: Padding }),
	]
	errors.all(|e| Tar.err_to_str(e).starts_with("tar: "))
}

# An octal field of `width` digits with leading zeros.
oct : U64, U64 -> List(U8)
oct = |value, width| {
	var $digits = []
	var $v = value
	for _k in 0.U64..<width {
		$digits = $digits.prepend('0' + ($v % 8).to_u8_wrap())
		$v = $v // 8
	}
	$digits
}
