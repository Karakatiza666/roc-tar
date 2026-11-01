## A streaming reader for ustar archives (POSIX.1-1988 ustar, plus the pax
## `x` and `g` headers and the GNU `L` and `K` headers).
##
## A `Tar` is the state of one read. Give it the archive in chunks of any size
## with `push`, then call `finish` once. Each member gives one `Entry` event.
## The function that you give to `push` says, for each member, if the reader
## skips its data or collects it (with a byte limit). A collected member gives
## one `Content` event when its data is complete.
##
## The reader keeps at most one partial header (less than 512 bytes), the data
## of the member or meta header that it collects now, and the pax values that
## apply to the next member. It never keeps the data of a member that it skips.
Tar :: {
	limits : Tar.Limits,
	# The count of archive bytes that the reader consumed.
	offset : U64,
	phase : Phase,
	# The bytes of a header block that is not complete (less than 512).
	pending : List(U8),
	# The data of the member or meta header that the reader collects now.
	buf : List(U8),
	# The offset of the last header block.
	at : U64,
	members : U64,
	path_bytes : U64,
	total_size : U64,
	collected : U64,
	local : Meta,
	global : Meta,
}.{

	## The limits of one read. Each field has a default: `Tar.Limits.{}` gives
	## all of them. A limit that the archive goes over gives an error.
	##
	## | Field | Default | Error |
	## | --- | --- | --- |
	## | `max_members` | 10000 | `TooManyMembers` |
	## | `max_path_bytes` | 4096 | `PathTooLong` (also a link target) |
	## | `max_total_path_bytes` | 1048576 | `TooManyPathBytes` (the sum of the paths and link targets of all members) |
	## | `max_total_size` | 268435456 | `TotalSizeTooLarge` (the sum of the member sizes) |
	## | `max_collect_bytes` | 16777216 | `CollectTooLarge` (the sum of the sizes of the collected members) |
	## | `max_meta_bytes` | 65536 | `MetaTooLarge` (the data of one pax or GNU long name header) |
	Limits := {
		max_members : U64 ?? 10000,
		max_path_bytes : U64 ?? 4096,
		max_total_path_bytes : U64 ?? 1048576,
		max_total_size : U64 ?? 268435456,
		max_collect_bytes : U64 ?? 16777216,
		max_meta_bytes : U64 ?? 65536,
	}

	## The type of a member. `Other` has the type byte of the header, for
	## example `'3'` (character device), `'4'` (block device), `'6'` (FIFO)
	## or a vendor type.
	Kind : [File, Dir, Symlink, HardLink, Other(U8)]

	## One member. `path` and `link` are as in the archive, with no change:
	## the pax `path` or the GNU long name if there is one, else the ustar
	## prefix, `/` and name. `link` is the link target (empty for most
	## members). `mode` is the permission bits of the header. `offset` is the
	## archive offset of the ustar header of the member.
	Entry : { path : Str, kind : Tar.Kind, size : U64, mode : U32, link : Str, offset : U64 }

	## What the reader does with the data of one member. `Collect(limit)`: a
	## member of more than `limit` bytes is the error `ContentTooLarge`, never
	## a part of the data.
	Action : [Skip, Collect(U64)]

	## `Entry` comes when the header of a member is read. `Content` comes
	## after all data of a collected member is read.
	Event : [Entry(Tar.Entry), Content(Tar.Entry, List(U8))]

	## How the archive ended. `TwoZeroBlocks` is the end that POSIX
	## specifies. `NoZeroBlock`: the input ended after a complete member, with
	## no end marker.
	End : [TwoZeroBlocks, OneZeroBlock, NoZeroBlock]

	## The result of `finish`. `bytes` is the archive length.
	Summary : { end : Tar.End, members : U64, bytes : U64, total_size : U64 }

	## The errors. Each `offset` is an archive offset: of the header block for
	## a header error, of the end of the input for `Truncated`.
	Error : [
		BadChecksum({ offset : U64 }),
		BadNumber({ offset : U64, field : Str }),
		NotUstar({ offset : U64 }),
		BadPax({ offset : U64 }),
		BadPath({ offset : U64, problem : [Empty, NotUtf8, HasNul] }),
		PathTooLong({ offset : U64, bytes : U64, limit : U64 }),
		UnexpectedData({ offset : U64, size : U64 }),
		MetaWithoutMember({ offset : U64 }),
		MetaTooLarge({ offset : U64, size : U64, limit : U64 }),
		TooManyMembers({ offset : U64, limit : U64 }),
		TooManyPathBytes({ offset : U64, limit : U64 }),
		TotalSizeTooLarge({ offset : U64, limit : U64 }),
		ContentTooLarge({ offset : U64, size : U64, limit : U64 }),
		CollectTooLarge({ offset : U64, limit : U64 }),
		LoneZeroBlock({ offset : U64 }),
		DataAfterEnd({ offset : U64 }),
		Truncated({ offset : U64, inside : [Header, Data, Padding] }),
	]

	## A reader with these limits, at the start of an archive.
	new : Tar.Limits -> Tar
	new = |limits| {
		limits,
		offset: 0,
		phase: Header,
		pending: [],
		buf: [],
		at: 0,
		members: 0,
		path_bytes: 0,
		total_size: 0,
		collected: 0,
		local: no_meta,
		global: no_meta,
	}

	## Read the next chunk. A chunk can have any size and can stop in a header
	## or in member data. `choose` is called once for each member, after its
	## `Entry` is complete and before its data. The events of the chunk are
	## in archive order.
	##
	## After an error the reader is gone: do not push to it again.
	push : Tar, List(U8), (Tar.Entry -> Tar.Action) -> Try((Tar, List(Tar.Event)), Tar.Error)
	push = |tar, chunk, choose| {
		n = chunk.len()
		var $t = tar
		var $events = []
		var $i = 0
		while $i < n {
			match $t.phase {
				Ended => {
					match chunk.drop_first($i).find_first_index(|b| b != 0) {
						Ok(k) => return Err(DataAfterEnd({ offset: $t.offset + k }))
						Err(NotFound) => {
							$t = { ..$t, offset: $t.offset + (n - $i) }
							$i = n
						}
					}
				}
				Body({ left, pad, sink }) => {
					take = U64.min(left, n - $i)
					piece_buf = match sink {
						Skip => $t.buf
						_ => add($t.buf, chunk.sublist({ start: $i, len: take }))
					}
					$i = $i + take
					$t = { ..$t, offset: $t.offset + take, buf: piece_buf }
					if take == left {
						match end_body($t, sink) {
							Ok((t2, evs)) => {
								$events = $events.concat(evs)
								$t = { ..t2, phase: if (pad == 0) Header else Pad(pad) }
							}
							Err(e) => return Err(e)
						}
					} else {
						$t = { ..$t, phase: Body({ left: left - take, pad, sink }) }
					}
				}
				Pad(left) => {
					take = U64.min(left, n - $i)
					$i = $i + take
					$t = { ..$t, offset: $t.offset + take, phase: if (take == left) Header else Pad(left - take) }
				}
				_ => {
					# Header or OneZero: the reader needs a 512-byte block.
					have = $t.pending.len()
					if have == 0 and n - $i >= block_size {
						block = chunk.sublist({ start: $i, len: block_size })
						$i = $i + block_size
						match on_block({ ..$t, at: $t.offset, offset: $t.offset + block_size }, block, choose) {
							Ok((t2, evs)) => {
								$events = $events.concat(evs)
								$t = t2
							}
							Err(e) => return Err(e)
						}
					} else {
						take = U64.min(block_size - have, n - $i)
						start = if (have == 0) List.with_capacity(block_size) else $t.pending
						pending = add(start, chunk.sublist({ start: $i, len: take }))
						$i = $i + take
						if pending.len() == block_size {
							match on_block({ ..$t, pending: [], at: $t.offset - have, offset: $t.offset + take }, pending, choose) {
								Ok((t2, evs)) => {
									$events = $events.concat(evs)
									$t = t2
								}
								Err(e) => return Err(e)
							}
						} else {
							$t = { ..$t, pending, offset: $t.offset + take }
						}
					}
				}
			}
		}
		Ok(($t, $events))
	}

	## End the read: the input has no more bytes. An input that stops in a
	## header, in member data or in the padding after it is `Truncated`. A
	## pax or GNU long name header with no member after it is
	## `MetaWithoutMember`.
	finish : Tar -> Try(Tar.Summary, Tar.Error)
	finish = |tar| {
		summary = |end| Ok({ end, members: tar.members, bytes: tar.offset, total_size: tar.total_size })
		match tar.phase {
			Ended => summary(TwoZeroBlocks)
			OneZero => summary(OneZeroBlock)
			Body(_) => Err(Truncated({ offset: tar.offset, inside: Data }))
			Pad(_) => Err(Truncated({ offset: tar.offset, inside: Padding }))
			Header =>
				if tar.pending.len() > 0 {
					Err(Truncated({ offset: tar.offset, inside: Header }))
				} else if has_meta(tar.local) {
					Err(MetaWithoutMember({ offset: tar.at }))
				} else {
					summary(NoZeroBlock)
				}
		}
	}

	## `Ok({})` when the path is safe to make under a root directory: it is not
	## empty, it does not start with `/`, and no part between two `/` is `..`.
	## Other checks (duplicates, `.` parts, reserved names) are for the caller.
	check_path : Str -> Try({}, [EmptyPath, Absolute, ParentDir])
	check_path = |path| {
		if path == "" {
			Err(EmptyPath)
		} else if path.starts_with("/") {
			Err(Absolute)
		} else if path.split_on("/").any(|part| part == "..") {
			Err(ParentDir)
		} else {
			Ok({})
		}
	}

	## A text for each error, in English.
	err_to_str : Tar.Error -> Str
	err_to_str = |err| match err {
		BadChecksum({ offset }) => "tar: the header at offset ${offset.to_str()} has a bad checksum"
		BadNumber({ offset, field }) => "tar: the ${field} field of the header at offset ${offset.to_str()} is not an octal number (base-256 numbers are not supported)"
		NotUstar({ offset }) => "tar: the header at offset ${offset.to_str()} is not a ustar or GNU header (no ustar magic)"
		BadPax({ offset }) => "tar: the pax header at offset ${offset.to_str()} has a bad record"
		BadPath({ offset, problem }) => {
			why = match problem {
				Empty => "is empty"
				NotUtf8 => "is not UTF-8"
				HasNul => "has a NUL byte"
			}
			"tar: the path or link of the member at offset ${offset.to_str()} ${why}"
		}

		PathTooLong({ offset, bytes, limit }) => "tar: the path or link of the member at offset ${offset.to_str()} has ${bytes.to_str()} bytes, more than the limit ${limit.to_str()}"
		UnexpectedData({ offset, size }) => "tar: the link, directory or device at offset ${offset.to_str()} has a size of ${size.to_str()} bytes, but this type has no data"
		MetaWithoutMember({ offset }) => "tar: the pax or GNU long name header at offset ${offset.to_str()} has no member after it"
		MetaTooLarge({ offset, size, limit }) => "tar: the pax or GNU long name header at offset ${offset.to_str()} has ${size.to_str()} bytes, more than the limit ${limit.to_str()}"
		TooManyMembers({ offset, limit }) => "tar: the member at offset ${offset.to_str()} is more than the limit of ${limit.to_str()} members"
		TooManyPathBytes({ offset, limit }) => "tar: at offset ${offset.to_str()} the paths and links are more than the limit of ${limit.to_str()} bytes"
		TotalSizeTooLarge({ offset, limit }) => "tar: at offset ${offset.to_str()} the sum of the member sizes is more than the limit of ${limit.to_str()} bytes"
		ContentTooLarge({ offset, size, limit }) => "tar: the member at offset ${offset.to_str()} has ${size.to_str()} bytes, more than the collect limit ${limit.to_str()}"
		CollectTooLarge({ offset, limit }) => "tar: at offset ${offset.to_str()} the collected members are more than the limit of ${limit.to_str()} bytes"
		LoneZeroBlock({ offset }) => "tar: the zero block before offset ${offset.to_str()} is not followed by a second zero block"
		DataAfterEnd({ offset }) => "tar: a byte that is not zero at offset ${offset.to_str()}, after the end of the archive"
		Truncated({ offset, inside }) => {
			where_ = match inside {
				Header => "a header"
				Data => "the data of a member"
				Padding => "the padding after a member"
			}
			"tar: the input ends at offset ${offset.to_str()}, in ${where_}"
		}
	}
}

