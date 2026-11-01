// The worker of bench/run-workerd.mjs: the measure app (bench/app.roc) behind `makeHandler` of the platform shim.
// More paths: `GET /__stats` (wasm memory bytes and the live peak of the host allocator), `GET /__reset` (reset the
// peak).
import app from 'app.wasm';
import { makeHandler } from './js/index.js';

const Handler = makeHandler(app, { heapCheckWhenIdle: false });

export default class extends Handler {
  async fetch(request) {
    const path = new URL(request.url).pathname;
    const x = Handler.runner?.x;
    if (path === '/__stats') return Response.json({ mem: x?.memory.buffer.byteLength ?? 0, livePeak: x?.live_peak() ?? 0 });
    if (path === '/__reset') {
      x?.stats_reset();
      return Response.json({ ok: true });
    }
    return super.fetch(request);
  }
}
