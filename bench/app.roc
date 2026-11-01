app [event!] { pf: platform "platform/main.roc", tar: "../package/main.roc" }

## The measure app of roc-tar in the Cloudflare Workers platform (bench
## platform of talon/cloudflare-workers). `bench/build.sh` builds it and
## `bench/run-node.mjs` sends the requests.
##
## | Request | Work on each chunk of the request body (a `.tar.zst` bundle) |
## | --- | --- |
## | POST /run?mode=read | `Body.chunk!` only |
## | POST /run?mode=b3 | BLAKE3 of the chunk (`Native.Blake3`) |
## | POST /run?mode=zstd | zstd decode of the chunk (`Native.ZstdStream`) |
## | POST /run?mode=b3zstd | BLAKE3 and zstd decode |
## | POST /run?mode=full | BLAKE3, zstd decode and the tar reader: keep main.roc and the paths (Registry R-PU38 row 1) |
## | POST /run?mode=tarzstd | zstd decode and the tar reader (no BLAKE3) |
## | POST /run?mode=tar10 | zstd decode and 10 tar readers on the same bytes (the tar cost times 10, above the noise) |
##
## With `&raw=1` the body is a plain tar: the modes skip the zstd decode and give each body chunk to the tar
## readers (the cost of the tar reader alone, against `mode=read`).
##
## The answer: "chunks=<n> packed=<bytes> unpacked=<bytes> b3=<hex> members=<n> header=<bytes> paths=<n> path_bytes=<bytes> targets=<n> end=<end>".
import pf.Worker
import pf.Request
import pf.Response
import pf.Native
import tar.Tar

fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method(), req.segments()) {
	(POST, ["run"]) => {
		mode = req.query("mode") ?? "full"
		Ok(Response.from_text(200, run!(req, mode)))
	}

	_ => Ok(Response.from_text(404, "no route"))
}

run! : Request, Str => Str
run! = |req, mode| {
	raw = req.query("raw") == Ok("1")
	hash = mode == "b3" or mode == "b3zstd" or mode == "full"
	unzip0 = mode == "zstd" or mode == "b3zstd" or mode == "full" or mode == "tarzstd"
	untar = mode == "full" or mode == "tarzstd" or mode == "tar10"
	unzip = unzip0 or mode == "tar10"
	# The readers after the first one (mode tar10): the same work on the same bytes.
	extra = if (mode == "tar10") 9 else 0
	var $others = List.repeat(Tar.new(Tar.Limits.{ max_total_size: 1073741824 }), extra)
	b3 = Native.Blake3.new!() ?? crash "b3 new"
	z = Native.ZstdStream.open!() ?? crash "zstd open"
	var $t = Tar.new(Tar.Limits.{ max_total_size: 1073741824 })
	var $chunks = 0.U64
	var $packed = 0.U64
	var $unpacked = 0.U64
	var $header = []
	var $paths = []
	var $path_bytes = 0.U64
	var $tar_err = ""
	var $more = Bool.True
	while $more {
		match req.body().chunk!() {
			Ok(Chunk(c)) => {
				$chunks = $chunks + 1
				$packed = $packed + c.len()
				if hash {
					Native.Blake3.update!(b3, c) ?? crash "b3 update"
				}
				if unzip {
					out = if (raw) c else Native.ZstdStream.push!(z, c) ?? crash "zstd push"
					$unpacked = $unpacked + out.len()
					if extra > 0 {
						$others = $others.map(
							|o| match o.push(out, choose) {
								Ok((o2, _)) => o2
								Err(_) => crash "tar10"
							},
						)
					}
					if untar and $tar_err == "" {
						match $t.push(out, choose) {
							Ok((t2, events)) => {
								$t = t2
								for e in events {
									match e {
										Entry(entry) => {
											$paths = $paths.append(entry.path)
											$path_bytes = $path_bytes + entry.path.count_utf8_bytes()
										}

										Content(_, data) => {
											$header = data
										}
									}
								}
							}

							Err(err) => {
								$tar_err = Tar.err_to_str(err)
							}
						}
					}
				}
			}

			Ok(End) => {
				$more = Bool.False
			}

			Err(_) => crash "body read"
		}
	}
	digest = Native.Blake3.final!(b3) ?? crash "b3 final"
	# A stream with no input ends with `Truncated`: only a mode that decodes checks the end.
	closed = Native.ZstdStream.close!(z)
	if unzip and !raw and closed.is_err() {
		crash "zstd close"
	}
	end =
		if !untar {
			"-"
		} else if $tar_err != "" {
			$tar_err
		} else {
			match $t.finish() {
				Ok(s) => Str.inspect(s.end)
				Err(err) => Tar.err_to_str(err)
			}
		}
	b3_text = if (hash) hex(digest) else "-"
	n_targets = $paths.keep_if(|p| p.starts_with("targets/")).len()
	"chunks=${$chunks.to_str()} packed=${$packed.to_str()} unpacked=${$unpacked.to_str()} b3=${b3_text} members=${$paths.len().to_str()} header=${$header.len().to_str()} paths=${$paths.len().to_str()} path_bytes=${$path_bytes.to_str()} targets=${n_targets.to_str()} end=${end}"
}

## The header file: main.roc at the root, up to 1 MiB. The rest is skipped.
choose : Tar.Entry -> Tar.Action
choose = |e| if (e.path == "main.roc") Collect(1048576) else Skip

digits : List(Str)
digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]

hex : List(U8) -> Str
hex = |bytes| bytes.fold(
	"",
	|acc, b| acc.concat(digits.get(b.to_u64() // 16) ?? "?").concat(digits.get(b.to_u64() % 16) ?? "?"),
)

worker = Worker.new({
	fetch!,
})

event! : Worker.Event => Worker.Outcome
event! = |e| worker.event!(e)
