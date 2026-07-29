'use strict';
// CommonJS variant. The baseline shape: NODE_OPTIONS=--require <register.js> must instrument this.
//
// Each process drives its own outbound HTTP on a timer. That is not decoration: PM2 cluster on
// Windows does not round-robin inbound connections (they all land on one worker), so without a
// per-process self-call only one worker of a cluster app would ever emit a span, and the
// per-worker assertion would pass or fail for the wrong reason.
const http = require('http');
const pino = require('pino');

const NAME = process.env.OTEL_SERVICE_NAME || process.env.name || 'cx-app-cjs';
const PORT = Number(process.env.PORT || 9101);
const log  = pino({ name: NAME });

http.createServer((req, res) => {
  log.info({ path: req.url, pid: process.pid }, 'request');
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ service: NAME, module: 'cjs', pid: process.pid, path: req.url }));
}).listen(PORT, '127.0.0.1', () => log.info({ port: PORT, pid: process.pid, service: NAME }, 'listening'));

if (process.env.CX_SELF_LOAD !== '0') {
  setInterval(() => {
    const req = http.get({ host: '127.0.0.1', port: PORT, path: '/work', timeout: 2500 }, (r) => r.resume());
    req.on('error', () => {});
    req.on('timeout', () => req.destroy());
  }, 3000);
}

process.on('uncaughtException', (e) => { log.error({ err: String(e) }, 'uncaughtException'); process.exit(1); });
