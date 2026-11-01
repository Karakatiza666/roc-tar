#!/usr/bin/env bash
# Builds bench/app.roc on the bench platform of the Cloudflare Workers
# platform (talon/cloudflare-workers) to .work/bench/app.wasm.
# Env: CFW (default: ../talon/cloudflare-workers next to this repository, with
# its bench host built by its bench/build.sh), ROC (default: the nightly of
# $CFW/compat/last-stack-first-nightly, from $CFW/bench/get-roc.sh).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
CFW=$(cd "${CFW:-$HERE/../talon/cloudflare-workers}" && pwd)
ROC=${ROC:-$("$CFW/bench/get-roc.sh")}
[ -f "$CFW/bench/platform/targets/wasm32/host.wasm" ] || { echo "no bench host: run ZIG=<zig 0.17> $CFW/bench/build.sh" >&2; exit 1; }
# The app header names platform/main.roc: a link (ignored by git) to the bench platform.
ln -sfn "$CFW/bench/platform" "$HERE/bench/platform"
mkdir -p "$HERE/.work/bench"
export ROC_CACHE_DIR=$HERE/.work/xdg/roc XDG_CACHE_HOME=$HERE/.work/xdg
"$ROC" version
"$ROC" build --opt=speed --target=wasm32 --no-cache --output="$HERE/.work/bench/app.wasm" "$HERE/bench/app.roc" || [ $? -eq 2 ]
node "$CFW/bench/check-layout.mjs" --header "$CFW/bench/platform/main.roc" "$HERE/.work/bench/app.wasm"
ls -l "$HERE/.work/bench/app.wasm"
