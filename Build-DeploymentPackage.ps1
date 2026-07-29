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

.PARAMETER Region
  Coralogix region code (eu1, eu2, us1, us2, us3, ap1, ap2, ap3) to bake into the
  package as region.txt. Install-Agent.ps1 falls back to that file when no -Region /
  -Domain / CX_REGION is supplied at deploy time, so BatchPatch's remote command can
  stay a bare 'deploy.bat' on a non-eu1 fleet. The region MUST match the account the
  key belongs to: a key from another region authenticates nowhere while every host
  still reports healthy. Omit to build a region-neutral package.

.PARAMETER OutFile
  Output zip path. Default: .\coralogix-agent-deploy.zip

.EXAMPLE
  .\Build-DeploymentPackage.ps1 -KeyFile C:\secrets\cx.key

.EXAMPLE
  .\Build-DeploymentPackage.ps1 -KeyFile C:\secrets\cx.key -Region eu2
#>
[CmdletBinding()]
param(
    [string] $KeyFile = $null,
    [string] $Region  = $null,
    [string] $OutFile = (Join-Path $PSScriptRoot 'coralogix-agent-deploy.zip')
)

$ErrorActionPreference = 'Stop'
$deployDir = Join-Path $PSScriptRoot 'deploy'
if (-not (Test-Path $deployDir)) { throw "deploy/ folder not found at $deployDir" }

# Required members of the package. Includes the install + uninstall + diagnostic
# entry points, the shared helpers they dot-source (Resolve-IISServiceNames,
# Backup-Config, Write-DeployLog), and the base config.
#
# NOTE: every dot-source in the scripts is Test-Path guarded, so a file omitted
# here does NOT crash on the target host - the feature just silently degrades
# (a diagnostic check reports UNKNOWN, or output loses its formatting). The
# foreach below is the safety net: it fails the BUILD instead, loudly.
$required = @('deploy.bat','uninstall.bat','doctor.bat','Resolve-IISLogPaths.ps1',
              'Install-Agent.ps1','Uninstall-Agent.ps1',
              'Install-CoralogixSupervisor.ps1','Detect-Workloads.ps1',
              'Instrument-IIS.ps1','Resolve-IISServiceNames.ps1','Resolve-IISAppRuntime.ps1',
              'Instrument-NodePM2.ps1','Resolve-NodeServiceNames.ps1',
              'Backup-Config.ps1','Write-DeployLog.ps1','Resolve-CxRegion.ps1',
              'Test-Agent.ps1','Test-IISInstrumentation.ps1','Test-NodeInstrumentation.ps1',
              'config.supervisor.yaml')
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

    # Region: validated HERE, at build time, against the same table the installer uses.
    # A typo caught now costs a rebuild; the same typo shipped in region.txt fails on
    # every target host instead.
    if ($Region) {
        . (Join-Path $deployDir 'Resolve-CxRegion.ps1')
        $regionDomain = Resolve-CxDomain -Region $Region   # throws on an unknown code
        Set-Content -Path (Join-Path $stage 'region.txt') -Value $Region.Trim().ToLowerInvariant() -Encoding utf8 -NoNewline
        Write-Host "[build] included region.txt -> $Region (domain $regionDomain)"
    } else {
        Write-Host "[build] no -Region: package is region-neutral. Hosts use CX_REGION / CORALOGIX_DOMAIN at deploy time, or the eu1 default."
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
Write-Host "To uninstall later, run remote command 'uninstall.bat' (set CX_PURGE=1 to also delete staged config + binaries)."