# The phases of the reader. `Body`: `left` data bytes, then `pad` padding
# bytes. `OneZero`: one zero block was read. `Ended`: two zero blocks.
Phase : [Header, Body({ left : U64, pad : U64, sink : Sink }), Pad(U64), OneZero, Ended]

# Where the data of the current body goes.
Sink : [Skip, Keep(Tar.Entry), PaxLocal, PaxGlobal, LongName, LongLink]

# A value of a pax or GNU header. `Clear`: a pax record with an empty value,
# so the field of the ustar header applies.
Value(a) : [Inherit, Clear, Set(a)]

Meta : { path : Value(List(U8)), link : Value(List(U8)), size : Value(U64), long_path : Value(List(U8)), long_link : Value(List(U8)) }

no_meta : Meta
no_meta = { path: Inherit, link: Inherit, size: Inherit, long_path: Inherit, long_link: Inherit }

has_meta : Meta -> Bool
has_meta = |m| m != no_meta

block_size : U64
block_size = 512

# The data of a body is complete: give its events and apply a meta header.
end_body : Tar, Sink -> Try((Tar, List(Tar.Event)), Tar.Error)
end_body = |t, sink| match sink {
	Skip => Ok((t, []))
	Keep(entry) => Ok(({ ..t, buf: [] }, [Content(entry, t.buf)]))
	LongName => Ok(({ ..t, buf: [], local: { ..t.local, long_path: Set(c_str(t.buf)) } }, []))
	LongLink => Ok(({ ..t, buf: [], local: { ..t.local, long_link: Set(c_str(t.buf)) } }, []))
	PaxLocal => {
		m = parse_pax(t.buf, t.local) ? |_| BadPax({ offset: t.at })
		Ok(({ ..t, buf: [], local: m }, []))
	}
	PaxGlobal => {
		m = parse_pax(t.buf, t.global) ? |_| BadPax({ offset: t.at })
		Ok(({ ..t, buf: [], global: m }, []))
	}
}

