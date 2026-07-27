<#
.SYNOPSIS
  Discover where IIS actually writes its access logs, so the collector can be
  pointed at them.

.DESCRIPTION
  PURE FUNCTION LIBRARY - dot-source it. Nothing runs on load, nothing is written.

    Get-IISLogConfig     parse the logging section of applicationHost.config
    Get-IISLogDirValue   the distinct log directories NOT already covered by the
                         collector's built-in default glob, comma-joined
    Get-IISLogDirSlots   those directories split into the fixed CX_IIS_LOG_DIR_n slots
    Test-IISLogDirCovered  does a given directory fall under a given include glob?

  WHY THIS EXISTS. The collector's filelog/iis receiver ships one hardcoded path:

      C:\inetpub\logs\LogFiles\W3SVC*\*.log

  That is the IIS default and nothing more. A site with its own logFile directory,
  a host using central W3C logging, or a site logging in IIS/NCSA format instead of
  W3C produces NO logs in Coralogix - silently, with nothing anywhere saying why.
  This library finds the real paths so Instrument-IIS.ps1 can publish them and
  Test-IISInstrumentation.ps1 can report the ones that are not covered.

  THE SLOT LIMIT, stated up front because it is a real constraint and not an
  oversight: an OTel `include:` is a LIST, and `${env:VAR}` expands to a single
  scalar. One environment variable therefore cannot become N list entries. The
  config template carries a fixed number of slots (CX_IIS_LOG_DIR_1..3) and a host
  with more distinct log roots than slots is REPORTED rather than silently
  truncated. Raising the ceiling means adding slots to the template.

.NOTES
  Windows PowerShell 5.1. Reads applicationHost.config directly rather than using
  WebAdministration, for the same reason Test-IISInstrumentation.ps1 does: the IIS
  management tools are missing on some fleet hosts.
#>

# Number of ${env:CX_IIS_LOG_DIR_n} slots the collector config template declares.
# Changing this alone does nothing - the template must declare the same count.
$script:CxLogDirSlotCount = 3

# The glob the collector ships with. Directories already covered by it must NOT be
# published into a slot: filelog would then match the same files twice through two
# include entries, and every access-log line would be ingested twice.
$script:CxDefaultLogGlob = 'C:\inetpub\logs\LogFiles\W3SVC*\*.log'

function Get-CxLogInetsrvDir {
    # WOW64: System32 is redirected to SysWOW64 for a 32-bit process, and
    # SysWOW64\inetsrv has no config\applicationHost.config. Same resolver as
    # Test-IISInstrumentation.ps1's Get-CxInetsrvDir - see the long comment there.
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        return (Join-Path $env:windir 'Sysnative\inetsrv')
    }
    return (Join-Path $env:windir 'System32\inetsrv')
}

