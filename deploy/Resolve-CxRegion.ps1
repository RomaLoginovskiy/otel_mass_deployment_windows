<#
.SYNOPSIS
  Coralogix REGION <-> DOMAIN resolution. Dot-sourced by the install scripts, the
  doctor and the package builder so there is exactly ONE region table in the repo.

.DESCRIPTION
  A Coralogix account lives in one region and every integration endpoint is derived
  from that region's domain (the collector's coralogix exporter turns `domain` into
  ingress.<domain>:443, and the vendor installer turns the same value into the OpAMP
  endpoint https://ingress.<domain>/opamp/v1).

  Operators think in region codes (eu1, eu2, us1, ...), which is what -Region takes.
  The canonical domain for a region is simply <region>.coralogix.com - see
  https://coralogix.com/docs/user-guides/account-management/account-settings/coralogix-domain/

  A wrong region is the worst kind of failure here: the collector starts, reports
  healthy, and ships to an account that is not yours - so an unknown region code is a
  hard error rather than a warning. Private / non-standard ingress domains stay
  possible through -Domain, which bypasses this table entirely.

  Functions:
    Get-CxRegions          - the supported region codes.
    Resolve-CxDomain       - region code (or canonical domain) -> domain. Throws on
                             anything it does not recognise.
    Get-CxRegionForDomain  - domain -> region code, or $null when the domain is not
                             one Coralogix publishes (private ingress, proxy, typo).
                             For DISPLAY only - never gate an install on it.
#>

# Region -> canonical exporter domain. The account's own team hostname (e.g.
# <team>.app.eu2.coralogix.com) is NOT this value and must not be passed as -Domain.
$script:CxRegionDomains = [ordered]@{
    'us1' = 'us1.coralogix.com'   # AWS us-east-2      (Ohio)
    'us2' = 'us2.coralogix.com'   # AWS us-west-2      (Oregon)
    'us3' = 'us3.coralogix.com'   # GCP us-central1    (Iowa)
    'eu1' = 'eu1.coralogix.com'   # AWS eu-west-1      (Ireland)
    'eu2' = 'eu2.coralogix.com'   # AWS eu-north-1     (Stockholm)
    'ap1' = 'ap1.coralogix.com'   # AWS ap-south-1     (Mumbai)
    'ap2' = 'ap2.coralogix.com'   # AWS ap-southeast-1 (Singapore)
    'ap3' = 'ap3.coralogix.com'   # AWS ap-southeast-3 (Jakarta)
}

# Older per-region domains that are still accepted by the exporter and still appear in
# runbooks. Recognised so the doctor can NAME the region instead of reporting a domain
# it does not know, and so -Region keeps working if someone pastes one of these.
$script:CxLegacyDomains = @{
    'coralogix.com'       = 'eu1'
    'coralogix.us'        = 'us1'
    'app.coralogix.us'    = 'us1'
    'cx498.coralogix.com' = 'us2'
    'coralogix.in'        = 'ap1'
    'app.coralogix.in'    = 'ap1'
    'coralogixsg.com'     = 'ap2'
    'app.coralogixsg.com' = 'ap2'
}

function Get-CxRegions {
    <# Supported region codes, in table order. #>
    return @($script:CxRegionDomains.Keys)
}

function Format-CxRegionList {
    <# Human-readable "eu1, eu2, ..." for error messages and help text. #>
    return ((Get-CxRegions) -join ', ')
}

function Normalize-CxDomainString {
    <#
      Operators paste URLs. Strip the scheme, any path and a trailing dot/slash so
      'https://eu2.coralogix.com/' and 'eu2.coralogix.com' resolve identically.
    #>
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $v = $Value.Trim().ToLowerInvariant()
    $v = $v -replace '^[a-z]+://', ''
    $v = ($v -split '/')[0]
    return $v.TrimEnd('.')
}

function Assert-CxDomainNotEmpty {
    <#
      Guard for the explicit-domain inputs (-Domain and CX_DOMAIN), which bypass the
      region table on purpose and so have no other validation.

      A whitespace-only value must fail rather than be honoured: `set CX_DOMAIN= `
      satisfies cmd.exe's `if defined`, deploy.bat then forwards -Domain "   ", and
      normalizing that yields ''. An empty CORALOGIX_DOMAIN makes the exporters ship to
      'ingress.' while the collector still reports healthy - the exact silent-misroute
      failure Resolve-CxDomain refuses to allow for an empty region.
    #>
    param([string] $Normalized, [string] $Source)

    if ([string]::IsNullOrWhiteSpace($Normalized)) {
        throw ("$Source is set but empty. Pass a full ingress domain (e.g. eu2.coralogix.com " +
               "or a private ingress host), or unset it to fall back to the region.")
    }
    return $Normalized
}

function Resolve-CxDomain {
    <#
    .SYNOPSIS
      Region code -> Coralogix domain.

    .DESCRIPTION
      Accepts a bare region code ('eu2', 'EU2'), the canonical domain for a region
      ('eu2.coralogix.com', 'https://eu2.coralogix.com/'), or one of the legacy
      per-region domains. Throws on anything else: an unrecognised region silently
      ships telemetry nowhere (or to the wrong account), so it must fail the install
      instead of being defaulted.
    #>
    param([Parameter(Mandatory)] [string] $Region)

    $r = Normalize-CxDomainString $Region
    if (-not $r) { throw "Region is empty. Use one of: $(Format-CxRegionList) (or pass -Domain for a private ingress domain)." }

    if ($script:CxRegionDomains.Contains($r)) { return $script:CxRegionDomains[$r] }

    # Someone passed a domain where a region was expected. Accept it when it is a
    # domain Coralogix publishes, so the two spellings cannot disagree.
    if ($script:CxLegacyDomains.ContainsKey($r)) { return $r }
    foreach ($k in $script:CxRegionDomains.Keys) {
        if ($script:CxRegionDomains[$k] -eq $r) { return $r }
    }

    throw ("Unknown Coralogix region '$Region'. Supported: $(Format-CxRegionList). " +
           "For a private or non-standard ingress domain pass -Domain '<domain>' instead of -Region.")
}

function Get-CxRegionForDomain {
    <#
      Domain -> region code for DISPLAY (doctor output, install log lines). Returns
      $null for a domain that is not one Coralogix publishes - which is legitimate
      (private ingress) as well as what a typo looks like, hence display-only.
    #>
    param([string] $Domain)

    $d = Normalize-CxDomainString $Domain
    if (-not $d) { return $null }
    foreach ($k in $script:CxRegionDomains.Keys) {
        if ($script:CxRegionDomains[$k] -eq $d) { return $k }
    }
    if ($script:CxLegacyDomains.ContainsKey($d)) { return $script:CxLegacyDomains[$d] }
    return $null
}