# One complete 512-byte block in phase Header or OneZero. `t.at` is its
# offset and `t.offset` is after it.
on_block : Tar, List(U8), (Tar.Entry -> Tar.Action) -> Try((Tar, List(Tar.Event)), Tar.Error)
on_block = |t, block, choose| {
	if block.all(|b| b == 0) {
		match t.phase {
			OneZero => Ok(({ ..t, phase: Ended }, []))
			_ =>
				if has_meta(t.local) {
					Err(MetaWithoutMember({ offset: t.at }))
				} else {
					Ok(({ ..t, phase: OneZero }, []))
				}
		}
	} else {
		match t.phase {
			OneZero => Err(LoneZeroBlock({ offset: t.at }))
			_ => on_header(t, block, choose)
		}
	}
}

# A header block that is not all zero.
on_header : Tar, List(U8), (Tar.Entry -> Tar.Action) -> Try((Tar, List(Tar.Event)), Tar.Error)
on_header = |t, h, choose| {
	at = t.at
	stored = octal(h, 148, 8) ? |_| BadChecksum({ offset: at })
	if !(checksum_ok(h, stored)) {
		return Err(BadChecksum({ offset: at }))
	}
	format = magic(h) ? |_| NotUstar({ offset: at })
	mode = octal(h, 100, 8) ? |_| BadNumber({ offset: at, field: "mode" })
	_uid = octal(h, 108, 8) ? |_| BadNumber({ offset: at, field: "uid" })
	_gid = octal(h, 116, 8) ? |_| BadNumber({ offset: at, field: "gid" })
	header_size = octal(h, 124, 12) ? |_| BadNumber({ offset: at, field: "size" })
	_mtime = octal(h, 136, 12) ? |_| BadNumber({ offset: at, field: "mtime" })
	type = h.get(156) ?? 0
	limits = t.limits
	if type == 'x' or type == 'g' or type == 'L' or type == 'K' {
		if header_size > limits.max_meta_bytes {
			return Err(MetaTooLarge({ offset: at, size: header_size, limit: limits.max_meta_bytes }))
		}
		sink = if (type == 'x') PaxLocal else if (type == 'g') PaxGlobal else if (type == 'L') LongName else LongLink
		body({ ..t, buf: List.with_capacity(header_size) }, header_size, sink, [])
	} else {
		member(t, h, format, type, mode, header_size, choose)
	}
}

