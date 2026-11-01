app [main!] { pkg: "../package/main.roc" }

import pkg.Tar
import lib/Mk as Mk

main! = |_args| Ok({})

# Rule sources:
# - USTAR: POSIX.1-1988 ustar (512-byte blocks, data padded to 512, end of two zero blocks).
# - REG<n>: requirement n of the registry Worker (Talon slice 111, Registry R-PU38).
# - API: the rules of README.md "API".

# Three members: a pax `path` (so a meta header comes first), a file of 5
# bytes, a file of 600 bytes (two data blocks), then the end.
long_path : Str
long_path = "pkg/${Str.from_utf8(List.repeat('x', 150)) ?? ""}/Long.roc"

body : List(U8)
body = Mk.pax('x', [("path", long_path)])
	.concat(Mk.file("ignored", "abc".to_utf8()))
	.concat(Mk.file("main.roc", "hello".to_utf8()))
	.concat(Mk.file("big.bin", List.repeat('b', 600)))

archive : List(U8)
archive = body.concat(Mk.end)

# Collect main.roc only.
choose : Tar.Entry -> Tar.Action
choose = |e| if (e.path == "main.roc") Collect(100) else Skip

whole : Try({ events : List(Tar.Event), summary : Tar.Summary }, Tar.Error)
whole = Mk.run([archive], choose)

entry : Str, U64, U64 -> Tar.Entry
entry = |path, size, offset| { path, kind: File, size, mode: 0o644, link: "", offset, type_byte: '0' }

# USTAR, REG2, REG3: the events of the archive in one chunk
expect
	whole
		== Ok({
			events: [
				Entry(entry(long_path, 3, 1024)),
				Entry(entry("main.roc", 5, 2048)),
				Content(entry("main.roc", 5, 2048), "hello".to_utf8()),
				Entry(entry("big.bin", 600, 3072)),
			],
			summary: { end: TwoZeroBlocks, members: 3, bytes: archive.len(), total_size: 608 },
		})

# REG1: two chunks, split at each byte: in a header, in a pax record, in
# data, in padding, in the end blocks. The result is the same.
expect {
	var $bad = []
	for k in 0.U64..=archive.len() {
		if Mk.run(Mk.split(archive, k), choose) != whole {
			$bad = $bad.append(k)
		}
	}
	$bad == []
}

# REG1: chunks of each size from 1 to 1100 bytes (fewer and more than a block)
expect {
	var $bad = []
	for size in 1.U64..=1100 {
		if Mk.run(Mk.chunks(archive, size), choose) != whole {
			$bad = $bad.append(size)
		}
	}
	$bad == []
}

# REG1: empty chunks change nothing
expect Mk.run([[], archive.take_first(700), [], archive.drop_first(700), []], choose) == whole

# REG6, USTAR: an input that stops at each byte. At the end of a member it is a
# clean end with no zero block; else Truncated with the part where it stops.
expect {
	var $bad = []
	for p in 0.U64..<body.len() {
		got = match Mk.run(Mk.split(body.take_first(p), p / 2), choose) {
			Ok({ summary, .. }) => Ok(summary.end)
			Err(Truncated({ offset, inside })) if offset == p => Err(inside)
			Err(_) => Err(Wrong)
		}
		want = expect_cut(p)
		if got != want {
			$bad = $bad.append(p)
		}
	}
	$bad == []
}

# Where an input of `p` bytes of `body` ends.
expect_cut : U64 -> Try(Tar.End, [Header, Data, Padding, Wrong])
expect_cut = |p| {
	# The blocks: pax header 0, pax data 512 (record of `rec` bytes), header 1024,
	# data 1536 (3), header 2048, data 2560 (5), header 3072, data 3584 (600).
	rec = Mk.record("path", long_path).len()
	if p == 0 or p == 2048 or p == 3072 {
		Ok(NoZeroBlock)
	} else if p == 1024 {
		# The pax header has no member yet: a block boundary in a header.
		Err(Wrong)
	} else if p % 512 != 0 and (p < 512 or (p > 1024 and p < 1536) or (p > 2048 and p < 2560) or (p > 3072 and p < 3584)) {
		Err(Header)
	} else if p >= 512 and p < 1024 {
		if (p < 512 + rec) Err(Data) else Err(Padding)
	} else if p >= 1536 and p < 2048 {
		if (p < 1539) Err(Data) else Err(Padding)
	} else if p >= 2560 and p < 3072 {
		if (p < 2565) Err(Data) else Err(Padding)
	} else if p >= 3584 {
		if (p < 4184) Err(Data) else Err(Padding)
	} else {
		Err(Wrong)
	}
}

