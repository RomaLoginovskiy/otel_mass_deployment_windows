<#
.SYNOPSIS
  POC-ONLY one-time bootstrap, run INSIDE the guest (elevated) to make it remotely
  manageable from the host - so the host can push the agent exactly like BatchPatch
  (SMB admin share copy + WinRM/PSRemoting run). Needed only because Guest Additions
  didn't come up, so VBox guestcontrol isn't available.

.DESCRIPTION
  Enables PSRemoting/WinRM, sets the network profile to Private, opens the firewall
  for WinRM + File and Printer Sharing (admin shares) + ICMP, and sets
  LocalAccountTokenFilterPolicy=1 so the local Administrator works over the network
  on this non-domain host. Prints the host-only IP to use from the controller.

  SECURITY: enables Basic/unencrypted WinRM for POC simplicity over the isolated
  host-only network (192.168.56.0/24). Do NOT use these settings on real servers -
  production hosts are domain-joined and use Kerberos/HTTPS.
#>
$ErrorActionPreference = 'Continue'
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
Enable-NetFirewallRule -DisplayGroup 'Windows Remote Management','File and Printer Sharing' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'POC ICMPv4 In' -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
winrm set winrm/config/service '@{AllowUnencrypted="true"}'   | Out-Null
winrm set winrm/config/service/auth '@{Basic="true"}'         | Out-Null
Write-Host "Host-only IP (use this from the controller):"
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    ForEach-Object { "  {0}  ({1})" -f $_.IPAddress, $_.InterfaceAlias }
