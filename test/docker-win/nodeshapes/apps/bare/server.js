'use strict';
// The app for the NON-PM2 shapes: started by a scheduled task, or wrapped as a Windows service by
// node-windows. No supervisor metadata anywhere - which is the point. Nothing in this repo
// instruments these today, so the assertion is that the tooling SAYS so (workload.nodejs without
// workload.pm2, doctor skip/unknown) rather than claiming coverage it does not have or crashing on
// a host shape it did not expect.
const http = require('http');

const NAME = process.env.OTEL_SERVICE_NAME || 'cx-app-bare';
const PORT = Number(process.env.PORT || 9104);

http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ service: NAME, module: 'bare', pid: process.pid, path: req.url }));
}).listen(PORT, '127.0.0.1', () => console.log(`[bare] listening ${PORT} pid=${process.pid}`));

setInterval(() => {
  const req = http.get({ host: '127.0.0.1', port: PORT, path: '/work', timeout: 2500 }, (r) => r.resume());
  req.on('error', () => {});
  req.on('timeout', () => req.destroy());
}, 3000);
