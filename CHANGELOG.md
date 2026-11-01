# Changelog

## Next (0.1.0, not released)

| Change | Kind | What to do |
| --- | --- | --- |
| `Tar.Entry` has the new field `type_byte : U8`: the type byte of the ustar header of the member, as it is (after a pax `x` or GNU `L`/`K` header, the byte of the member header). `kind` does not change: `0`, NUL and `7` are still `File`. | Breaking | Code that makes an `Entry` record (for example a fake `Entry` in a test) must add `type_byte`. Code that only reads fields does not change. |
| New `Tar.roc_accepts : Tar.Entry -> Try({}, [UnsupportedType(U8), Path(...), Link(...)])`: `Ok({})` when `roc unbundle` (roc-lang/roc `76258c1`, Zig 0.17.0 `std.tar.Iterator`) accepts the member on each OS. Only types `0`, NUL, `5` and `2` are accepted; `7` is `UnsupportedType('7')`. | New | Use it in place of a read of the byte at `entry.offset + 156`. |

Why 0.1.0 and not 0.0.2: below 1.0, the series is `0.minor` (Roc package groups, Talon R-ID1). 0.0.2 is in the series of 0.0.1, so a build can take 0.0.2 in place of 0.0.1 for a dependent that was written for 0.0.1. A dependent that makes an `Entry` record then fails to compile. A new series (0.1) is necessary for a breaking change.

## 0.0.1

The first release: a streaming reader for ustar, pax and GNU long names, `check_path`, `check_portable_path`, `held_bytes`.
