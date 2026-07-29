'use strict';
// Node hosted INSIDE IIS by iisnode.
//
// iisnode does not give the app a TCP port: it sets process.env.PORT to a NAMED PIPE and proxies
// requests over it, which is why this listens on process.env.PORT verbatim with no numeric default
// and no host argument. It also spawns/recycles the process itself, so there is no self-load timer.
//
// This shape exists to pin behaviour, not to be instrumented: the IIS side has no managed code
// (Resolve-IISAppRuntime -> Unsupported / NON_DOTNET_APP_NOT_INSTRUMENTED, kept out of
// CX_IIS_SERVICES) and the Node side has no PM2, so Instrument-NodePM2.ps1 does not reach it
// either. A host relying on iisnode gets no zero-code Node telemetry from this tooling, and the
// matrix asserts that this is reported rather than silently assumed.
const http = require('http');

http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ service: 'cx-app-iisnode', module: 'iisnode', pid: process.pid, path: req.url }));
}).listen(process.env.PORT, () => console.log('[iisnode] listening on ' + process.env.PORT));
