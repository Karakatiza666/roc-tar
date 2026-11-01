# Builders of tar bytes for the tests, and a driver that reads them in chunks.
# This module is not in the package.
import pkg.Tar

Mk :: [].{

	## The fields of one header block. `sum` replaces the right checksum
	## field (8 bytes) when it is not empty.
	H := {
		name : Str,
		size : U64 ?? 0,
		type : U8 ?? '0',
		prefix : Str ?? "",
		link : Str ?? "",
		mode : U64 ?? 0o644,
		magic : List(U8) ?? ['u', 's', 't', 'a', 'r', 0, '0', '0'],
	}

	## A 512-byte header block with a right checksum.
	header : Mk.H -> List(U8)
	header = |h| {
		zeros = List.repeat(0, 512)
		b1 = put(zeros, 0, h.name.to_utf8())
		b2 = put(b1, 100, octal(h.mode, 8))
		b3 = put(b2, 108, octal(0, 8))
		b4 = put(b3, 116, octal(0, 8))
		b5 = put(b4, 124, octal(h.size, 12))
		b6 = put(b5, 136, octal(0, 12))
		b7 = put(b6, 156, [h.type])
		b8 = put(b7, 157, h.link.to_utf8())
		b9 = put(b8, 257, h.magic)
		block = put(b9, 345, h.prefix.to_utf8())
		fix_sum(block, 0)
	}

	## Write the right checksum of the header block at `at`.
	fix_sum : List(U8), U64 -> List(U8)
	fix_sum = |bytes, at| {
		block = put(bytes.sublist({ start: at, len: 512 }), 148, List.repeat(' ', 8))
		sum = block.fold(0.U64, |acc, b| acc + b.to_u64())
		put(bytes, at + 148, octal(sum, 7).append(' '))
	}

	## Overwrite bytes at an offset.
	put : List(U8), U64, List(U8) -> List(U8)
	put = |bytes, at, new| {
		var $out = bytes
		var $k = at
		for b in new {
			$out = $out.set($k, b) ?? $out
			$k = $k + 1
		}
		$out
	}

	## A regular file: the header, the data, the padding to 512.
	file : Str, List(U8) -> List(U8)
	file = |name, data| member(Mk.H.{ name, size: data.len() }, data)

	## A member with this header and data. `h.size` is not changed.
	member : Mk.H, List(U8) -> List(U8)
	member = |h, data| header(h).concat(data).concat(List.repeat(0, padding(data.len())))

	## The zero bytes to fill `n` up to a multiple of 512.
	padding : U64 -> U64
	padding = |n| (512 - n % 512) % 512

	## A pax header (type `x` or `g`) with these records.
	pax : U8, List((Str, Str)) -> List(U8)
	pax = |type, records| {
		data = records.fold([], |acc, (k, v)| acc.concat(record(k, v)))
		member(Mk.H.{ name: "PaxHeaders/x", size: data.len(), type }, data)
	}

	## One pax record: "<length> <key>=<value>\n".
	record : Str, Str -> List(U8)
	record = |key, value| {
		body = " ${key}=${value}\n".to_utf8()
		# The length counts its own digits.
		n = digits_len(body.len())
		"${n.to_str()}".to_utf8().concat(body)
	}

	## A GNU long name (`L`) or long link (`K`) header with the text and a NUL.
	long : U8, Str -> List(U8)
	long = |type, text| {
		data = text.to_utf8().append(0)
		member(Mk.H.{ name: "././@LongLink", size: data.len(), type }, data)
	}

	## The end marker: two zero blocks.
	end : List(U8)
	end = List.repeat(0, 1024)

	## A read of `chunks`, in order, then finish.
	run : List(List(U8)), (Tar.Entry -> Tar.Action) -> Try({ events : List(Tar.Event), summary : Tar.Summary }, Tar.Error)
	run = |chunks, choose| {
		var $t = Tar.new(Tar.Limits.{})
		var $events = []
		for c in chunks {
			(t2, evs) = $t.push(c, choose)?
			$t = t2
			$events = $events.concat(evs)
		}
		summary = $t.finish()?
		Ok({ events: $events, summary })
	}

	## A read with these limits, in one chunk.
	run_with : Tar.Limits, List(U8), (Tar.Entry -> Tar.Action) -> Try({ events : List(Tar.Event), summary : Tar.Summary }, Tar.Error)
	run_with = |limits, bytes, choose| {
		(t, events) = Tar.new(limits).push(bytes, choose)?
		summary = t.finish()?
		Ok({ events, summary })
	}

	## The bytes in chunks of `size` bytes (the last can be shorter).
	chunks : List(U8), U64 -> List(List(U8))
	chunks = |bytes, size| bytes.chunks_of(size)

	## The bytes in two chunks, split at `k`.
	split : List(U8), U64 -> List(List(U8))
	split = |bytes, k| [bytes.take_first(k), bytes.drop_first(k)]

	## Skip each member.
	skip : Tar.Entry -> Tar.Action
	skip = |_| Skip

	## Collect each member, up to 1 MiB.
	keep : Tar.Entry -> Tar.Action
	keep = |_| Collect(1048576)

	## One member in the form of `tar -tv` (scripts/tvlist.sh): "<type><mode>
	## <size> <path>", then " -> <target>" or " link to <target>".
	tv_line : Tar.Entry -> Str
	tv_line = |e| {
		type = match e.kind {
			File => "-"
			Dir => "d"
			Symlink => "l"
			HardLink => "h"
			Other(_) => "?"
		}
		link = match e.kind {
			Symlink => " -> ${e.link}"
			HardLink => " link to ${e.link}"
			_ => ""
		}
		var $mode = ""
		for k in [8, 7, 6, 5, 4, 3, 2, 1, 0] {
			on = e.mode.shr_wrap(k).bitwise_and(1) == 1
			c = if (!on) "-" else if (k % 3 == 2) "r" else if (k % 3 == 1) "w" else "x"
			$mode = $mode.concat(c)
		}
		"${type}${$mode} ${e.size.to_str()} ${e.path}${link}"
	}

	## The paths of the `Entry` events.
	paths : List(Tar.Event) -> List(Str)
	paths = |events| events.keep_oks(
		|e| match e {
			Entry(entry) => Ok(entry.path)
			_ => Err(NotEntry)
		},
	)
}

# The record length: the smallest n with n == digits(n) + body length.
digits_len : U64 -> U64
digits_len = |body| {
	var $n = body + 1
	while $n != body + $n.to_str().count_utf8_bytes() {
		$n = $n + 1
	}
	$n
}

# An octal field of `width` bytes: width - 1 digits with leading zeros, then NUL.
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
