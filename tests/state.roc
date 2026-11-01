app [main!] { pkg: "../package/main.roc" }

import pkg.Tar
import lib/Mk as Mk

main! = |_args| Ok({})

# Rule sources:
# - REG9: Talon slice 111: a push whose chunk ends in a header keeps at most
#   512 + max_meta_bytes bytes of state.
# - API: README.md "Memory": held_bytes, and max_meta_bytes counts the meta
#   data that the reader reads now plus the pax and GNU values that it keeps.

long : U64 -> Str
long = |n| Str.from_utf8(List.repeat('p', n)) ?? ""

# A pax `g` path, a pax `x` path and linkpath, a GNU `L` and `K`, then the
# members.
archive : List(U8)
archive = Mk.pax('g', [("path", long(100))])
	.concat(Mk.pax('x', [("path", long(60)), ("linkpath", long(50))]))
	.concat(Mk.long('L', long(70)))
	.concat(Mk.long('K', long(40)))
	.concat(Mk.header(Mk.H.{ name: "s", type: '2', link: "t" }))
	.concat(Mk.file("a", List.repeat('a', 700)))
	.concat(Mk.pax('x', [("path", long(90))]))
	.concat(Mk.file("b", []))
	.concat(Mk.end)

meta_limit : U64
meta_limit = 600

# The most bytes of state after one push, for chunks of `size` bytes.
peak : U64 -> Try(U64, Tar.Error)
peak = |size| {
	var $t = Tar.new(Tar.Limits.{ max_meta_bytes: meta_limit })
	var $most = 0
	for c in archive.chunks_of(size) {
		(t2, _) = $t.push(c, Mk.skip)?
		$t = t2
		$most = U64.max($most, $t.held_bytes())
	}
	_ = $t.finish()?
	Ok($most)
}

# REG9, API: for each chunk size from 1 to 1100, the state after each push is
# at most 511 + max_meta_bytes
expect {
	var $bad = []
	for size in 1.U64..=1100 {
		match peak(size) {
			Ok(n) if n <= 511 + meta_limit => {}
			_ => {
				$bad = $bad.append(size)
			}
		}
	}
	$bad == []
}

# API: the bound is reached in part: a chunk of 1 byte ends in a header with
# the meta values kept (g 100, x 60 + 50, L 70, K 40 = 320, no NUL) and 511
# header bytes
expect peak(1) == Ok(511 + 320)

# API: after the member, its x, L and K values are gone; the g value stays
expect {
	(t, _) = Tar.new(Tar.Limits.{}).push(archive.take_first(4608 + 512), Mk.skip) ?? crash "push"
	t.held_bytes() == 100
}

# API: max_meta_bytes counts the kept values: g keeps 100 bytes, so an x of
# more than 500 bytes data is MetaTooLarge with a limit of 600
expect {
	bytes = Mk.pax('g', [("path", long(100))]).concat(Mk.pax('x', [("path", long(500))])).concat(Mk.file("a", []))
	size = Mk.record("path", long(500)).len()
	Mk.run_with(Tar.Limits.{ max_meta_bytes: 600 }, bytes, Mk.skip) == Err(MetaTooLarge({ offset: 1024, size: size + 100, limit: 600 }))
}

# API: a collected member counts in held_bytes with its full size, from its header
expect {
	one = Mk.file("c", List.repeat('c', 1000)).concat(Mk.end)
	(t, _) = Tar.new(Tar.Limits.{}).push(one.take_first(600), Mk.keep) ?? crash "push"
	t.held_bytes() == 1000
}

# API: a skipped member keeps nothing, in its data and in its padding
expect {
	one = Mk.file("c", List.repeat('c', 1000)).concat(Mk.end)
	(t1, _) = Tar.new(Tar.Limits.{}).push(one.take_first(600), Mk.skip) ?? crash "push"
	(t2, _) = Tar.new(Tar.Limits.{}).push(one.take_first(1520), Mk.skip) ?? crash "push"
	t1.held_bytes() == 0 and t2.held_bytes() == 0
}
