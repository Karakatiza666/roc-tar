app [main!] { pkg: "../package/main.roc" }

import pkg.Tar
import lib/Mk as Mk

main! = |_args| Ok({})

# Rule sources:
# - REG<n>: requirement n of the registry Worker (Talon slice 111, Registry R-PU38).
# - API: the rules of README.md "API" (the limits and their defaults).

three : List(U8)
three = Mk.file("a", "1".to_utf8()).concat(Mk.file("bb", "22".to_utf8())).concat(Mk.file("ccc", "333".to_utf8())).concat(Mk.end)

members : Try({ events : List(Tar.Event), summary : Tar.Summary }, Tar.Error) -> Try(U64, [Failed])
members = |r| match r {
	Ok({ summary, .. }) => Ok(summary.members)
	Err(_) => Err(Failed)
}

# API: the defaults
expect {
	l = Tar.Limits.{}
	(l.max_members, l.max_path_bytes, l.max_total_path_bytes, l.max_total_size, l.max_collect_bytes, l.max_meta_bytes)
		== (10000, 4096, 1048576, 268435456, 16777216, 65536)
}

# REG5: max_members: equal is good, one more is TooManyMembers at the header of that member
expect members(Mk.run_with(Tar.Limits.{ max_members: 3 }, three, Mk.skip)) == Ok(3)
expect Mk.run_with(Tar.Limits.{ max_members: 2 }, three, Mk.skip) == Err(TooManyMembers({ offset: 2048, limit: 2 }))

# REG5: max_path_bytes: for the path and for the link target
expect members(Mk.run_with(Tar.Limits.{ max_path_bytes: 3 }, three, Mk.skip)) == Ok(3)
expect Mk.run_with(Tar.Limits.{ max_path_bytes: 2 }, three, Mk.skip) == Err(PathTooLong({ offset: 2048, bytes: 3, limit: 2 }))
expect Mk.run_with(Tar.Limits.{ max_path_bytes: 2 }, Mk.header(Mk.H.{ name: "s", type: '2', link: "abc" }), Mk.skip) == Err(PathTooLong({ offset: 0, bytes: 3, limit: 2 }))

# REG5: max_total_path_bytes: the sum of the paths and links (1 + 2 + 3 = 6)
expect members(Mk.run_with(Tar.Limits.{ max_total_path_bytes: 6 }, three, Mk.skip)) == Ok(3)
expect Mk.run_with(Tar.Limits.{ max_total_path_bytes: 5 }, three, Mk.skip) == Err(TooManyPathBytes({ offset: 2048, limit: 5 }))
expect {
	link = Mk.header(Mk.H.{ name: "s", type: '2', link: "abc" })
	Mk.run_with(Tar.Limits.{ max_total_path_bytes: 3 }, link, Mk.skip) == Err(TooManyPathBytes({ offset: 0, limit: 3 }))
}

# API: max_total_size: the sum of the sizes (1 + 2 + 3 = 6), checked at the header, before the data
expect members(Mk.run_with(Tar.Limits.{ max_total_size: 6 }, three, Mk.skip)) == Ok(3)
expect Mk.run_with(Tar.Limits.{ max_total_size: 5 }, three, Mk.skip) == Err(TotalSizeTooLarge({ offset: 2048, limit: 5 }))
expect {
	# A size bomb: the header says 8 GiB - 1, and no data follows.
	bomb = Mk.header(Mk.H.{ name: "bomb", size: 8589934591 })
	Tar.new(Tar.Limits.{}).push(bomb, Mk.skip).map_ok(|_| {}) == Err(TotalSizeTooLarge({ offset: 0, limit: 268435456 }))
}

# REG3: Collect(limit): a member over the limit is ContentTooLarge (no cut data)
expect Mk.run([three], |e| if (e.path == "ccc") Collect(2) else Skip) == Err(ContentTooLarge({ offset: 2048, size: 3, limit: 2 }))
expect {
	got = Mk.run([three], |e| if (e.path == "ccc") Collect(3) else Skip) ?? crash "x"
	got.events.last().map_ok(
		|e| match e {
			Content(_, data) => data
			_ => []
		},
	)
		== Ok("333".to_utf8())
}

# API: max_collect_bytes: the sum of the collected sizes (1 + 2 + 3 = 6)
expect members(Mk.run_with(Tar.Limits.{ max_collect_bytes: 6 }, three, Mk.keep)) == Ok(3)
expect Mk.run_with(Tar.Limits.{ max_collect_bytes: 5 }, three, Mk.keep) == Err(CollectTooLarge({ offset: 2048, limit: 5 }))

# API: a skipped member does not count for max_collect_bytes
expect members(Mk.run_with(Tar.Limits.{ max_collect_bytes: 0 }, three, Mk.skip)) == Ok(3)

# API: max_meta_bytes: equal is good
expect {
	pax = Mk.pax('x', [("path", "abc")])
	size = Mk.record("path", "abc").len()
	members(Mk.run_with(Tar.Limits.{ max_meta_bytes: size }, pax.concat(three), Mk.skip)) == Ok(3)
}
