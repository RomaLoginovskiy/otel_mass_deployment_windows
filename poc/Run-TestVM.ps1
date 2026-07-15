<#
.SYNOPSIS
  POC-ONLY helper: create / run a Windows test VM in VirtualBox from the ISO in
  vm_images, and drive the deployment package into it via guestcontrol.

.DESCRIPTION
  THROWAWAY convenience for validating the BatchPatch deployment package on a
  clean Windows Server before rolling it across the real fleet. This is NOT part
  of the fleet automation - it just gives you one disposable target.

  vm_images holds a Windows Server 2025 EVAL *ISO* (not a ready appliance), so the
  first run needs a one-time interactive Windows install + Guest Additions, after
  which you snapshot a 'baseline' and the rest is scriptable.

  Typical flow:
    .\Run-TestVM.ps1 -Action Create        # create VM, attach ISO+disk
    .\Run-TestVM.ps1 -Action Start -Gui     # boot; install Windows + Guest Additions by hand
    .\Run-TestVM.ps1 -Action Snapshot -SnapshotName baseline
    ..\Build-DeploymentPackage.ps1 -KeyFile C:\secrets\cx.key
    .\Run-TestVM.ps1 -Action Deploy -User Administrator -Password '<pw>'   # copyto + run deploy.bat
    .\Run-TestVM.ps1 -Action Restore -SnapshotName baseline                # reset for another run

.PARAMETER Action
  Create | Start | Stop | Snapshot | Restore | Deploy | Info | Destroy

.NOTES
  Requires VirtualBox (VBoxManage). guestcontrol needs Guest Additions installed
  in the guest and valid guest credentials.
#>
[CmdletBinding()]
param(
    [ValidateSet('Unattended','Create','Configure','Start','Stop','Snapshot','Restore','Deploy','Info','Destroy')]
    [string] $Action = 'Info',
    [string] $VmName       = 'cx-fleet-test',
    [string] $IsoPath      = (Join-Path $PSScriptRoot '..\vm_images\26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso'),
    [string] $PackagePath  = (Join-Path $PSScriptRoot '..\coralogix-agent-deploy.zip'),
    [int]    $MemoryMB     = 4096,
    [int]    $Cpus         = 2,
    [int]    $DiskMB       = 51200,
    [string] $SnapshotName = 'baseline',
    [switch] $Gui,
    [string] $User         = 'Administrator',
    [string] $Password     = 'Otel!Passw0rd2026',
    [string] $GuestStageDir= 'C:\cx-deploy',
    [string] $AdditionsIso = (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxGuestAdditions.iso'),
    [string] $HostOnlyIf   = 'VirtualBox Host-Only Ethernet Adapter'
)

$ErrorActionPreference = 'Stop'

$vbox = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $vbox)) { $vbox = 'VBoxManage.exe' }  # rely on PATH
function VBox { & $vbox @args; if ($LASTEXITCODE -ne 0) { throw "VBoxManage failed: $($args -join ' ')" } }
# Tolerant variant: run VBoxManage but never throw (e.g. poweroff on an already-off VM
# returns non-zero "not currently running" - not a real failure for Destroy/Restore).
# Under $ErrorActionPreference='Stop', PS 5.1 turns any native stderr write into a
# terminating NativeCommandError even with 2>$null, so swallow it explicitly.
function VBoxSoft {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $vbox @args 2>&1 | Out-Null } catch { }
    $ErrorActionPreference = $old
    $global:LASTEXITCODE = 0
}

