<#
.SYNOPSIS
  POC controller: push the Coralogix agent to the test VM from THIS host over WinRM
  - the same "copy files + run remote command" model BatchPatch uses, scripted so it
  can run headless (no Guest Additions / guestcontrol needed).

.DESCRIPTION
  1. Ensures the WinRM client is up and trusts the target (host-only IP).
  2. Opens a PSSession to the guest with local-Administrator creds.
  3. Enables IIS + ASP.NET in the guest (so the agent's IIS zero-code branch runs).
  4. Copies coralogix-agent-deploy.zip into the guest over the session (no SMB needed).
  5. Expands it and runs deploy.bat (collector supervisor install + workload detect
     + conditional IIS instrumentation) - identical payload/command to BatchPatch.
  6. Pulls back install-agent logs + status and prints a verification summary.

  Must run ELEVATED (setting WinRM TrustedHosts requires admin).

.NOTES
  POC only. Uses NTLM over HTTP to a workgroup host on an isolated host-only network.
#>
[CmdletBinding()]
param(
    [string] $Target      = '192.168.56.101',
    [string] $User        = 'Administrator',
    [string] $Password    = 'Otel!Passw0rd2026',
    [string] $Package     = (Join-Path $PSScriptRoot '..\coralogix-agent-deploy.zip'),
    [string] $GuestStage  = 'C:\cx-deploy',
    [string] $Environment = '',   # deployment env (staging/production/...); -> guest CX_ENVIRONMENT -> deploy.bat -Environment
    [string] $TranscriptLog = (Join-Path $PSScriptRoot '..\poc-deploy-fromhost.log')
)

$ErrorActionPreference = 'Stop'
try { Start-Transcript -Path $TranscriptLog -Force | Out-Null } catch {}
Write-Host "=== Deploy-FromHost -> $Target  $(Get-Date -Format o) ==="

# 0. Admin?
$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run elevated." }

# 1. WinRM client + trust
try { Set-Service WinRM -StartupType Automatic; Start-Service WinRM } catch {}
$th = try { (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value } catch { '' }
if ($th -notmatch [regex]::Escape($Target)) {
    $new = if ($th) { "$th,$Target" } else { $Target }
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $new -Force
}
Write-Host "[ctl] TrustedHosts = $((Get-Item WSMan:\localhost\Client\TrustedHosts).Value)"

if (-not (Test-Path $Package)) { throw "Package not found: $Package (run Build-DeploymentPackage.ps1)" }

$cred = New-Object System.Management.Automation.PSCredential($User, (ConvertTo-SecureString $Password -AsPlainText -Force))
$s = New-PSSession -ComputerName $Target -Credential $cred
try {
    Write-Host "[ctl] connected: $(Invoke-Command -Session $s { "$(whoami) @ $(hostname)" })"

    # 3. Configure: enable IIS + ASP.NET so the IIS zero-code branch exercises.
    Write-Host "[ctl] enabling IIS + ASP.NET in guest ..."
    Invoke-Command -Session $s {
        Install-WindowsFeature -Name Web-Server, Web-Asp-Net45, Web-Mgmt-Console, Web-Mgmt-Tools -IncludeManagementTools | Out-Null
        "IIS installed: " + ((Get-WindowsFeature Web-Server).Installed)
    }

    # 4. Copy the package in over the session (WinRM, no SMB).
    Write-Host "[ctl] staging package -> $GuestStage ..."
    Invoke-Command -Session $s -ArgumentList $GuestStage { param($d) New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $guestZip = Join-Path $GuestStage 'coralogix-agent-deploy.zip'
    Copy-Item -Path $Package -Destination $guestZip -ToSession $s -Force

    # 5. Expand + run deploy.bat (the BatchPatch remote command).
    Write-Host "[ctl] expanding + running deploy.bat in guest (collector supervisor install + detect + IIS instr) ..."
    $out = Invoke-Command -Session $s -ArgumentList $GuestStage, $Environment {
        param($d, $envName)
        $pkg = Join-Path $d 'pkg'
        if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
        Expand-Archive -Path (Join-Path $d 'coralogix-agent-deploy.zip') -DestinationPath $pkg -Force
        $bat = Join-Path $pkg 'deploy.bat'
        # deploy.bat forwards CX_ENVIRONMENT as -Environment; set it in this process
        # so the child cmd.exe inherits it.
        if ($envName) { $env:CX_ENVIRONMENT = $envName }
        & cmd.exe /c "`"$bat`""
        "deploy.bat exit=$LASTEXITCODE"
    }
    $out | ForEach-Object { Write-Host "  [guest] $_" }

    # 6. Verify + pull logs.
    Write-Host "[ctl] verifying agent ..."
    $verify = Invoke-Command -Session $s {
        $svc = Get-Service otelcol-contrib,opampsupervisor -ErrorAction SilentlyContinue |
               ForEach-Object { "$($_.Name)=$($_.Status)" }
        $health = try { (Invoke-WebRequest 'http://127.0.0.1:13133' -UseBasicParsing -TimeoutSec 8).StatusCode } catch { 'no' }
        $attrs = [Environment]::GetEnvironmentVariable('OTEL_RESOURCE_ATTRIBUTES','Machine')
        $cxEnv = [Environment]::GetEnvironmentVariable('CX_ENVIRONMENT','Machine')
        [pscustomobject]@{ services = ($svc -join '; '); health13133 = $health; otelResourceAttributes = $attrs; cxEnvironment = $cxEnv }
    }
    $verify | Format-List | Out-String | Write-Host

    foreach ($f in 'install-agent.log','install-agent-status.json','detect-workloads.json') {
        try { Copy-Item -Path (Join-Path "$GuestStage\pkg" $f) -Destination (Join-Path $PSScriptRoot "..\poc-guest-$f") -FromSession $s -Force -ErrorAction Stop; Write-Host "[ctl] pulled $f" } catch {}
    }
}
finally {
    Remove-PSSession $s -ErrorAction SilentlyContinue
    try { Stop-Transcript | Out-Null } catch {}
}
Write-Host "=== Deploy-FromHost done ==="
