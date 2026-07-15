# POC guest bootstrap - fetched + run inside the VM via keyboard injection.
# Enables IIS (agent IIS zero-code branch + exfil channel), pulls the package,
# runs deploy.bat (the BatchPatch remote command), exfils logs via IIS wwwroot.
$ErrorActionPreference = 'Continue'
$base = 'http://192.168.56.1:48080'
$wt   = 'C:\inetpub\wwwroot'

# 1. Enable IIS + ASP.NET first (creates wwwroot, opens :80)
Install-WindowsFeature -Name Web-Server, Web-Asp-Net45, Web-Mgmt-Tools -IncludeManagementTools | Out-Null
New-Item -ItemType Directory -Path $wt -Force | Out-Null

# clear stale markers from a previous run
foreach ($m in 'done.txt','dump.txt','dumpdone.txt','deploy-out.log','install-agent.log','install-agent-status.json','detect-workloads.json','state.txt','statedone.txt') { Remove-Item (Join-Path $wt $m) -Force -ErrorAction SilentlyContinue }
$prog = Join-Path $wt 'g-progress.txt'
"STAGE=iis-done $(Get-Date -Format o)" | Out-File $prog -Encoding ascii

# 2. Pull + expand the package
Invoke-WebRequest "$base/coralogix-agent-deploy.zip" -OutFile C:\cx.zip -UseBasicParsing
if (Test-Path C:\cx) { Remove-Item C:\cx -Recurse -Force }
Expand-Archive C:\cx.zip C:\cx -Force
"STAGE=pkg-expanded" | Out-File $prog -Append -Encoding ascii

# 3. Run deploy.bat (collector supervisor install + detect + IIS instr)
& C:\cx\deploy.bat *> (Join-Path $wt 'deploy-out.log') 2>&1
"STAGE=deploy-exit=$LASTEXITCODE" | Out-File $prog -Append -Encoding ascii

# 4. Exfil the agent's own logs + status via IIS
foreach ($f in 'install-agent.log','install-agent-status.json','detect-workloads.json') {
    Copy-Item (Join-Path C:\cx $f) $wt\ -Force -ErrorAction SilentlyContinue
}
'DONE' | Out-File (Join-Path $wt 'done.txt') -Encoding ascii