# The header of a member: apply the meta values, check the limits, call
# `choose` and start the body.
member : Tar, List(U8), [Ustar, Gnu], U8, U64, U64, (Tar.Entry -> Tar.Action) -> Try((Tar, List(Tar.Event)), Tar.Error)
member = |t, h, format, type, mode, header_size, choose| {
	at = t.at
	limits = t.limits
	name = c_str(h.sublist({ start: 0, len: 100 }))
	prefix = match format {
		Ustar => c_str(h.sublist({ start: 345, len: 155 }))
		Gnu => []
	}
	ustar_path = if (prefix.is_empty()) name else prefix.concat(['/']).concat(name)
	path_bytes = resolve(t.local.path, t.local.long_path, t.global.path, ustar_path)
	link_bytes = resolve(t.local.link, t.local.long_link, t.global.link, c_str(h.sublist({ start: 157, len: 100 })))
	size = resolve(t.local.size, Inherit, t.global.size, header_size)
	if t.members + 1 > limits.max_members {
		return Err(TooManyMembers({ offset: at, limit: limits.max_members }))
	}
	path = to_text(path_bytes, at, limits.max_path_bytes)?
	if path == "" {
		return Err(BadPath({ offset: at, problem: Empty }))
	}
	link = to_text(link_bytes, at, limits.max_path_bytes)?
	all_path_bytes = t.path_bytes + path_bytes.len() + link_bytes.len()
	if all_path_bytes > limits.max_total_path_bytes {
		return Err(TooManyPathBytes({ offset: at, limit: limits.max_total_path_bytes }))
	}
	kind = kind_of(type)
	if size > 0 and type >= '1' and type <= '6' {
		return Err(UnexpectedData({ offset: at, size }))
	}
	if size > limits.max_total_size - U64.min(t.total_size, limits.max_total_size) {
		return Err(TotalSizeTooLarge({ offset: at, limit: limits.max_total_size }))
	}
	entry = { path, kind, size, mode: mode.to_u32_wrap(), link, offset: at }
	t1 = {
		..t,
		members: t.members + 1,
		path_bytes: all_path_bytes,
		total_size: t.total_size + size,
		local: no_meta,
	}
	match choose(entry) {
		Skip => body(t1, size, Skip, [Entry(entry)])
		Collect(limit) => {
			if size > limit {
				return Err(ContentTooLarge({ offset: at, size, limit }))
			}
			if size > limits.max_collect_bytes - U64.min(t.collected, limits.max_collect_bytes) {
				return Err(CollectTooLarge({ offset: at, limit: limits.max_collect_bytes }))
			}
			body({ ..t1, collected: t.collected + size, buf: List.with_capacity(size) }, size, Keep(entry), [Entry(entry)])
		}
	}
}

