app [main!] { pkg: "../package/main.roc" }

import pkg.Tar
import lib/Mk as Mk

main! = |_args| Ok({})

# Rule sources:
# - PAX: POSIX.1-2001 pax extended headers: type `x` (next member) and `g`
#   (all next members), records "<length> <key>=<value>\n", an empty value
#   deletes the key.
# - GNU: GNU tar long name `L` and long link `K` headers (the data is the
#   name, NUL at the end).
# - REG<n>: requirement n of the registry Worker (Talon slice 111, Registry R-PU38).
# - API: the rules of README.md "API".

entries : List(U8) -> Try(List(Tar.Entry), [Failed(Tar.Error)])
entries = |bytes| match Mk.run([bytes.concat(Mk.end)], Mk.skip) {
	Ok({ events, .. }) =>
		Ok(
			events.keep_oks(
				|e| match e {
					Entry(x) => Ok(x)
					_ => Err(No)
				},
			),
		)

	Err(e) => Err(Failed(e))
}

paths : List(U8) -> Try(List(Str), [Failed(Tar.Error)])
paths = |bytes| entries(bytes).map_ok(|es| es.map(|e| e.path))

error_of : List(U8) -> Try(Tar.Error, [NoError])
error_of = |bytes| match Mk.run([bytes], Mk.skip) {
	Err(e) => Ok(e)
	Ok(_) => Err(NoError)
}

long : Str
long = "a/${Str.from_utf8(List.repeat('n', 300)) ?? ""}.roc"

# PAX, REG2: `x` path applies to the next member only
expect paths(Mk.pax('x', [("path", long)]).concat(Mk.file("short", [])).concat(Mk.file("next", []))) == Ok([long, "next"])

# PAX: a record of 9 bytes and of 10 bytes (the length has 1 or 2 digits)
expect paths(Mk.pax('x', [("path", "abc")]).concat(Mk.file("x", []))) == Ok(["abc"])
expect paths(Mk.pax('x', [("path", "abcd")]).concat(Mk.file("x", []))) == Ok(["abcd"])

# PAX: records that the reader does not know are ignored; the last record of a key wins
expect paths(Mk.pax('x', [("mtime", "1.5"), ("path", "one"), ("uname", "u"), ("path", "two")]).concat(Mk.file("x", []))) == Ok(["two"])

# PAX: a value can have "=" and spaces in it
expect paths(Mk.pax('x', [("path", "a=b c")]).concat(Mk.file("x", []))) == Ok(["a=b c"])

# PAX, REG2: `g` path applies to all next members; `x` wins over `g`
expect paths(Mk.pax('g', [("path", "global")]).concat(Mk.file("a", [])).concat(Mk.pax('x', [("path", "local")])).concat(Mk.file("b", [])).concat(Mk.file("c", []))) == Ok(["global", "local", "global"])

# PAX: an empty `x` value deletes the `g` value, so the header name applies
expect paths(Mk.pax('g', [("path", "global")]).concat(Mk.pax('x', [("path", "")])).concat(Mk.file("own", []))) == Ok(["own"])

# PAX: two `x` headers in a row are both used
expect entries(Mk.pax('x', [("path", "p")]).concat(Mk.pax('x', [("linkpath", "t")])).concat(Mk.header(Mk.H.{ name: "s", type: '2' }))).map_ok(|es| es.map(|e| (e.path, e.link))) == Ok([("p", "t")])

# PAX: `size` replaces the header size, so the reader skips the right count of bytes
expect {
	bytes = Mk.pax('x', [("size", "700")])
		.concat(Mk.header(Mk.H.{ name: "big", size: 0 }))
		.concat(List.repeat('q', 1024))
		.concat(Mk.file("after", []))
	entries(bytes).map_ok(|es| es.map(|e| (e.path, e.size))) == Ok([("big", 700), ("after", 0)])
}

# PAX: `size` that is not decimal is BadPax
expect error_of(Mk.pax('x', [("size", "7x")]).concat(Mk.file("a", []))) == Ok(BadPax({ offset: 0 }))

# PAX: a record length that is not the record is BadPax
expect {
	data = "13 path=abc\n".to_utf8()
	error_of(Mk.member(Mk.H.{ name: "p", type: 'x', size: data.len() }, data).concat(Mk.file("a", []))) == Ok(BadPax({ offset: 0 }))
}
expect {
	data = "10 path=abc\n".to_utf8()
	error_of(Mk.member(Mk.H.{ name: "p", type: 'x', size: data.len() }, data).concat(Mk.file("a", []))) == Ok(BadPax({ offset: 0 }))
}

# PAX: a record with no newline, no "=", no key, or no length is BadPax
expect {
	bad = ["9 path=ab ", "8 pathab\n", "6 =ab\n", " path=a\n", "x path=a\n", "999999999999999999999 path=a\n", "1 \n"]
	bad.all(
		|text| {
			data = text.to_utf8()
			error_of(Mk.member(Mk.H.{ name: "p", type: 'x', size: data.len() }, data).concat(Mk.file("a", []))) == Ok(BadPax({ offset: 0 }))
		},
	)
}

# PAX: a pax `path` with a NUL is BadPath
expect {
	data = "12 path=a\u(0)b\n".to_utf8()
	error_of(Mk.member(Mk.H.{ name: "p", type: 'x', size: data.len() }, data).concat(Mk.file("a", []))) == Ok(BadPath({ offset: 1024, problem: HasNul }))
}

# GNU, REG2: `L` gives the path and `K` the link target of the next member
expect paths(Mk.long('L', long).concat(Mk.file("short", [])).concat(Mk.file("next", []))) == Ok([long, "next"])
expect entries(Mk.long('K', "target/${long}").concat(Mk.header(Mk.H.{ name: "s", type: '2', link: "t" }))).map_ok(|es| es.map(|e| e.link)) == Ok(["target/${long}"])

# GNU, PAX: a pax `path` wins over a GNU long name
expect paths(Mk.long('L', "gnu").concat(Mk.pax('x', [("path", "pax")])).concat(Mk.file("h", []))) == Ok(["pax"])

# API: a meta header with no member after it is MetaWithoutMember
expect error_of(Mk.pax('x', [("path", "p")]).concat(Mk.end)) == Ok(MetaWithoutMember({ offset: 1024 }))
expect error_of(Mk.long('L', "p")) == Ok(MetaWithoutMember({ offset: 0 }))

# API: a meta header over `max_meta_bytes` is MetaTooLarge (it is not read)
expect {
	bytes = Mk.pax('x', [("path", long)]).concat(Mk.file("a", []))
	Mk.run_with(Tar.Limits.{ max_meta_bytes: 100 }, bytes, Mk.skip) == Err(MetaTooLarge({ offset: 0, size: Mk.record("path", long).len(), limit: 100 }))
}

# API: the meta values give no events of their own
expect {
	got = Mk.run([Mk.pax('g', [("comment", "c")]).concat(Mk.long('L', "l")).concat(Mk.file("x", [])).concat(Mk.end)], Mk.keep) ?? crash "x"
	got.events.len() == 2 and got.summary.members == 1
}
