app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
	pkg: "../package/main.roc",
}

import fuzz.Fuzz
import pkg.Tar
import "../tests/fixtures/gnu.tar" as gnu : List(U8)
import "../tests/fixtures/pax.tar" as pax : List(U8)
import "../tests/fixtures/ustar.tar" as ustar : List(U8)
import "../tests/fixtures/roc-HDQnwrX2Bcm8Jsf8RMC9ZdbVGwPiqD2nCLP7Zf1osfgU.tar" as roc_bundle : List(U8)

# L1 (REG1, REG9): push and finish never crash, on any bytes, and the result
# does not depend on the chunk sizes. The input is a seed archive (GNU tar
# gnu, pax, ustar, a roc bundle) with a cut and an insert, or any bytes. It
# is read in one chunk and in chunks of random sizes; both results must be
# equal.

seeds : List(List(U8))
seeds = [gnu, pax, ustar, roc_bundle]

Input := { seed : U64, cut : U64, drop : U64, insert : List(U8), raw : Bool, sizes : List(U8) }.{
	generator_for : Fuzz.FuzzEncoding -> Fuzz.Generator(Input)
	generator_for = |_| {
		seed: Fuzz.u64,
		cut: Fuzz.u64,
		drop: Fuzz.u64_in(0, 600),
		insert: Fuzz.bytes,
		raw: Fuzz.map(Fuzz.u8_in(0, 7), |b| b == 0),
		sizes: Fuzz.bytes,
	}.Fuzz
}

## The seed with `drop` bytes at `cut` replaced by `insert`.
bytes_of : Input -> List(U8)
bytes_of = |input| {
	if input.raw {
		return input.insert
	}
	bytes = seeds.get(input.seed % seeds.len()) ?? []
	at = input.cut % (bytes.len() + 1)
	bytes.take_first(at).concat(input.insert).concat(bytes.drop_first(at + input.drop))
}

## The bytes in chunks. Each size byte `s` gives a chunk of `s * 7 % 1100`
## bytes. A size of 0 gives an empty chunk and then a chunk of 1 byte. The
## sizes repeat.
chunks_of : List(U8), List(U8) -> List(List(U8))
chunks_of = |bytes, sizes| {
	steps = if (sizes.is_empty()) [1] else sizes
	var $out = []
	var $at = 0
	var $k = 0
	while $at < bytes.len() {
		s0 = (steps.get($k % steps.len()) ?? 1).to_u64() * 7 % 1100
		s = if s0 == 0 {
			$out = $out.append([])
			1
		} else {
			s0
		}
		$out = $out.append(bytes.sublist({ start: $at, len: s }))
		$at = $at + s
		$k = $k + 1
	}
	$out
}

read : List(List(U8)) -> Try((List(Tar.Event), Tar.Summary), Tar.Error)
read = |chunks| {
	var $t = Tar.new(Tar.Limits.{})
	var $events = []
	for c in chunks {
		(t2, evs) = $t.push(c, |e| if (e.path.ends_with(".roc")) Collect(4096) else Skip)?
		$t = t2
		$events = $events.concat(evs)
	}
	summary = $t.finish()?
	Ok(($events, summary))
}

test : Input -> Fuzz.Outcome
test = |input| {
	bytes = bytes_of(input)
	if (read([bytes]) == read(chunks_of(bytes, input.sizes))) Fuzz.keep else crash "the chunk sizes change the result"
}

target = Fuzz.target_with({
	name: "split",
	generator: Input.generator_for(Default),
	test,
	show: |input| Str.inspect(input),
})
