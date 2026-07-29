'use strict';
// The script a service-hosted PM2 runs - the `pm2-installer` shape, reproduced.
//
// WHY connect(true): no-daemon mode runs the PM2 God IN THIS PROCESS instead of spawning a
// separate one. That is what produces the process tree observed on the real host:
//
//   node.exe node-windows\lib\wrapper.js --file <PM2_HOME>\service\index.js   <- winsw shim
//    └─ node.exe <PM2_HOME>\service\index.js                                  <- God daemon (this)
//        ├─ node.exe pm2\lib\ProcessContainerFork.js                          <- app
//        └─ ... one per app
//
// If this connected normally, the God would be a fourth, separately-parented process and the
// topology probe would be tested against a tree no real host produces.
//
// Everything here runs as the SERVICE ACCOUNT (LOCAL SERVICE / LocalSystem / a local user,
// depending on the shape). The daemon's IPC pipe therefore belongs to that account, which is the
// whole condition under test: `pm2 jlist` run by anyone else answers for an empty daemon of its
// own and exits 0.
process.env.PM2_HOME = process.env.PM2_HOME || 'C:\\ProgramData\\pm2';

const pm2 = require('C:/npm-global/node_modules/pm2');

function log(msg) {
  // stdout is captured by the service wrapper's log file; also stamp PM2_HOME so a harness
  // reading the log can prove which home this daemon owns.
  console.log(`[pm2-service] ${new Date().toISOString()} PM2_HOME=${process.env.PM2_HOME} ${msg}`);
}

log('starting (no-daemon mode: God runs in this process)');

const fs   = require('fs');
const path = require('path');

// The app list this daemon should own, as `<PM2_HOME>\service\apps.json`.
//
// Started explicitly rather than via pm2.resurrect(): resurrect replays dump.pm2, and a dump written
// by hand (which is what a fixture must do - there is no daemon yet to `pm2 save` from) does not
// reliably satisfy the full pm2_env schema pm2 v7 expects, so it came back with zero apps and the
// shape silently had nothing to instrument. dump.pm2 is still written alongside, because the
// stopped-daemon shape needs a dump on disk to read.
const appsFile = path.join(process.env.PM2_HOME, 'service', 'apps.json');

pm2.connect(true, (err) => {
  if (err) {
    log('connect failed: ' + err.message);
    process.exit(1);
  }
  log('God started');

  let apps = null;
  try { apps = JSON.parse(fs.readFileSync(appsFile, 'utf8')); }
  catch (e) { log('no readable apps.json (' + e.message + ')'); }

  if (Array.isArray(apps) && apps.length > 0) {
    let i = 0;
    const startNext = () => {
      if (i >= apps.length) { log('started ' + apps.length + ' app(s)'); return; }
      const a = apps[i++];
      pm2.start(a, (sErr) => {
        log(sErr ? ('start FAILED ' + a.name + ': ' + sErr.message) : ('started ' + a.name));
        startNext();
      });
    };
    startNext();
  } else {
    pm2.resurrect((rErr) => {
      if (rErr) log('resurrect: ' + rErr.message);
      else      log('resurrected saved apps');
    });
  }
});

// Hold the process open. Without this the God dies with us and the shape evaporates.
setInterval(() => {}, 1 << 30);

process.on('uncaughtException', (e) => log('uncaughtException: ' + String(e)));