# API: a meta header and then the end of the input is MetaWithoutMember
expect Mk.run([body.take_first(1024)], choose) == Err(MetaWithoutMember({ offset: 0 }))

# USTAR, REG7: the end is two zero blocks, one zero block, or no zero block
expect (Mk.run([body.concat(List.repeat(0, 1024))], choose) |> end_of) == Ok(TwoZeroBlocks)
expect (Mk.run([body.concat(List.repeat(0, 512))], choose) |> end_of) == Ok(OneZeroBlock)
expect (Mk.run([body], choose) |> end_of) == Ok(NoZeroBlock)
expect (Mk.run([[]], choose) |> end_of) == Ok(NoZeroBlock)

# USTAR: zero bytes after the end (a record padded to 10240 bytes) are good
expect (Mk.run([body.concat(List.repeat(0, 10240 - 4608 + 4096))], choose) |> end_of) == Ok(TwoZeroBlocks)
expect (Mk.run([body.concat(List.repeat(0, 1030))], choose) |> end_of) == Ok(TwoZeroBlocks)

# API: a byte that is not zero after the end is DataAfterEnd, at its offset
expect Mk.run([archive, [0, 0, 7]], choose) == Err(DataAfterEnd({ offset: archive.len() + 2 }))
expect Mk.run([archive.concat(Mk.file("hidden", []))], choose) == Err(DataAfterEnd({ offset: archive.len() }))

# API: one zero block and then a header is LoneZeroBlock
expect Mk.run([body.concat(List.repeat(0, 512)).concat(Mk.file("hidden", []))], choose) == Err(LoneZeroBlock({ offset: body.len() + 512 }))

# USTAR: the padding of a member is skipped, whatever its bytes are
expect {
	padded = Mk.header(Mk.H.{ name: "p", size: 1 }).concat(['1']).concat(List.repeat('#', 511)).concat(Mk.file("q", [])).concat(Mk.end)
	(Mk.run([padded], Mk.skip) ?? crash "x").events |> Mk.paths == ["p", "q"]
}

# USTAR: a size of a multiple of 512 has no padding
expect {
	exact = Mk.file("a", List.repeat('a', 1024)).concat(Mk.file("b", [])).concat(Mk.end)
	got = Mk.run([exact], Mk.skip) ?? crash "x"
	got.events |> Mk.paths == ["a", "b"] and exact.len() == 512 + 1024 + 512 + 1024
}

# REG4: a skipped member gives no data; the reader keeps no data of it
expect {
	(t, events) = Tar.new(Tar.Limits.{}).push(archive.take_first(3584 + 300), Mk.skip) ?? crash "push"
	events.len() == 3 and t.finish() == Err(Truncated({ offset: 3884, inside: Data }))
}

# REG3: a collected member of 0 bytes gives Content at once
expect {
	got = Mk.run([Mk.file("e", []).concat(Mk.end)], Mk.keep) ?? crash "x"
	got.events == [Entry(entry("e", 0, 0)), Content(entry("e", 0, 0), [])]
}

# REG3: a collected member split over many chunks has all its bytes in order
expect {
	var $data = []
	for n in 0.U64..<3000 {
		$data = $data.append((n % 251).to_u8_wrap())
	}
	data = $data
	one = Mk.file("data", data).concat(Mk.end)
	got = Mk.run(Mk.chunks(one, 37), Mk.keep) ?? crash "x"
	got.events.last() == Ok(Content(entry("data", 3000, 0), data))
}

end_of : Try({ events : List(Tar.Event), summary : Tar.Summary }, Tar.Error) -> Try(Tar.End, [Failed])
end_of = |r| match r {
	Ok({ summary, .. }) => Ok(summary.end)
	Err(_) => Err(Failed)
}
