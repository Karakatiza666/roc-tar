# roc-tar

A streaming reader for tar archives (ustar, pax, GNU long names) in pure Roc. No effects, no dependencies. Give it the archive in chunks of any size. It gives an event for each member, and keeps no data of a member that you skip.

It is made for the registry Worker of [Talon](https://github.com/Karakatiza666/talon) (Registry R-PU38): a `.tar.zst` Roc bundle goes through BLAKE3 and a zstd decoder in chunks, and this reader keeps only the header file and the list of paths.

## API

One module, `Tar`. The value of type `Tar` is the state of one read.

| Function | Type |
| --- | --- |
| `Tar.new` | `Tar.Limits -> Tar` |
| `Tar.push` | `Tar, List(U8), (Tar.Entry -> Tar.Action) -> Try((Tar, List(Tar.Event)), Tar.Error)` |
| `Tar.finish` | `Tar -> Try(Tar.Summary, Tar.Error)` |
| `Tar.check_path` | `Str -> Try({}, [EmptyPath, Absolute, ParentDir])` |
| `Tar.check_portable_path` | `Str -> Try({}, [EmptyPath, TooLong, Absolute, DriveLetter, ParentDir, DotPart, ReservedName, EndsWithSpace, EndsWithPeriod, ReservedChar(U8), Backslash])` |
| `Tar.roc_accepts` | `Tar.Entry -> Try({}, [UnsupportedType(U8), Path(...), Link([Absolute, DriveLetter, ParentDir, DotPart])])` (`Path` has the errors of `check_portable_path`) |
| `Tar.held_bytes` | `Tar -> U64` |
| `Tar.err_to_str` | `Tar.Error -> Str` |

| Type | Definition |
| --- | --- |
| `Tar.Entry` | `{ path : Str, kind : Tar.Kind, size : U64, mode : U32, link : Str, offset : U64, type_byte : U8 }` |
| `Tar.Kind` | `[File, Dir, Symlink, HardLink, Other(U8)]` |
| `Tar.Action` | `[Skip, Collect(U64)]` |
| `Tar.Event` | `[Entry(Tar.Entry), Content(Tar.Entry, List(U8))]` |
| `Tar.End` | `[TwoZeroBlocks, OneZeroBlock, NoZeroBlock]` |
| `Tar.Summary` | `{ end : Tar.End, members : U64, bytes : U64, total_size : U64 }` |
| `Tar.Limits` | A nominal record. Each field has a default, so `Tar.Limits.{}` gives all defaults (table below). |

### How to read

1. `Tar.new(limits)`.
2. For each chunk: `tar.push(chunk, choose)`. A chunk can stop at any byte: in a header, in a pax record, in member data, in padding. An empty chunk is good.
3. At the end of the input: `tar.finish()`.

`choose` is called once for each member, when its header is complete, before its data. It gives `Skip` (the reader counts the data bytes and keeps none) or `Collect(limit)` (the reader keeps the data, and gives `Content(entry, bytes)` after the last byte). A member of more than `limit` bytes is `ContentTooLarge` at its header: the reader never gives a part of the data.

| Event | When |
| --- | --- |
| `Entry(entry)` | The header of a member is read. One for each member, in archive order. |
| `Content(entry, bytes)` | All data of a collected member is read. A member of 0 bytes gives it at once. |

After the end, the caller can push more chunks: zero bytes are good (GNU tar pads to 10240 bytes), and a byte that is not zero is `DataAfterEnd`. So the caller can push every chunk that it hashes, also when it has all that it needs.

After an error, do not push again. The caller can still hash the rest of the stream.

### Entry fields

| Field | Value |
| --- | --- |
| `path` | As in the archive, with no change (no removal of `./`, `//` or `..`). The pax `path` if there is one, else the GNU long name, else the pax global `path`, else the ustar prefix, `/` and name. |
| `kind` | `File` for the type bytes `0`, NUL and `7`. `HardLink` `1`, `Symlink` `2`, `Dir` `5`. Each other type byte is `Other(byte)` (`3` character device, `4` block device, `6` FIFO, vendor types). |
| `size` | The pax `size` if there is one, else the header size. |
| `mode` | The permission bits of the header (octal field). |
| `link` | The link target (`linkpath`, GNU `K`, or the header field). Empty for most members. |
| `offset` | The archive offset of the ustar header of the member. |
| `type_byte` | The type byte (offset 156) of the ustar header of the member, as it is. After a pax `x` or `g` or a GNU `L` or `K` header, it is the byte of the member header, not of the meta header. `kind` gives `File` for `0`, NUL and `7`, so use `type_byte` to tell them apart (`roc unbundle` refuses `7`). |

### Limits

| Field | Default | Error | What it limits |
| --- | --- | --- | --- |
| `max_members` | 10000 | `TooManyMembers` | The count of members |
| `max_path_bytes` | 4096 | `PathTooLong` | The bytes of one path or one link target |
| `max_total_path_bytes` | 1048576 | `TooManyPathBytes` | The sum of the bytes of all paths and link targets (the memory of a member list) |
| `max_total_size` | 268435456 | `TotalSizeTooLarge` | The sum of the member sizes. Checked at each header, before the data. |
| `max_collect_bytes` | 16777216 | `CollectTooLarge` | The sum of the sizes of the collected members |
| `max_meta_bytes` | 65536 | `MetaTooLarge` | The data of the pax or GNU long name header that the reader reads now, plus the pax and GNU values that it keeps for the next members. Checked at each meta header, before its data. |

Example: `Tar.new(Tar.Limits.{ max_members: 2000, max_total_size: 524288000 })`.

### Errors

`Tar.Error` is a closed tag union. `Tar.err_to_str` gives an English text for each.

| Error | Cause |
| --- | --- |
| `BadChecksum({ offset })` | The header checksum is not the sum of the header bytes (unsigned or signed) |
| `BadNumber({ offset, field })` | A number field (`mode`, `uid`, `gid`, `size`, `mtime`) is not octal. A base-256 number (first byte 0x80 or more) is also this error. |
| `NotUstar({ offset })` | No ustar magic: not `ustar\0` (POSIX) and not `ustar  \0` (old GNU). A V7 header is refused. |
| `BadPax({ offset })` | A pax record is not `<length> <key>=<value>\n` with the right length, or a pax `size` is not decimal |
| `BadPath({ offset, problem })` | A path is empty, or a path or link is not UTF-8 or has a NUL byte |
| `PathTooLong({ offset, bytes, limit })` | Limit `max_path_bytes` |
| `UnexpectedData({ offset, size })` | A hard link, symbolic link, device, directory or FIFO (types `1` to `6`) with a size that is not 0. Readers do not agree on its data, so the reader refuses it. |
| `MetaWithoutMember({ offset })` | A pax `x` or GNU `L`/`K` header with no member after it |
| `MetaTooLarge({ offset, size, limit })` | Limit `max_meta_bytes`. `size` is the data of the new meta header plus the values that the reader keeps. |
| `TooManyMembers({ offset, limit })` | Limit `max_members` |
| `TooManyPathBytes({ offset, limit })` | Limit `max_total_path_bytes` |
| `TotalSizeTooLarge({ offset, limit })` | Limit `max_total_size` |
| `ContentTooLarge({ offset, size, limit })` | The limit of `Collect(limit)` |
| `CollectTooLarge({ offset, limit })` | Limit `max_collect_bytes` |
| `LoneZeroBlock({ offset })` | One zero block, then a header. GNU tar stops at the zero block and does not read the rest, so the reader refuses it. |
| `DataAfterEnd({ offset })` | A byte that is not zero after the two zero blocks |
| `Truncated({ offset, inside })` | The input ends in a header, in member data or in the padding after it (`inside` is `Header`, `Data` or `Padding`) |

### The end

`finish` gives `Summary.end`:

| `end` | Input |
| --- | --- |
| `TwoZeroBlocks` | The end that POSIX specifies (roc bundle and GNU tar write it) |
| `OneZeroBlock` | One zero block, then the end of the input |
| `NoZeroBlock` | The end of the input after a complete member. The reader cannot see a member list that was cut at a member boundary, so the caller decides. |

### Paths

The reader gives each path as it is in the archive. Three checks are for the caller:

| Function | `Ok({})` when |
| --- | --- |
| `Tar.check_path` | The path is safe to make under a root directory: not empty, no leading `/`, and no part between two `/` that is `..` |
| `Tar.check_portable_path` | `roc unbundle` accepts the path on each OS: all rules below |
| `Tar.roc_accepts` | `roc unbundle` accepts the member on each OS: its type, its path and its link target (see "Member types of roc unbundle") |

`check_portable_path` applies the rules of `pathInvalidReason` in `src/unbundle/unbundle.zig` of roc-lang/roc (commit `76258c1267204e31e58d8edcdd3ede6163ef60db`), in the same order, and gives the first rule that fails. `roc unbundle` refuses an archive with such a path, and `roc bundle` applies the same function to each path that it writes. A part is the text between two separators, `/` or `\`; an empty part is skipped (`std.mem.tokenizeAny`).

| Order | Rule | Error | roc reason |
| --- | --- | --- | --- |
| 1 | The path is empty | `EmptyPath` | `empty_path` |
| 2 | More than 255 bytes (`TAR_PATH_MAX_LENGTH`, `src/unbundle/format.zig`) | `TooLong` | `path_too_long` |
| 3 | The first byte is `/` or `\` | `Absolute` | `absolute_path` |
| 4 | The second byte is `:` (`C:x`, also `1:`) | `DriveLetter` | `absolute_path` |
| 5 | A part is `..` | `ParentDir` | `path_traversal` |
| 6 | A part is `.` | `DotPart` | `current_directory_reference` |
| 7 | The text before the first `.` of a part is `CON`, `PRN`, `AUX`, `NUL`, `COM1` to `COM9` or `LPT1` to `LPT9`, in any case (`con.roc` and `aux.tar.gz` fail, `x.CON`, `COM0` and `CON .roc` pass) | `ReservedName` | `windows_reserved_name` |
| 8 | A part ends with a space | `EndsWithSpace` | `component_ends_with_space` |
| 9 | A part ends with `.` | `EndsWithPeriod` | `component_ends_with_period` |
| 10 | A byte is NUL, `<`, `>`, `:`, `"`, `\|`, `?` or `*` | `ReservedChar(byte)` | `windows_reserved_char` |
| 11 | A byte is `\` | `Backslash` | `contained_backslash_on_unix` (on Windows, roc bundle writes `/` for it, so no archive has it) |

Rules 10 and 11 give the first such byte of the path. `roc unbundle` checks a symbolic link target with other rules (`linkTargetUnbundleErr`), but a roc bundle has no links. Duplicate paths, and two paths that differ only in case, are for the caller.

### Member types of roc unbundle

`roc unbundle` (`unbundleStream` in `src/unbundle/unbundle.zig`, roc-lang/roc commit `76258c1267204e31e58d8edcdd3ede6163ef60db`) reads with `std.tar.Iterator` of Zig 0.17.0 (`Iterator.next` in `lib/std/tar.zig`), with no diagnostics. `Tar.roc_accepts(entry)` applies its rules in this order and gives the first rule that fails:

| Order | Rule | Error |
| --- | --- | --- |
| 1 | `type_byte` is not `0`, NUL, `5` or `2`. Zig gives `error.TarUnsupportedHeader` for each other member type: `1` (hard link), `3`, `4`, `6`, `7` (contiguous file), `S` and vendor types. | `UnsupportedType(byte)` |
| 2 | `check_portable_path(path)` fails (`pathHasUnbundleErr`, for each member) | `Path(error)` |
| 3 | Type `2` only: the link target starts with `/` or `\`, its second byte is `:`, or a part between `/` or `\` is `..` (`ParentDir`) or `.` (`DotPart`). These are the rules of `linkTargetUnbundleErr` on Unix and on Windows together. | `Link(error)` |

| Type byte | roc unbundle |
| --- | --- |
| `0`, NUL | Makes the file |
| `5` | Makes the directory |
| `2` | Checks the target, then makes nothing (a TODO in roc) |
| `x`, `g`, `L`, `K` | Meta headers, read by the iterator (never an `Entry`) |
| Each other byte, also `7` | Refuses the archive |

`roc bundle` writes only type `0`.

### Memory

| Data | Kept |
| --- | --- |
| A skipped member | Nothing: the reader counts its bytes |
| A header that two chunks split | At most 511 bytes, in a buffer of its own |
| A collected member | Its bytes, in a buffer of its own of `size` bytes, from its header to its last byte |
| A pax or GNU long name header that the reader reads now | A buffer of its data size |
| The pax `x` and GNU `L`/`K` values for the next member, and the pax `g` values | A copy of each value (`path`, `linkpath`, long name, long link), with no NUL. The `x`, `L` and `K` values go at the next member; the `g` values stay. |
| Path and link texts | A copy of their bytes |

The bound: at each meta header, the reader checks that its data size plus the values that it keeps is at most `max_meta_bytes`. So between two pushes, when no member is collected, the state is at most 511 + `max_meta_bytes` bytes (plus the fixed fields of the record): 511 bytes of a split header and the kept values, or 0 header bytes and a meta buffer with the kept values. A collected member adds its size. `Tar.held_bytes(tar)` gives this count. `tests/state.roc` checks it after each push, for chunks of 1 to 1100 bytes of an archive with pax `g` and `x`, GNU `L` and `K`: the most is 511 + 320 with 1-byte chunks.

The reader never keeps a slice of a chunk: a Roc `List.sublist` or `Str.from_utf8` can share the memory of the whole chunk, so the reader copies the bytes that it keeps. Without this copy, the list of paths kept a reference to a decoded chunk for each member, and the live memory of the measure app was 6 MB more (see Measurement).

## Tar formats

`roc bundle` (roc `src/bundle/bundle.zig`) writes the archive with the Zig standard library `std.tar.Writer`: POSIX ustar headers (magic `ustar\0`, version `00`), regular files only (type `0`, mode 0644, mtime 0), each path in the name field or split at a `/` into the prefix and name fields, and two zero blocks at the end (`finishPedantically`). When a path does not fit in prefix and name (a part of more than 100 bytes), the Zig writer writes a GNU `L` header. `roc unbundle` reads with `std.tar.Iterator`, which reads pax `x` and `g` and GNU `L` and `K`. roc refuses a path of more than 255 bytes.

All 36 bundles in the local roc cache (2 KB to 100 MB unpacked) have only type `0`, magic `ustar\0` `00`, no prefix field, two zero blocks and nothing after them.

| Format | Support | Why |
| --- | --- | --- |
| POSIX ustar (name, prefix) | Yes | roc bundle writes it |
| GNU `L` and `K` (long name, long link) | Yes | The Zig writer of roc bundle writes `L` for a long path part. GNU tar `--format=gnu` writes them. |
| pax `x` (`path`, `linkpath`, `size`) | Yes | GNU tar `--format=pax` and bsdtar write them. Other keys are ignored. An empty value deletes the key. |
| pax `g` (global) | Yes, for `path`, `linkpath` and `size` | POSIX. The registry asks for it. |
| Old GNU header (magic `ustar  \0`) | Yes, with no prefix field | GNU tar `--format=gnu` writes it |
| V7 (no magic) | No: `NotUstar` | No current tool writes it; with no magic, a random block can look like a header |
| Base-256 numbers (GNU, for sizes of 8 GiB or more) | No: `BadNumber` | An octal size field holds sizes to 8 GiB, more than each limit here. A pax `size` record gives a larger size if a writer needs it. |
| GNU sparse (`S`), volume (`V`), multi-volume (`M`) | As `Other(byte)`, data skipped by its size | The caller decides; the registry refuses each member that is not a file |

## Usage

Add the release to the header of your app, package or platform:

```roc
tar: "https://github.com/Karakatiza666/roc-tar/releases/download/0.0.1/FGAUE1Pds7Fvd48GkrAYd9rRUpztew8bgUZjUrKPGyo7.tar.zst",
```

Then, for example, the header file and the paths of an archive that comes in chunks:

```roc
import tar.Tar

## main.roc (to 1 MiB) and the path of each member.
header_and_paths : List(List(U8)) -> Try({ header : List(U8), paths : List(Str) }, Tar.Error)
header_and_paths = |chunks| {
	choose = |e| if e.path == "main.roc" Collect(1048576) else Skip
	var $t = Tar.new(Tar.Limits.{ max_members: 2000 })
	var $header = []
	var $paths = []
	for chunk in chunks {
		(t2, events) = $t.push(chunk, choose)?
		$t = t2
		for event in events {
			match event {
				Entry(e) => {
					$paths = $paths.append(e.path)
				}

				Content(_, bytes) => {
					$header = bytes
				}
			}
		}
	}
	_summary = $t.finish()?
	Ok({ header: $header, paths: $paths })
}
```

`bench/app.roc` is a complete Worker: BLAKE3, zstd decode and this reader on each chunk of a request body.

## Tests

| Layer | Files | Tool |
| --- | --- | --- |
| L0 | `tests/header.roc` (fields, types, checksum, octal, magic, paths, `check_path`), `tests/stream.roc` (a split at each byte, chunks of 1 to 1100 bytes, a cut at each byte, the end blocks, padding), `tests/meta.roc` (pax `x` and `g`, GNU `L` and `K`), `tests/limits.roc` (each limit), `tests/portable.roc` (each rule of `check_portable_path` and `roc_accepts`, and the verdicts of `roc bundle` in `tests/fixtures/portable.tsv`, made by `scripts/portable-oracle.sh`), `tests/state.roc` (the state bound), `tests/fixtures.roc` (archives of GNU tar 1.35 in the gnu, pax and ustar formats and of roc bundle, against their `tar -tv`) | `roc test` |
| L1 | `fuzz/split.roc` (on mutated archives and on any bytes: no crash, and the chunk sizes do not change the result), `fuzz/roundtrip.roc` (random members written with ustar prefix, pax `path` or GNU `L`, read back in random chunks) | [roc-fuzz](https://github.com/lukewilliamboswell/roc-fuzz) 0.4.3 |
| Real bundles | `scripts/bundles.sh [ROC] [FILE.tar.zst...]`: `tests/tools/tarlist.roc` (basic-cli, reads standard input in chunks) against GNU `tar -tv`, for the fixtures and each bundle in the roc cache | basic-cli 0.26.0, GNU tar |
| Mutations | `scripts/mutants.py ROC [ID...]`: 17 changes to tricky rules of `package/Tar.roc`; each must make a test fail | `roc test` |

`scripts/test.sh [ROC [FUZZ_ROC]]` runs `roc check`, `roc fmt --check`, the L0 tests and the L1 targets. `scripts/fixtures.sh` makes `tests/fixtures/` again. Use the nightly in `.roc-version` (the nightly of the Cloudflare Workers platform 0.0.2). CI (`.github/workflows/ci.yml`) runs the same checks on that nightly. The package also checks and passes `tests/header.roc` on `nightly-2026-10-14-38a3029`.

`scripts/bundles.sh` on 2026-11-01: the 5 fixtures and the 36 bundles of the local roc cache (2 KB to 100 MB unpacked) give the same members as GNU tar 1.35.

### Mutations

`scripts/mutants.py` on 2026-11-01 (nightly-2026-10-31-f7bef6b). Each mutant changes one rule in `package/Tar.roc`.

| Id | Mutant | Files with a failed test |
| --- | --- | --- |
| M1 | chunk split: a partial header takes a whole block from the next chunk | fixtures.roc, stream.roc |
| M2 | 512 padding: a size that is a multiple of 512 gets one more block | stream.roc |
| M3 | checksum: the last checksum byte is not counted as a space | fixtures.roc |
| M4 | pax length: the value keeps the newline | fixtures.roc, meta.roc, stream.roc |
| M5 | pax: an empty `x` value does not delete the `g` value | meta.roc |
| M6 | end: a byte after the two zero blocks is accepted | stream.roc |
| M7 | end: a lone zero block, then a header, is read as a member | stream.roc |
| M8 | ustar: the prefix and the name are joined with no `/` | fixtures.roc, header.roc |
| M9 | truncation: an input that ends in the padding is a clean end | stream.roc |
| M10 | collect: a member of limit + 1 bytes is collected | limits.roc |
| M11 | portable path: a backslash does not end a part | portable.roc |
| M12 | portable path: a reserved name is the whole part, not the text before the first `.` | portable.roc |
| M13 | portable path: 256 bytes are good | portable.roc |
| M14 | state: `max_meta_bytes` does not count the kept pax and GNU values | state.roc |
| M15 | type byte: NUL is given as `0` (the byte of the kind, not of the header) | header.roc, meta.roc |
| M16 | `roc_accepts`: `7` is accepted, as its kind is `File` | portable.roc |
| M17 | `roc_accepts`: a link target is checked with `/` as the only separator | portable.roc |

All 17 are killed. M15 to M17: 2026-11-02, the same nightly. M3 is killed only by the fixtures: the test writer puts a space in the last checksum byte, and GNU tar and Zig put a NUL there.

## Measurement

The question: in the registry Worker (Registry R-PU38), does the tar step add a material cost to BLAKE3 and the zstd decode? `bench/` has the measure app and its runners. 2026-11-01, Cloudflare Workers platform 0.0.2 (bench host, `talon/cloudflare-workers` at 241182c), nightly-2026-10-31-f7bef6b, Node 26.7.0, workerd 2026-10-12, Linux x86-64, 24 cores with a load average of 10 to 17 from other work, so the times move by about 10 % (more in workerd).

```sh
bench/build.sh                                                  # .work/bench/app.wasm (CFW= the platform repository)
node bench/run-node.mjs .work/bench/app.wasm 5 FILE.tar.zst...  # Node, the runner of the platform (makeHandler)
WORKERD=<workerd> node bench/run-workerd.mjs 3 FILE.tar.zst...  # workerd, the client times each request
```

The app reads the request body (the bundle) with `Body.chunk!` and does the work of its mode on each chunk. `full` is the work of R-PU38 row 1: BLAKE3, zstd decode, and the tar reader that keeps `main.roc` and the paths. `tar10` runs 10 tar readers on the same decoded bytes, so the tar cost is 10 times larger than the noise. With a plain `.tar` file (`&raw=1`), the app gives each body chunk to the tar readers with no zstd decode: the cost of the tar reader alone. Each Node request has a new instance, so its wasm memory is the peak of that request. The raw outputs are in `bench/results/`.

Bundles: roc-parser 2.0.0 (`7CLzCK6q`, 0.13 MB packed, 0.5 MB unpacked, 9 members), basic-cli 0.26.0 (`GddgvsGj`, 22.3 MB, 79 MB, 207 members), and basic-webserver 0.19.0 (`4KBAoiBa`, the largest bundle in the roc cache, 28.1 MB, 95 MB, 242 members).

### Node (CPU ms of the process, median of 5)

| Mode | roc-parser | basic-cli 0.26.0 | basic-webserver 0.19.0 |
| --- | --- | --- | --- |
| read (body only) | 0.8 | 5.0 | 6.3 |
| b3 | 0.8 | 39.1 | 51.4 |
| zstd | 13.0 | 1436 | 2113 |
| b3zstd | 11.5 | 1620 | 2015 |
| tarzstd | 11.6 | 1593 | 1942 |
| tar10 | 18.4 | 1436 | 1863 |
| full | 18.0 | 1439 | 1922 |
| wasm memory MB, b3zstd / full | 3.2 / 3.2 | 8.2 / 8.2 | 8.9 / 8.9 |
| live peak MB, b3zstd / full | 0.9 / 0.9 | 5.2 / 5.3 | 5.2 / 5.2 |

The differences between the zstd modes are noise (10 tar readers are not slower than one). The tar reader alone, on the plain tar (wall ms, median of 7):

| Mode | roc-parser (0.5 MB) | basic-cli (79 MB) | basic-webserver (95 MB) |
| --- | --- | --- | --- |
| read | 0.8 | 21.9 | 26.1 |
| one tar reader | 0.9 | 25.8 | 27.7 |
| 10 tar readers | 1.6 | 30.1 | 34.3 |
| tar cost of one reader (from 10 readers) | 0.08 | 0.8 | 0.8 |

### workerd (wall ms of the client, median of 3; plain tar: median of 5)

| Mode | roc-parser | basic-cli 0.26.0 | basic-webserver 0.19.0 |
| --- | --- | --- | --- |
| read | 11.4 | 155 | 175 |
| b3 | 10.4 | 186 | 268 |
| zstd | 20.0 | 4619 | 3636 |
| b3zstd | 15.6 | 5769 | 4750 |
| full | 18.2 | 3617 | 5690 |
| plain tar: read / one reader / 10 readers | 8.4 / 9.6 / 10.5 | 414 / 430 / 492 | 504 / 748 / 698 |
| tar cost of one reader (from 10 readers) | 0.2 | 7.8 | 19 |
| wasm memory MB, full | 3.1 | 5.9 | 5.8 |

### Result

| Question | Answer |
| --- | --- |
| CPU of the tar step | At most about 1 ms (Node) and 20 ms (workerd, an upper bound in the noise) for 79 to 95 MB unpacked. BLAKE3 and zstd take 1.4 to 2.1 s (Node) and 3.6 to 5.8 s (workerd) for the same bundles. The tar step is less than 1 % of that, and less than 0.1 % of the 30 s CPU of a Workers Paid request. |
| Memory of the tar step | 0.1 MB of live peak (5.2 to 5.3 MB) and no more wasm memory (8.2 MB in Node, under 6 MB in workerd), far inside the 128 MB isolate (R-WH9). |
| Why it is small | The reader skips data by a count: it reads 512 bytes for each member header and never reads the bytes of a skipped member. |
| Is the cost immaterial | Yes. |

Before the copy rule of the Memory section, `Str.from_utf8` and `List.concat` gave texts and lists that shared the decoded chunks, and the paths kept the chunks: the live peak of `tarzstd` for basic-cli was 11.2 MB in place of 5.3 MB. The copy fixed it.

Not about tar, for the registry: the zstd decode of the platform is the cost. It runs at about 40 to 60 MB of output a second in Node and slower in workerd. The first estimate of R-PU38 ("much less than 1 s" for basic-cli) is low by 2 to 5 times; the time is still far inside 30 s.

## Release

`.github/workflows/release.yml` makes a release with [roc-lang/release-package](https://github.com/roc-lang/release-package): `gh workflow run release.yml --ref main -f release_version=X.Y.Z`. The tag is `X.Y.Z` with no prefix, and the one package asset is `<hash>.tar.zst` from `roc bundle`.

The hash is the hash of `roc bundle main.roc Tar.roc` of this commit with nightly-2026-10-31-f7bef6b (the bundle step of `release.yml`). The release asset has the same name when `package/` does not change. Check the name on the release page before you use the URL.

## License

UPL-1.0, see `LICENSE`.
