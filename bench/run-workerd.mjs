// The measure of roc-tar in workerd: bench/app.roc (built to .work/bench/app.wasm) behind bench/worker.js.
// WORKERD=<workerd> node bench/run-workerd.mjs <reps> <file.tar.zst>...
// Env: CFW (the platform repository, default ../talon/cloudflare-workers), PORT (default 8191), CHUNK (default 65536).
// For each file and mode, a new workerd process (so wasm memory is the peak of that mode), one warm-up request, then
// `reps` requests. The time is the wall time of the client for one request (workerd stops its clocks while a Worker
// runs, so the server cannot time itself); the body goes over localhost in CHUNK-byte chunks. A file that ends in
// `.tar` is sent as a plain tar with `&raw=1` (no zstd decode in the app).
import { spawn } from 'node:child_process';
import http from 'node:http';
import { mkdirSync, readFileSync, writeFileSync, symlinkSync, rmSync, copyFileSync, readdirSync } from 'node:fs';
import { basename, resolve, join } from 'node:path';

const here = new URL('.', import.meta.url).pathname;
const CFW = resolve(process.env.CFW ?? `${here}/../../talon/cloudflare-workers`);
const PORT = Number(process.env.PORT ?? 8191);
const CHUNK = Number(process.env.CHUNK ?? 65536);
const MODES = (process.env.MODES ?? 'read,b3,zstd,b3zstd,tarzstd,tar10,full').split(',');
const [repsArg, ...files] = process.argv.slice(2);
const reps = Number(repsArg ?? 5);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The config directory: the worker, the app, and a copy of the shim (capnp `embed` takes relative paths).
const W = resolve(`${here}/../.work/bench/workerd`);
rmSync(W, { recursive: true, force: true });
mkdirSync(join(W, 'js'), { recursive: true });
copyFileSync(join(here, 'worker.js'), join(W, 'worker.js'));
copyFileSync(resolve(`${here}/../.work/bench/app.wasm`), join(W, 'app.wasm'));
const jsFiles = readdirSync(join(CFW, 'js')).filter((f) => f.endsWith('.js'));
for (const f of jsFiles) copyFileSync(join(CFW, 'js', f), join(W, 'js', f));
writeFileSync(
  join(W, 'config.capnp'),
  `using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "main", worker = (modules = [
        (name = "worker.js", esModule = embed "worker.js"),
${jsFiles.map((f) => `        (name = "js/${f}", esModule = embed "js/${f}"),`).join('\n')}
        (name = "app.wasm", wasm = embed "app.wasm")],
      compatibilityDate = "2026-10-01")),
  ],
  sockets = [ (name = "http", address = "127.0.0.1:${PORT}", http = (), service = "main") ],
);
`,
);

const BASE = `http://127.0.0.1:${PORT}`;
async function start() {
  const p = spawn(process.env.WORKERD, ['serve', join(W, 'config.capnp')], { stdio: ['ignore', 'ignore', 'inherit'] });
  for (let i = 0; i < 100; i++) {
    try {
      await fetch(`${BASE}/__stats`);
      return p;
    } catch {
      await sleep(100);
    }
  }
  throw new Error('workerd did not start');
}
// One request on a new connection (node:http, no keep-alive agent): Node fetch reuses a connection that workerd
// closed and then fails (EPIPE, "other side closed"). The body goes in CHUNK-byte writes.
const run = (bytes, mode, raw = false) =>
  new Promise((resolveRun, reject) => {
    const t0 = performance.now();
    const req = http.request(`${BASE}/run?mode=${mode}${raw ? '&raw=1' : ''}`, { method: 'POST', agent: false, headers: { 'content-length': bytes.length } }, (res) => {
      const parts = [];
      res.on('data', (d) => parts.push(d));
      res.on('end', () => resolveRun({ status: res.statusCode, text: Buffer.concat(parts).toString(), wallMs: performance.now() - t0 }));
      res.on('error', reject);
    });
    req.on('error', reject);
    let at = 0;
    const write = () => {
      while (at < bytes.length) {
        const n = Math.min(CHUNK, bytes.length - at);
        const more = req.write(bytes.subarray(at, at + n));
        at += n;
        if (!more) return req.once('drain', write);
      }
      req.end();
    };
    write();
  });
const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];

const rows = [];
for (const f of files) {
  const bytes = new Uint8Array(readFileSync(f));
  for (const mode of MODES) {
    const p = await start();
    try {
      await run(new Uint8Array(0), 'read');
      await fetch(`${BASE}/__reset`);
      const walls = [];
      let text = '';
      for (let r = 0; r < reps; r++) {
        const got = await run(bytes, mode, f.endsWith('.tar'));
        if (got.status !== 200) throw new Error(`${f} ${mode}: ${got.status} ${got.text}`);
        walls.push(got.wallMs);
        text = got.text;
        console.log(JSON.stringify({ file: basename(f), mode, rep: r, wallMs: got.wallMs, text }));
      }
      const s = await (await fetch(`${BASE}/__stats`)).json();
      rows.push({ file: basename(f).slice(0, 12), packedMB: (bytes.length / 2 ** 20).toFixed(1), mode, wallMs: median(walls), memMB: s.mem / 2 ** 20, livePeakMB: s.livePeak / 2 ** 20, text });
    } finally {
      p.kill();
      await sleep(200);
    }
  }
}
console.log('\n| File | Packed MB | Mode | Wall ms (median, client) | wasm memory MB | Live peak MB |');
console.log('| --- | --- | --- | --- | --- | --- |');
for (const r of rows) console.log(`| ${r.file} | ${r.packedMB} | ${r.mode} | ${r.wallMs.toFixed(1)} | ${r.memMB.toFixed(1)} | ${r.livePeakMB.toFixed(1)} |`);
console.log('');
for (const r of rows.filter((r) => r.mode === 'full')) console.log(`${r.file}: ${r.text}`);
