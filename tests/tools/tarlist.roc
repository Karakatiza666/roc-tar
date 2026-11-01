app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	pkg: "../../package/main.roc",
}

import pf.Stdin
import pf.Stdout
import pkg.Tar

## Reads a tar archive from standard input in the chunks that `Stdin.bytes!`
## gives, and prints one line for each member in the form of `tar -tv`:
## "<type><mode> <size> <path>", then " -> <target>" for a symbolic link and
## " link to <target>" for a hard link. The last line is "end <end> <members>".
## scripts/bundles.sh compares the lines with GNU tar.
main! = |_args| {
	var $t = Tar.new(Tar.Limits.{ max_total_size: 1073741824 })
	var $lines = []
	var $more = True
	while $more {
		match Stdin.bytes!() {
			Ok(chunk) => {
				(t2, events) = $t.push(chunk, |_| Skip) ? |e| Tar(Tar.err_to_str(e))
				$t = t2
				for e in events {
					match e {
						Entry(entry) => {
							$lines = $lines.append(line(entry))
						}

						Content(_, _) => {}
					}
				}
			}

			Err(EndOfInput) => {
				$more = False
			}

			Err(_) => return Err(ReadFailed)
		}
	}
	summary = $t.finish() ? |e| Tar(Tar.err_to_str(e))
	end = match summary.end {
		TwoZeroBlocks => "two-zero-blocks"
		OneZeroBlock => "one-zero-block"
		NoZeroBlock => "no-zero-block"
	}
	Stdout.line!(Str.join_with($lines.append("end ${end} ${summary.members.to_str()}"), "\n"))?
	Ok({})
}

line : Tar.Entry -> Str
line = |e| {
	type = match e.kind {
		File => "-"
		Dir => "d"
		Symlink => "l"
		HardLink => "h"
		Other(b) => if (b == '3') "c" else if (b == '4') "b" else if (b == '6') "p" else "?"
	}
	link = match e.kind {
		Symlink => " -> ${e.link}"
		HardLink => " link to ${e.link}"
		_ => ""
	}
	"${type}${rwx(e.mode)} ${e.size.to_str()} ${e.path}${link}"
}

# The 9 permission bits as "rwxr-xr-x".
rwx : U32 -> Str
rwx = |mode| {
	var $s = ""
	for k in [8, 7, 6, 5, 4, 3, 2, 1, 0] {
		on = mode.shr_wrap(k).bitwise_and(1) == 1
		c = if (!on) "-" else if (k % 3 == 2) "r" else if (k % 3 == 1) "w" else "x"
		$s = $s.concat(c)
	}
	$s
}