switch ($Action) {

    'Unattended' {
        # Hands-off provisioning: create the VM and let VBox drive Windows Setup
        # (auto answer file) + install Guest Additions. No interactive steps.
        if (-not (Test-Path $IsoPath))      { throw "ISO not found: $IsoPath" }
        if (-not (Test-Path $AdditionsIso)) { throw "Guest Additions ISO not found: $AdditionsIso" }
        $vmDir = Join-Path $env:USERPROFILE 'VirtualBox VMs'
        VBox createvm --name $VmName --ostype Windows2025_64 --register
        VBox modifyvm $VmName --memory $MemoryMB --cpus $Cpus --firmware efi `
            --nic1 nat --nic2 hostonly --hostonlyadapter2 $HostOnlyIf `
            --graphicscontroller vboxsvga --vram 128 --audio-driver none --usbohci on
        $disk = Join-Path (Join-Path $vmDir $VmName) "$VmName.vdi"
        VBox createmedium disk --filename $disk --size $DiskMB --format VDI
        VBox storagectl $VmName --name 'SATA' --add sata --controller IntelAhci --portcount 4
        VBox storageattach $VmName --storagectl 'SATA' --port 0 --device 0 --type hdd --medium $disk
        VBox unattended install $VmName --iso=$IsoPath --image-index=2 `
            --user=$User --password=$Password --full-user-name=$User `
            --install-additions --additions-iso=$AdditionsIso `
            --locale=en_US --country=US --time-zone=UTC --language=en-US `
            --start-vm=headless
        Write-Host "[poc] '$VmName' is installing Windows unattended (~20-40 min). Guest Additions install automatically."
        Write-Host "[poc] Poll readiness: VBoxManage guestcontrol $VmName --username $User --password <pw> run --exe cmd.exe --wait-stdout -- cmd /c echo READY"
    }

    'Create' {
        if (-not (Test-Path $IsoPath)) { throw "ISO not found: $IsoPath" }
        $vmDir = Join-Path $env:USERPROFILE 'VirtualBox VMs'
        VBox createvm --name $VmName --ostype Windows2022_64 --register
        VBox modifyvm $VmName --memory $MemoryMB --cpus $Cpus --nic1 nat --graphicscontroller vboxsvga --vram 128 --firmware efi
        $disk = Join-Path (Join-Path $vmDir $VmName) "$VmName.vdi"
        VBox createmedium disk --filename $disk --size $DiskMB --format VDI
        VBox storagectl $VmName --name 'SATA' --add sata --controller IntelAhci
        VBox storageattach $VmName --storagectl 'SATA' --port 0 --device 0 --type hdd --medium $disk
        VBox storageattach $VmName --storagectl 'SATA' --port 1 --device 0 --type dvddrive --medium $IsoPath
        Write-Host "[poc] VM '$VmName' created. Next: -Action Start -Gui and install Windows + Guest Additions."
    }

    'Configure' {
        # Copy Configure-Guest.ps1 into the guest and run it: enable IIS + ASP.NET,
        # WinRM/PSRemoting + firewall + local-admin-over-network (so BatchPatch can
        # reach it from the host). Requires Guest Additions up + valid credentials.
        $cfg = Join-Path $PSScriptRoot 'Configure-Guest.ps1'
        if (-not (Test-Path $cfg)) { throw "Configure-Guest.ps1 not found next to this script." }
        $gc = @('guestcontrol', $VmName, '--username', $User, '--password', $Password)
        VBox @gc mkdir "$GuestStageDir" --parents
        VBox @gc copyto "$cfg" "$GuestStageDir\Configure-Guest.ps1"
        Write-Host "[poc] running Configure-Guest.ps1 in guest ..."
        # NOTE: '--' MUST be quoted. PowerShell strips a bare -- token (its
        # end-of-parameters marker) before it reaches VBoxManage, which then
        # parses -NoProfile as its own option and fails. Quoting passes it through.
        # Args after -- go straight to powershell.exe (arg0 = the --exe path), so
        # do NOT repeat a leading 'powershell' token.
        VBox @gc run --exe 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' --wait-stdout --wait-stderr `
            '--' -NoProfile -ExecutionPolicy Bypass -File "$GuestStageDir\Configure-Guest.ps1"
        Write-Host "[poc] guest configured (IIS + WinRM/firewall). Ready for BatchPatch / Deploy."
    }

    'Start' {
        $type = if ($Gui) { 'gui' } else { 'headless' }
        VBox startvm $VmName --type $type
        Write-Host "[poc] started '$VmName' ($type). For the first boot use -Gui to install Windows interactively."
    }

    'Stop'   { VBox controlvm $VmName acpipowerbutton; Write-Host "[poc] ACPI shutdown sent to '$VmName'." }

    'Snapshot' {
        VBox snapshot $VmName take $SnapshotName --description "POC baseline: Windows + Guest Additions installed"
        Write-Host "[poc] snapshot '$SnapshotName' taken."
    }

    'Restore' {
        VBoxSoft controlvm $VmName poweroff
        Start-Sleep -Seconds 2
        VBox snapshot $VmName restore $SnapshotName
        Write-Host "[poc] restored '$VmName' to snapshot '$SnapshotName'. Start it again to reuse."
    }

    'Deploy' {
        if (-not $Password) { throw "Provide -Password for the guest '$User' account." }
        if (-not (Test-Path $PackagePath)) { throw "Package not found: $PackagePath (run Build-DeploymentPackage.ps1 first)" }
        $gc = @('guestcontrol', $VmName, '--username', $User, '--password', $Password)

        Write-Host "[poc] copying package into guest $GuestStageDir ..."
        VBox @gc mkdir "$GuestStageDir" --parents
        $guestZip = "$GuestStageDir\coralogix-agent-deploy.zip"
        VBox @gc copyto "$PackagePath" "$guestZip"

        Write-Host "[poc] expanding + running deploy.bat in guest ..."
        VBox @gc run --exe 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' --wait-stdout --wait-stderr `
            '--' -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Path '$guestZip' -DestinationPath '$GuestStageDir\pkg' -Force"
        VBox @gc run --exe "$GuestStageDir\pkg\deploy.bat" --wait-stdout --wait-stderr
        Write-Host "[poc] deploy.bat completed in guest. Check Coralogix Fleet Management for the agent."
    }

    'Info' {
        Write-Host "[poc] VMs:"; VBox list vms
        Write-Host "[poc] running:"; VBox list runningvms
        Write-Host "[poc] ISO: $IsoPath ($(if (Test-Path $IsoPath){'present'}else{'MISSING'}))"
    }

    'Destroy' {
        VBoxSoft controlvm $VmName poweroff
        Start-Sleep -Seconds 2
        VBox unregistervm $VmName --delete
        Write-Host "[poc] '$VmName' destroyed."
    }
}
