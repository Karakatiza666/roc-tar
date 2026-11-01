// The measure of roc-tar in the Cloudflare Workers platform, in Node (the runner of the platform, `makeHandler`).
// node bench/run-node.mjs <app.wasm> <reps> <file.tar.zst>...
// Env: CFW (the platform repository, default ../talon/cloudflare-workers), CHUNK (bytes of a body chunk, default 65536).
// For each file and mode: `reps` requests in rotating order, each with a new instance (makeHandler), so the wasm memory
// of one request is its own peak. The body is the file as a stream of CHUNK-byte chunks (as from the network).
// A file that ends in `.tar` is sent as a plain tar with `&raw=1` (no zstd decode in the app).
// Prints one JSON line for each request, then a Markdown table of the medians.
import { readFileSync } from 'node:fs';
import { basename, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const here = new URL('.', import.meta.url).pathname;
const CFW = resolve(process.env.CFW ?? `${here}/../../talon/cloudflare-workers`);
const { makeHandler } = await import(pathToFileURL(`${CFW}/bench/cf-node.mjs`).href);
const CHUNK = Number(process.env.CHUNK ?? 65536);
const [wasmPath, repsArg, ...files] = process.argv.slice(2);
const reps = Number(repsArg ?? 5);
const module = new WebAssembly.Module(readFileSync(wasmPath));
const MODES = (process.env.MODES ?? 'read,b3,zstd,b3zstd,tarzstd,tar10,full').split(',');

const streamOf = (bytes) => {
  let at = 0;
  return new ReadableStream({
    pull(c) {
      if (at >= bytes.length) return c.close();
      const n = Math.min(CHUNK, bytes.length - at);
      c.enqueue(bytes.slice(at, at + n));
      at += n;
    },
  });
};
const ctx = { waitUntil() {}, passThroughOnException() {} };

async function once(bytes, mode, raw) {
  const H = makeHandler(module, { isolateBytes: 2 ** 40, heapCheckWhenIdle: false });
  // Warm the instance with an empty body, so instantiate is not in the time.
  await (await new H(ctx, {}).fetch(new Request('http://x/run?mode=read', { method: 'POST', body: '' }))).text();
  const x = H.runner.x;
  x.stats_reset?.();
  const mem0 = x.memory.buffer.byteLength;
  const live0 = x.live_peak();
  const req = new Request(`http://x/run?mode=${mode}${raw ? '&raw=1' : ''}`, { method: 'POST', body: streamOf(bytes), duplex: 'half' });
  const cpu0 = process.cpuUsage();
  const t0 = performance.now();
  const res = await new H(ctx, {}).fetch(req);
  const text = await res.text();
  const wall = performance.now() - t0;
  const cpu = process.cpuUsage(cpu0);
  return {
    mode,
    status: res.status,
    text,
    wallMs: wall,
    cpuMs: (cpu.user + cpu.system) / 1000,
    wasmMB: x.memory.buffer.byteLength / 2 ** 20,
    wasmGrowMB: (x.memory.buffer.byteLength - mem0) / 2 ** 20,
    livePeakMB: (x.live_peak() - live0) / 2 ** 20,
  };
}

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
};
const rows = [];
for (const f of files) {
  const bytes = new Uint8Array(readFileSync(f));
  const runs = Object.fromEntries(MODES.map((m) => [m, []]));
  for (let r = 0; r < reps; r++) {
    for (let k = 0; k < MODES.length; k++) {
      const mode = MODES[(k + r) % MODES.length];
      const got = await once(bytes, mode, f.endsWith('.tar'));
      if (got.status !== 200) throw new Error(`${f} ${mode}: status ${got.status} ${got.text}`);
      console.log(JSON.stringify({ file: basename(f), rep: r, ...got }));
      runs[mode].push(got);
    }
  }
  for (const m of MODES) {
    const rs = runs[m];
    rows.push({
      file: basename(f).slice(0, 12),
      packedMB: (bytes.length / 2 ** 20).toFixed(1),
      mode: m,
      cpuMs: median(rs.map((r) => r.cpuMs)),
      wallMs: median(rs.map((r) => r.wallMs)),
      wasmMB: Math.max(...rs.map((r) => r.wasmMB)),
      livePeakMB: Math.max(...rs.map((r) => r.livePeakMB)),
      text: rs[0].text,
    });
  }
}
console.log('\n| File | Packed MB | Mode | CPU ms (median) | Wall ms (median) | wasm memory MB (max) | Live peak MB (max) |');
console.log('| --- | --- | --- | --- | --- | --- | --- |');
for (const r of rows) {
  console.log(`| ${r.file} | ${r.packedMB} | ${r.mode} | ${r.cpuMs.toFixed(1)} | ${r.wallMs.toFixed(1)} | ${r.wasmMB.toFixed(1)} | ${r.livePeakMB.toFixed(1)} |`);
}
console.log('');
for (const r of rows.filter((r) => r.mode === 'full')) console.log(`${r.file}: ${r.text}`);