# Start the body of `size` bytes. A body of zero bytes ends at once.
body : Tar, U64, Sink, List(Tar.Event) -> Try((Tar, List(Tar.Event)), Tar.Error)
body = |t, size, sink, events| {
	pad = (block_size - size % block_size) % block_size
	if size == 0 {
		(t2, more) = end_body(t, sink)?
		Ok(({ ..t2, phase: Header }, events.concat(more)))
	} else {
		Ok(({ ..t, phase: Body({ left: size, pad, sink }) }, events))
	}
}

# The value of one field. A pax `x` value wins, then a GNU long name, then a
# pax `g` value, then the ustar header. An empty pax `x` value (`Clear`) also
# deletes the `g` value.
resolve : Value(a), Value(a), Value(a), a -> a
resolve = |local, gnu, global, header| {
	after_pax = |fallback| match gnu {
		Set(x) => x
		_ => fallback
	}
	match local {
		Set(x) => x
		Clear => after_pax(header)
		Inherit =>
			match global {
				Set(x) => after_pax(x)
				_ => after_pax(header)
			}
	}
}

# The bytes as text, with the checks of a path or link.
to_text : List(U8), U64, U64 -> Try(Str, Tar.Error)
to_text = |bytes, at, limit| {
	if bytes.len() > limit {
		Err(PathTooLong({ offset: at, bytes: bytes.len(), limit }))
	} else if bytes.contains(0) {
		Err(BadPath({ offset: at, problem: HasNul }))
	} else {
		# A copy: `bytes` can be a slice of a chunk, and the text must not keep the chunk.
		Ok(Str.from_utf8(bytes.release_excess_capacity()) ? |_| BadPath({ offset: at, problem: NotUtf8 }))
	}
}

kind_of : U8 -> Tar.Kind
kind_of = |type| match type {
	'0' | 0 | '7' => File
	'1' => HardLink
	'2' => Symlink
	'5' => Dir
	other => Other(other)
}

# `buf` and then `piece`, in the memory of `buf`. `buf` has the capacity of
# all its bytes (List.with_capacity). A concat to an empty list gives the
# second list back, which can be a slice of a chunk and keep all of the chunk;
# so the first byte is an append.
add : List(U8), List(U8) -> List(U8)
add = |buf, piece| match piece {
	[] => buf
	[first, .. as rest] => if (buf.is_empty()) buf.append(first).concat(rest) else buf.concat(piece)
}

# The bytes before the first NUL.
c_str : List(U8) -> List(U8)
c_str = |bytes| match bytes.find_first_index(|b| b == 0) {
	Ok(k) => bytes.take_first(k)
	Err(NotFound) => bytes
}