function Get-IISLogConfig {
    <#
      Parse the logging configuration out of applicationHost.config.

      Returns:
        Ok            [bool]
        Error         [string]  set when Ok is false
        CentralMode   'Site' | 'CentralW3C' | 'CentralBinary'
        CentralDir    [string]  the central log directory, when not per-site
        Sites         one record per site:
                        Name, Id, Enabled, Format, Directory (expanded), LogRoot

      LogRoot is where files actually land, which is NOT always Directory:
        * per-site logging  -> <Directory>\W3SVC<Id>
        * central logging   -> <CentralDir>  (one file for the whole host)

      Never throws.
    #>
    [CmdletBinding()]
    param(
        [string] $AppHostConfig = (Join-Path (Get-CxLogInetsrvDir) 'config\applicationHost.config')
    )

    $result = [pscustomobject]@{
        Ok          = $false
        Error       = $null
        CentralMode = 'Site'
        CentralDir  = ''
        Sites       = @()
    }

    # Read-then-classify, never Test-Path first: on a permission-denied path
    # Test-Path emits a non-terminating error and returns $false, which would be
    # reported as "no logging configured" on a host that simply needs elevation.
    try {
        [xml]$xml = Get-Content -LiteralPath $AppHostConfig -Raw -ErrorAction Stop
    } catch {
        $result.Error = "could not read applicationHost.config: $($_.Exception.Message)"
        return $result
    }

    function Expand-CxPath([string] $p) {
        if (-not $p) { return '' }
        try { $p = [Environment]::ExpandEnvironmentVariables($p) } catch { }
        return $p.TrimEnd('\')
    }

    try {
        # ---- host-wide log section ------------------------------------------
        # centralLogFileMode defaults to Site when the attribute is absent.
        $logNode = $xml.SelectSingleNode('/configuration/system.applicationHost/log')
        if ($logNode -and $logNode.HasAttribute('centralLogFileMode')) {
            $mode = [string]$logNode.GetAttribute('centralLogFileMode')
            if ($mode) { $result.CentralMode = $mode }
        }
        if ($logNode) {
            $centralNode = if ($result.CentralMode -eq 'CentralBinary') {
                $logNode.SelectSingleNode('centralBinaryLogFile')
            } else {
                $logNode.SelectSingleNode('centralW3CLogFile')
            }
            if ($centralNode) {
                $result.CentralDir = Expand-CxPath ([string]$centralNode.GetAttribute('directory'))
            }
        }
        if (-not $result.CentralDir) {
            $result.CentralDir = Expand-CxPath '%SystemDrive%\inetpub\logs\LogFiles'
        }

        # ---- per-site logFile, with siteDefaults inheritance ------------------
        $sitesRoot = $xml.SelectSingleNode('/configuration/system.applicationHost/sites')
        if ($sitesRoot) {
            $defDir = ''; $defFmt = ''; $defEnabled = $null
            $siteDefaults = $sitesRoot.SelectSingleNode('siteDefaults/logFile')
            if ($siteDefaults) {
                $defDir = [string]$siteDefaults.GetAttribute('directory')
                $defFmt = [string]$siteDefaults.GetAttribute('logFormat')
                if ($siteDefaults.HasAttribute('enabled')) {
                    $defEnabled = ([string]$siteDefaults.GetAttribute('enabled')) -ne 'false'
                }
            }
            # IIS's own defaults when neither the site nor siteDefaults says.
            if (-not $defDir) { $defDir = '%SystemDrive%\inetpub\logs\LogFiles' }
            if (-not $defFmt) { $defFmt = 'W3C' }
            if ($null -eq $defEnabled) { $defEnabled = $true }

            foreach ($site in @($sitesRoot.SelectNodes('site'))) {
                $name = [string]$site.GetAttribute('name')
                if (-not $name) { continue }
                $id   = [string]$site.GetAttribute('id')

                $dir = $defDir; $fmt = $defFmt; $enabled = $defEnabled
                $lf = $site.SelectSingleNode('logFile')
                if ($lf) {
                    if ($lf.HasAttribute('directory')) {
                        $d = [string]$lf.GetAttribute('directory'); if ($d) { $dir = $d }
                    }
                    if ($lf.HasAttribute('logFormat')) {
                        $f = [string]$lf.GetAttribute('logFormat'); if ($f) { $fmt = $f }
                    }
                    if ($lf.HasAttribute('enabled')) {
                        $enabled = ([string]$lf.GetAttribute('enabled')) -ne 'false'
                    }
                }

                $dirX = Expand-CxPath $dir
                $root = if ($result.CentralMode -ne 'Site') {
                    $result.CentralDir
                } elseif ($id) {
                    Join-Path $dirX "W3SVC$id"
                } else {
                    $dirX
                }

                $result.Sites += [pscustomobject]@{
                    Name      = $name
                    Id        = $id
                    Enabled   = $enabled
                    Format    = $fmt
                    Directory = $dirX
                    LogRoot   = $root
                }
            }
        }

        $result.Ok = $true
    } catch {
        $result.Error = "unexpected shape in the applicationHost.config log section: $($_.Exception.Message)"
    }

    return $result
}

function Test-IISLogDirCovered {
    <#
      Is $Directory matched by $Glob?

      Compares DIRECTORIES, not filenames, so the glob's file component is dropped
      first. Two wildcard forms have to behave differently, and getting either
      wrong silently mis-reports coverage:

        ...\W3SVC*\*.log   ->  W3SVC* is ONE path segment. Covers
                               C:\inetpub\logs\LogFiles\W3SVC1 but NOT its parent
                               C:\inetpub\logs\LogFiles.
        ...\<dir>\**\*.log ->  ** is "this directory and everything below". Covers
                               <dir> ITSELF as well as <dir>\W3SVC1 - which matters
                               because central W3C logging writes its file directly
                               into <dir> with no subfolder.

      -like cannot express "exactly one segment", hence the regex.
    #>
    [CmdletBinding()]
    param([string] $Directory, [string] $Glob)

    if (-not $Directory -or -not $Glob) { return $false }

    # Drop the filename component - we are matching a directory.
    $globDir = Split-Path -Parent $Glob
    if (-not $globDir) { return $false }
    $globDir = $globDir.TrimEnd('\')

    # A trailing '**' means the base directory itself also counts as covered, so
    # strip it and match the base as a prefix rather than requiring a child.
    if ($globDir -match '^(.*)\\\*\*$') { $globDir = $Matches[1] }

    $pattern = [regex]::Escape($globDir)
    $pattern = $pattern -replace '\\\*\\\*', '.*'      # any remaining '**'
    $pattern = $pattern -replace '\\\*', '[^\\]*'      # '*' = one segment
    return ($Directory.TrimEnd('\') -match ('^' + $pattern + '(\\|$)'))
}

function Get-IISLogDirValue {
    <#
      The distinct ACTIVE log directories that the collector's built-in default
      glob does NOT already cover, comma-joined - the same shape as
      Get-IISServiceLabelValue's CX_IIS_SERVICES.

      Sites with logging disabled are excluded: there is nothing to collect and
      publishing the path would make the doctor look for files that will never
      appear. Non-W3C sites ARE included - the files exist and are worth tailing
      even though the csv parser cannot field-split them; the doctor reports the
      format separately.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config,
        [string[]] $DefaultGlobs = @($script:CxDefaultLogGlob)
    )

    if (-not $Config -or -not $Config.Ok) { return '' }

    $out = New-Object System.Collections.ArrayList
    $seen = @{}

    # Two different paths per site, and conflating them is a real bug:
    #   Check   = where the log FILES land (…\LogFiles\W3SVC1). This is what the
    #             default glob …\LogFiles\W3SVC*\*.log actually matches.
    #   Publish = the configured DIRECTORY (…\LogFiles). This is what goes in a
    #             slot, because the slot glob is <dir>\**\*.log and so covers every
    #             site's W3SVC<id> subfolder with one entry.
    # Testing coverage against Publish instead of Check would find the parent
    # unmatched and publish C:\inetpub\logs\LogFiles into a slot - a second include
    # over files the default already reads, i.e. every access-log line ingested twice.
    if ($Config.CentralMode -ne 'Site') {
        # One file for the whole host, written straight into the directory.
        $pairs = @(, @{ Check = $Config.CentralDir; Publish = $Config.CentralDir })
    } else {
        $pairs = @($Config.Sites | Where-Object { $_.Enabled } |
                   ForEach-Object { @{ Check = $_.LogRoot; Publish = $_.Directory } })
    }

    foreach ($p in $pairs) {
        if (-not $p.Publish) { continue }
        $key = $p.Publish.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $covered = $false
        foreach ($g in @($DefaultGlobs)) {
            if (Test-IISLogDirCovered -Directory $p.Check -Glob $g) { $covered = $true; break }
        }
        if (-not $covered) { [void]$out.Add($p.Publish) }
    }

    return (($out.ToArray()) -join ',')
}

function Get-IISLogDirSlots {
    <#
      Split a comma-joined directory list into the fixed slots, returning

        @{ Slots = @{ CX_IIS_LOG_DIR_1 = '...'; ... }; Overflow = @(...) }

      Overflow is the directories that did not fit. Callers must surface it -
      dropping it silently is exactly the failure mode this library exists to end.
      Unused slots come back as empty strings so a caller can CLEAR a stale value
      from a previous deploy rather than leaving it pointing at a removed site.
    #>
    [CmdletBinding()]
    param(
        [string] $Value,
        [int]    $SlotCount = $script:CxLogDirSlotCount
    )

    $dirs = @()
    if ($Value) { $dirs = @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

    $slots = [ordered]@{}
    for ($i = 1; $i -le $SlotCount; $i++) {
        $slots["CX_IIS_LOG_DIR_$i"] = if ($dirs.Count -ge $i) { $dirs[$i - 1] } else { '' }
    }

    $overflow = @()
    if ($dirs.Count -gt $SlotCount) { $overflow = @($dirs[$SlotCount..($dirs.Count - 1)]) }

    return @{ Slots = $slots; Overflow = $overflow; SlotCount = $SlotCount }
}
