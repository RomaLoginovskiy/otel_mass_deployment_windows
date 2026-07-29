// ESM variant by "type": "module" (note the .js extension - the extension alone says nothing).
import http from 'http';
import pino from 'pino';

const NAME = process.env.OTEL_SERVICE_NAME || 'cx-app-esm';
const PORT = Number(process.env.PORT || 9102);
const log  = pino({ name: NAME });

http.createServer((req, res) => {
  log.info({ path: req.url, pid: process.pid }, 'request');
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ service: NAME, module: 'esm', pid: process.pid, path: req.url }));
}).listen(PORT, '127.0.0.1', () => log.info({ port: PORT, pid: process.pid, service: NAME }, 'listening'));

if (process.env.CX_SELF_LOAD !== '0') {
  setInterval(() => {
    const req = http.get({ host: '127.0.0.1', port: PORT, path: '/work', timeout: 2500 }, (r) => r.resume());
    req.on('error', () => {});
    req.on('timeout', () => req.destroy());
  }, 3000);
}

process.on('uncaughtException', (e) => { log.error({ err: String(e) }, 'uncaughtException'); process.exit(1); });
