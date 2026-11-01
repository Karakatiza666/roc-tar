app [main!] { pkg: "../package/main.roc" }

import pkg.Tar
import lib/Mk as Mk
import "fixtures/gnu.tar" as gnu : List(U8)
import "fixtures/gnu.list" as gnu_list : Str
import "fixtures/pax.tar" as pax : List(U8)
import "fixtures/pax.list" as pax_list : Str
import "fixtures/ustar.tar" as ustar : List(U8)
import "fixtures/ustar.list" as ustar_list : Str
import "fixtures/roc-BgUuQGqWY94NikfEx4rBkWkgxYhngMim3ZEnD8wpM4NS.tar" as base58 : List(U8)
import "fixtures/roc-BgUuQGqWY94NikfEx4rBkWkgxYhngMim3ZEnD8wpM4NS.list" as base58_list : Str
import "fixtures/roc-HDQnwrX2Bcm8Jsf8RMC9ZdbVGwPiqD2nCLP7Zf1osfgU.tar" as header : List(U8)
import "fixtures/roc-HDQnwrX2Bcm8Jsf8RMC9ZdbVGwPiqD2nCLP7Zf1osfgU.list" as header_list : Str

main! = |_args| Ok({})

# Rule sources:
# - TOOLS: the archives of GNU tar 1.35 (--format=gnu, pax, ustar) and of
#   `roc bundle` (roc-base58 0.1.0, roc-app-header 0.1.0). scripts/fixtures.sh
#   makes them, and the .list files are their `tar -tv` (scripts/tvlist.sh).
# - REG<n>: requirement n of the registry Worker (Talon slice 111, Registry R-PU38).

# The lines of the reader, in chunks of `size` bytes, as in the .list file.
lines : List(U8), U64 -> Str
lines = |tar, size| match Mk.run(Mk.chunks(tar, size), Mk.skip) {
	Ok({ events, .. }) =>
		events
			.keep_oks(
				|e| match e {
					Entry(x) => Ok(Mk.tv_line(x))
					_ => Err(No)
				},
			)
			.append("end\n")
			|> Str.join_with("\n")

	Err(e) => Tar.err_to_str(e)
}

# TOOLS, REG2, REG6: the members of each archive are the members of `tar -tv`,
# in one chunk and in chunks of 1, 100 and 4096 bytes
expect [tar_size(gnu), 1, 100, 4096].all(|size| lines(gnu, size) == gnu_list)
expect [tar_size(pax), 1, 100, 4096].all(|size| lines(pax, size) == pax_list)
expect [tar_size(ustar), 1, 100, 4096].all(|size| lines(ustar, size) == ustar_list)
expect [tar_size(base58), 1, 100, 4096].all(|size| lines(base58, size) == base58_list)
expect [tar_size(header), 1, 100, 4096].all(|size| lines(header, size) == header_list)

tar_size : List(U8) -> U64
tar_size = |tar| tar.len()

# TOOLS, REG3: the content of one member, collected from each format
main_roc : List(U8) -> Try(List(U8), [NotFound])
main_roc = |tar| {
	got = Mk.run(Mk.chunks(tar, 333), |e| if (e.path == "pkg/main.roc") Collect(100) else Skip) ? |_| NotFound
	found = got.events.keep_oks(
		|e| match e {
			Content(_, data) => Ok(data)
			_ => Err(No)
		},
	)
	found.first().map_err(|_| NotFound)
}

expect [gnu, pax, ustar].all(|tar| main_roc(tar) == Ok("app [main!] {}\n".to_utf8()))

# TOOLS, REG7: GNU tar pads to a record of 10240 bytes after the two zero blocks
expect Mk.run([gnu], Mk.skip).map_ok(|r| (r.summary.end, r.summary.bytes)) == Ok((TwoZeroBlocks, 20480))

# TOOLS: roc bundle writes main.roc first, as a ustar file of mode 0644
expect {
	got = Mk.run([header], |e| if (e.path == "main.roc") Collect(65536) else Skip) ?? crash "x"
	match got.events {
		[Entry(first), Content(_, text), ..] => first.path == "main.roc" and first.mode == 0o644 and Str.from_utf8(text).map_ok(|s| s.starts_with("## Read and edit")) == Ok(Bool.True)
		_ => Bool.False
	}
}
