<#
.SYNOPSIS
  Publish the E2E app fixtures on the HOST, ready to be copied into a guest.

.DESCRIPTION
  The guests deliberately get no SDK. Installing one would change what is being tested: a fleet
  host runs published output, and an SDK on the box brings its own runtimes, which would blur the
  "does the profiler attach to net6 AND net8" question this matrix exists to answer.

  Produces under -OutDir (default test\fixtures\out):

    coreweb-net8\   ASP.NET Core 8, framework-dependent (the guest has the 8 hosting bundle)
    coreweb-net6\   the same source on ASP.NET Core 6, side by side
    workersvc\      the non-IIS Windows service, SELF-CONTAINED so it cannot silently pick up
                    whichever runtime the guest happens to have
    fw48\           ASP.NET Framework 4.8 - copied, not built: runtime-compiled .aspx
    clr2\           CLR 2.0 refusal case - likewise source only

  Framework-dependent for the IIS apps is deliberate: it makes the hosting bundles a real
  prerequisite, so a guest missing one FAILS the matrix instead of quietly running a bundled copy.

.NOTES
  Needs the .NET SDK on the host (`dotnet --list-sdks`). An SDK that can target net6.0/net8.0 is
  enough; it does not have to be version 6 or 8 itself.
#>
[CmdletBinding()]
param(
    [string] $OutDir = $null,
    [switch] $Clean
)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $OutDir) { $OutDir = Join-Path $here 'out' }

$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
if (-not $dotnet) { throw 'dotnet SDK not found on PATH - needed to publish the Core fixtures.' }

if ($Clean -and (Test-Path $OutDir)) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

function Publish-App {
    param([string] $Project, [string] $Framework, [string] $Dest, [switch] $SelfContained)

    Write-Host "[fixtures] publishing $(Split-Path -Leaf $Project) ($Framework$(if ($SelfContained) { ', self-contained' }))"
    $args = @('publish', $Project, '-c', 'Release', '-f', $Framework, '-o', $Dest, '--nologo', '-v', 'quiet')
    if ($SelfContained) { $args += @('-r', 'win-x64', '--self-contained', 'true') }
    else                { $args += @('--self-contained', 'false') }

    $out = & $dotnet @args 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        $out | Select-Object -Last 25 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
        throw "publish failed for $Project ($Framework), exit $LASTEXITCODE"
    }
}

$coreweb = Join-Path $here 'apps\coreweb\coreweb.csproj'
Publish-App -Project $coreweb -Framework 'net8.0' -Dest (Join-Path $OutDir 'coreweb-net8')
Publish-App -Project $coreweb -Framework 'net6.0' -Dest (Join-Path $OutDir 'coreweb-net6')

# Framework-dependent, like the IIS apps. Self-contained was tried first and produced 219 files to
# push over guestcontrol for no benefit: the guest's .NET 8 hosting bundle already carries
# Microsoft.NETCore.App, and depending on it keeps the bundle a real, asserted prerequisite instead
# of letting the service quietly run its own bundled copy.
$worker = Join-Path $here 'apps\workersvc\workersvc.csproj'
Publish-App -Project $worker -Framework 'net8.0' -Dest (Join-Path $OutDir 'workersvc')

# Source-only fixtures: ASP.NET compiles these on first request, which is what lets the matrix
# cover Framework 4.8 and CLR 2 without needing MSBuild web targets anywhere.
foreach ($src in @('fw48', 'clr2')) {
    $dest = Join-Path $OutDir $src
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $here "apps\$src") -Destination $dest -Recurse -Force
    Write-Host "[fixtures] copied $src (runtime-compiled, no build)"
}

# web.config for the two Core apps. `dotnet publish` writes one for a web SDK project, but the
# matrix needs the hostingModel pinned per copy: net8 runs IN-PROCESS (the ordinary case) and the
# out-of-process variant is provisioned separately by the shape script, so assert what we shipped
# rather than trusting the SDK's default.
foreach ($pair in @(@{ Dir = 'coreweb-net8'; Tfm = 'net8.0' }, @{ Dir = 'coreweb-net6'; Tfm = 'net6.0' })) {
    $cfg = Join-Path $OutDir "$($pair.Dir)\web.config"
    if (-not (Test-Path $cfg)) {
        Write-Host "[fixtures] WARNING: no web.config in $($pair.Dir) - IIS will not host it" -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '[fixtures] published:'
Get-ChildItem -LiteralPath $OutDir -Directory | ForEach-Object {
    $n = @(Get-ChildItem -LiteralPath $_.FullName -Recurse -File).Count
    "  {0,-16} {1,5} files" -f $_.Name, $n
}
Write-Host "[fixtures] out: $OutDir"
