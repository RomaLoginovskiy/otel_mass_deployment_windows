<#
.SYNOPSIS
  Build the BatchPatch deployment package (coralogix-agent-deploy.zip) from the
  deploy/ folder.

.DESCRIPTION
  Zips the deploy/ folder into a single artifact that BatchPatch's "Deploy
  software/patches/scripts" feature copies to each target server. The remote
  command BatchPatch runs after the copy is: deploy.bat.

  NOTE: batchpatch.zip in this repo is the BatchPatch.exe tool itself - that is
  NOT this package. This script produces the payload you push WITH BatchPatch.

.PARAMETER KeyFile
  Path to a real Send-Your-Data key file to include in the package as
  SendDataKey.txt. If omitted, the package is built WITHOUT a key and you must
  supply the key at deploy time (BatchPatch env var CORALOGIX_PRIVATE_KEY, or drop
  SendDataKey.txt on each host). The .example placeholder is never shipped.

.PARAMETER OutFile
  Output zip path. Default: .\coralogix-agent-deploy.zip

.EXAMPLE
  .\Build-DeploymentPackage.ps1 -KeyFile C:\secrets\cx.key
#>
[CmdletBinding()]
param(
    [string] $KeyFile = $null,
    [string] $OutFile = (Join-Path $PSScriptRoot 'coralogix-agent-deploy.zip')
)

$ErrorActionPreference = 'Stop'
$deployDir = Join-Path $PSScriptRoot 'deploy'
if (-not (Test-Path $deployDir)) { throw "deploy/ folder not found at $deployDir" }

# Required members of the package
$required = @('deploy.bat','Install-Agent.ps1','Install-CoralogixSupervisor.ps1',
              'Detect-Workloads.ps1','Instrument-IIS.ps1','config.supervisor.yaml')
foreach ($r in $required) {
    if (-not (Test-Path (Join-Path $deployDir $r))) { throw "Missing package file: deploy\$r" }
}

# Stage to a temp folder so we can control exactly what ships (and drop the key
# template / prior logs / status json).
$stage = Join-Path $env:TEMP ("cx-agent-pkg-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    Copy-Item -Path $required.ForEach({ Join-Path $deployDir $_ }) -Destination $stage -Force

    if ($KeyFile) {
        if (-not (Test-Path $KeyFile)) { throw "KeyFile not found: $KeyFile" }
        $key = (Get-Content $KeyFile -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) { throw "KeyFile is empty: $KeyFile" }
        Set-Content -Path (Join-Path $stage 'SendDataKey.txt') -Value $key -Encoding utf8 -NoNewline
        Write-Host "[build] included SendDataKey.txt from $KeyFile"
    } else {
        Write-Warning "[build] no -KeyFile: package built WITHOUT a key. Supply CORALOGIX_PRIVATE_KEY at deploy time or drop SendDataKey.txt on each host."
    }

    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $OutFile -Force
    Write-Host "[build] package created: $OutFile"
    Get-ChildItem $stage | Select-Object Name, Length | Format-Table -AutoSize | Out-String | Write-Host
}
finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Next: in BatchPatch, deploy '$OutFile' to the target servers, then run remote command 'deploy.bat'."