# `Ustar` for the magic "ustar\0", `Gnu` for "ustar  \0" (old GNU format: no
# prefix field).
magic : List(U8) -> Try([Ustar, Gnu], [NotUstar])
magic = |h| {
	m = h.sublist({ start: 257, len: 8 })
	if m.take_first(6) == ['u', 's', 't', 'a', 'r', 0] {
		Ok(Ustar)
	} else if m == ['u', 's', 't', 'a', 'r', ' ', ' ', 0] {
		Ok(Gnu)
	} else {
		Err(NotUstar)
	}
}

# The header checksum: the sum of the 512 bytes with the 8 checksum bytes as
# spaces. Unsigned bytes (POSIX), or signed bytes (some old writers).
checksum_ok : List(U8), U64 -> Bool
checksum_ok = |h, stored| {
	var $unsigned = 0.U64
	var $signed = 0.I64
	var $k = 0.U64
	for b in h {
		v = if ($k >= 148 and $k < 156) ' ' else b
		$unsigned = $unsigned + v.to_u64()
		$signed = $signed + v.to_i8_wrap().to_i64()
		$k = $k + 1
	}
	stored == $unsigned or stored.to_i64_wrap() == $signed
}

# An octal field: spaces, then octal digits, then only NUL or space. A field
# of only NUL or space is 0. A base-256 field (first byte >= 0x80) is an error.
octal : List(U8), U64, U64 -> Try(U64, [BadNumber])
octal = |h, start, len| {
	field = h.sublist({ start, len })
	var $value = 0.U64
	var $state = Lead
	for b in field {
		match $state {
			Lead =>
				if b == ' ' {
					{}
				} else if b >= '0' and b <= '7' {
					$value = (b - '0').to_u64()
					$state = Digits
				} else if b == 0 {
					$state = Tail
				} else {
					return Err(BadNumber)
				}
			Digits =>
				if b >= '0' and b <= '7' {
					$value = $value * 8 + (b - '0').to_u64()
				} else if b == 0 or b == ' ' {
					$state = Tail
				} else {
					return Err(BadNumber)
				}
			Tail =>
				if b == 0 or b == ' ' {
					{}
				} else {
					return Err(BadNumber)
				}
		}
	}
	Ok($value)
}

# The records of a pax header: "<length> <key>=<value>\n", where <length> is
# the decimal length of the whole record. The keys `path`, `linkpath` and
# `size` change `meta`. An empty value clears the key. Other keys are ignored.
parse_pax : List(U8), Meta -> Try(Meta, [BadPax])
parse_pax = |data, meta| {
	var $m = meta
	var $pos = 0.U64
	n = data.len()
	while $pos < n {
		rest = data.drop_first($pos)
		space = rest.find_first_index(|b| b == ' ') ? |_| BadPax
		if space == 0 or space > 20 {
			return Err(BadPax)
		}
		len = decimal(rest.take_first(space)) ? |_| BadPax
		if len <= space + 1 or len > rest.len() {
			return Err(BadPax)
		}
		if rest.get(len - 1) != Ok('\n') {
			return Err(BadPax)
		}
		kv = rest.sublist({ start: space + 1, len: len - space - 2 })
		{ before: key, after: value } = kv.split_first('=') ? |_| BadPax
		if key.is_empty() {
			return Err(BadPax)
		}
		$m = if key == "path".to_utf8() {
			{ ..$m, path: if (value.is_empty()) Clear else Set(value) }
		} else if key == "linkpath".to_utf8() {
			{ ..$m, link: if (value.is_empty()) Clear else Set(value) }
		} else if key == "size".to_utf8() {
			if value.is_empty() {
				{ ..$m, size: Clear }
			} else {
				size = decimal(value) ? |_| BadPax
				{ ..$m, size: Set(size) }
			}
		} else {
			$m
		}
		$pos = $pos + len
	}
	Ok($m)
}

# Decimal digits, at least one, with no overflow.
decimal : List(U8) -> Try(U64, [BadNumber])
decimal = |digits| {
	if digits.is_empty() {
		return Err(BadNumber)
	}
	var $value = 0.U64
	for b in digits {
		if b < '0' or b > '9' {
			return Err(BadNumber)
		}
		$value = match $value.times_try(10) {
			Ok(v) =>
				match v.plus_try((b - '0').to_u64()) {
					Ok(w) => w
					Err(_) => return Err(BadNumber)
				}
			Err(_) => return Err(BadNumber)
		}
	}
	Ok($value)
}
