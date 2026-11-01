app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
	pkg: "../package/main.roc",
}

import fuzz.Fuzz
import pkg.Tar

# L1 (REG2, REG3): a writer in this file makes an archive of random members.
# A path of at most 100 bytes goes in the name field; a longer path goes in
# the prefix and name fields when it can, else in a pax `path` record or a
# GNU `L` header (the `form` byte picks). The reader, in chunks of a random
# size, gives each path, size and data back, in order.

Member : { path : Str, data : List(U8), form : U8 }

Input := { members : List({ name : List(U8), data : List(U8), form : U8, depth : U8 }), chunk : U64 }.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		members: Fuzz.list(
			{
				name: Fuzz.bytes,
				data: Fuzz.bytes,
				form: Fuzz.u8,
				depth: Fuzz.u8_in(0, 40),
			}.Fuzz,
			20,
		),
		chunk: Fuzz.u64_in(1, 2000),
	}.Fuzz
}

# A path from random bytes: letters only, `depth` parts of the name, so the
# length is from 1 to about 300 bytes.
members_of : Input -> List(Member)
members_of = |input| {
	var $out = []
	var $k = 0.U64
	for m in input.members.take_first(20) {
		letters = m.name.map(|b| 'a' + b % 26)
		part = if (letters.is_empty()) ['f'] else letters.take_first(12)
		var $p = "m${$k.to_str()}".to_utf8()
		for _d in 0.U8..<m.depth {
			$p = $p.concat(['/']).concat(part)
		}
		$out = $out.append({ path: Str.from_utf8($p) ?? "bad", data: m.data, form: m.form })
		$k = $k + 1
	}
	$out
}

write : List(Member) -> List(U8)
write = |members| members.fold([], |acc, m| acc.concat(member(m))).concat(List.repeat(0, 1024))

member : Member -> List(U8)
member = |m| {
	p = m.path.to_utf8()
	n = p.len()
	size = m.data.len()
	data = m.data.concat(List.repeat(0, pad(size)))
	if n <= 100 {
		header(p, [], size, '0').concat(data)
	} else {
		# The prefix: the part before the last '/' that leaves at most 100 bytes.
		split = split_at(p)
		match split {
			Ok(k) if m.form % 3 == 0 => header(p.drop_first(k + 1), p.take_first(k), size, '0').concat(data)
			_ =>
				if m.form % 3 == 1 {
					rec = record("path", p)
					header("pax".to_utf8(), [], rec.len(), 'x').concat(rec).concat(List.repeat(0, pad(rec.len()))).concat(header("short".to_utf8(), [], size, '0')).concat(data)
				} else {
					long = p.append(0)
					header("././@LongLink".to_utf8(), [], long.len(), 'L').concat(long).concat(List.repeat(0, pad(long.len()))).concat(header("short".to_utf8(), [], size, '0')).concat(data)
				}
		}
	}
}

# The index of a '/' with at most 155 bytes before it and at most 100 after it.
split_at : List(U8) -> Try(U64, [NoSplit])
split_at = |p| {
	var $found = Err(NoSplit)
	var $k = 0.U64
	for b in p {
		if b == '/' and $k <= 155 and p.len() - $k - 1 <= 100 and $k > 0 {
			$found = Ok($k)
		}
		$k = $k + 1
	}
	$found
}

pad : U64 -> U64
pad = |n| (512 - n % 512) % 512

record : Str, List(U8) -> List(U8)
record = |key, value| {
	body = [' '].concat(key.to_utf8()).concat(['=']).concat(value).concat(['\n'])
	var $n = body.len() + 1
	while $n != body.len() + $n.to_str().count_utf8_bytes() {
		$n = $n + 1
	}
	$n.to_str().to_utf8().concat(body)
}

header : List(U8), List(U8), U64, U8 -> List(U8)
header = |name, prefix, size, type| {
	fields = name.concat(List.repeat(0, 100 - name.len()))
		.concat(octal(0o644, 8))
		.concat(octal(0, 8))
		.concat(octal(0, 8))
		.concat(octal(size, 12))
		.concat(octal(0, 12))
		.concat(List.repeat(' ', 8))
		.append(type)
		.concat(List.repeat(0, 100))
		.concat(['u', 's', 't', 'a', 'r', 0, '0', '0'])
		.concat(List.repeat(0, 80))
		.concat(prefix)
		.concat(List.repeat(0, 155 - prefix.len() + 12))
	sum = fields.fold(0.U64, |acc, b| acc + b.to_u64())
	fields.take_first(148).concat(octal(sum, 7)).append(' ').concat(fields.drop_first(156))
}

octal : U64, U64 -> List(U8)
octal = |value, width| {
	var $digits = []
	var $v = value
	for _k in 0.U64..<(width - 1) {
		$digits = $digits.prepend('0' + ($v % 8).to_u8_wrap())
		$v = $v // 8
	}
	$digits.append(0)
}

read : List(U8), U64 -> Try(List((Str, U64, List(U8))), Tar.Error)
read = |bytes, size| {
	var $t = Tar.new(Tar.Limits.{})
	var $out = []
	for c in bytes.chunks_of(size) {
		(t2, events) = $t.push(c, |_| Collect(1048576))?
		$t = t2
		for e in events {
			match e {
				Content(entry, data) => {
					$out = $out.append((entry.path, entry.size, data))
				}

				Entry(_) => {}
			}
		}
	}
	_ = $t.finish()?
	Ok($out)
}

test : Input -> Fuzz.Outcome
test = |input| {
	members = members_of(input)
	want = members.map(|m| (m.path, m.data.len(), m.data))
	size = input.chunk
	if (read(write(members), size) == Ok(want)) Fuzz.keep else crash "the members read back are not the members written"
}

target = Fuzz.target_with({
	name: "roundtrip",
	generator: Input.generator_for(Default),
	test,
	show: |input| Str.inspect(members_of(input)),
})
