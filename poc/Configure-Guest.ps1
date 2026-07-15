<#
.SYNOPSIS
  POC-ONLY: prepare a freshly-installed Windows Server guest to be a realistic
  fleet target AND reachable by BatchPatch from the host.

.DESCRIPTION
  Runs INSIDE the guest (copied in + executed via VBoxManage guestcontrol, or by
  hand). It:
    1. Enables IIS + ASP.NET (so Detect-Workloads reports 'iis' and the orchestrator
       runs zero-code .NET instrumentation).
    2. Enables WinRM / PSRemoting and opens the firewall so BatchPatch can push
       files (SMB admin shares) and run remote commands (WinRM + service control).
    3. Sets LocalAccountTokenFilterPolicy=1 so a LOCAL admin works over the network
       (required on non-domain-joined hosts, which is our POC).

  Idempotent; safe to re-run.

.NOTES
  This is throwaway POC scaffolding, NOT part of the fleet deployment package.
  Production servers are assumed already domain-joined / remotely manageable.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Write-Host "=== Configure-Guest on $($env:COMPUTERNAME) ==="

# --- 1. IIS + ASP.NET ---------------------------------------------------------
try {
    if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
        Write-Host "[guest] Install-WindowsFeature Web-Server + ASP.NET ..."
        Install-WindowsFeature -Name Web-Server, Web-Asp-Net45, Web-Mgmt-Console, Web-Mgmt-Tools -IncludeManagementTools | Out-Null
    } else {
        Write-Host "[guest] enabling IIS via DISM optional features ..."
        Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-ASPNET45, IIS-NetFxExtensibility45 -All -NoRestart | Out-Null
    }
    Write-Host "[guest] IIS enabled."
} catch { Write-Warning "[guest] IIS enable failed: $_" }

# --- 2. WinRM / PSRemoting for BatchPatch -------------------------------------
try {
    Write-Host "[guest] Enable-PSRemoting ..."
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    winrm quickconfig -quiet 2>$null | Out-Null
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service -Name WinRM
} catch { Write-Warning "[guest] PSRemoting failed: $_" }

# --- 3. Firewall: SMB (admin shares), WinRM, ICMP -----------------------------
try {
    Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -DisplayGroup 'Windows Remote Management' -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -DisplayGroup 'Windows Management Instrumentation (WMI)' -ErrorAction SilentlyContinue
    # ICMP echo so the host can ping the VM
    New-NetFirewallRule -DisplayName 'POC ICMPv4 In' -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow -ErrorAction SilentlyContinue | Out-Null
    Write-Host "[guest] firewall rules enabled (SMB, WinRM, WMI, ICMP)."
} catch { Write-Warning "[guest] firewall config failed: $_" }

# --- 4. Local admin over network (non-domain host) ----------------------------
try {
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name 'LocalAccountTokenFilterPolicy' -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host "[guest] LocalAccountTokenFilterPolicy=1 (local admin usable over network)."
} catch { Write-Warning "[guest] LATFP set failed: $_" }

# --- Report reachability info -------------------------------------------------
Write-Host ""
Write-Host "[guest] IPv4 addresses:"
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
    ForEach-Object { Write-Host ("  {0}  ({1})" -f $_.IPAddress, $_.InterfaceAlias) }
Write-Host "[guest] WinRM listeners:"
try { winrm enumerate winrm/config/listener 2>$null | Select-String 'Address|Port|Transport' | ForEach-Object { Write-Host "  $_" } } catch {}
Write-Host "=== Configure-Guest done ==="
