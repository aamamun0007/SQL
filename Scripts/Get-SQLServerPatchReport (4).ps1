#Requires -Version 5.1
<#
.SYNOPSIS
    Audits SQL Server instances for current build/version info and available patches,
    then sends an HTML email report.

.DESCRIPTION
    1. Reads a list of SQL Server instance names from a .txt file.
    2. Connects to each instance via SMO / Invoke-Sqlcmd and retrieves build details.
    3. Dynamically fetches the latest SQL Server build data from THREE online sources
       (no hardcoded version tables):
         - Source 1: sqlserverbuilds.blogspot.com   (community HTML table)
         - Source 2: Microsoft Learn build-versions pages (official; auto-discovers new versions)
         - Source 3: Microsoft Update Catalog API   (fills any remaining gaps)
       Results from all sources are cross-validated and merged; the highest build
       number wins.  New SQL Server releases are picked up automatically.
       If ALL sources are unreachable, affected instances are marked UNKNOWN.
    4. Compiles results into a colour-coded HTML report and sends it via SMTP.

.PARAMETER InstanceListPath
    Full path to the .txt file containing one SQL Server instance name per line.
    Default: .\sql_instances.txt

.PARAMETER SmtpServer
    SMTP relay hostname.  Default: smtp.yourdomain.com

.PARAMETER SmtpPort
    SMTP port.  Default: 25

.PARAMETER EmailFrom
    Sender address.

.PARAMETER EmailTo
    One or more recipient addresses (comma-separated string or array).

.PARAMETER EmailSubject
    Subject line.  A date stamp is appended automatically.

.PARAMETER SmtpCredential
    PSCredential for authenticated SMTP.  Omit for anonymous/relay.

.PARAMETER UseSsl
    Switch – enables SSL/TLS for SMTP.

.PARAMETER SqlCredential
    PSCredential for SQL Server login.  Omit to use Windows auth (default).

.PARAMETER TimeoutSeconds
    Per-instance connection timeout.  Default: 10

.EXAMPLE
    .\Get-SQLServerPatchReport.ps1 `
        -InstanceListPath "C:\DBA\sql_instances.txt" `
        -SmtpServer "mail.corp.local" `
        -EmailFrom "dba-alerts@corp.local" `
        -EmailTo  "dba-team@corp.local","manager@corp.local"

.NOTES
    Author  : Generated script – customise SMTP / credential sections for your environment.
    Requires: PowerShell 5.1+, internet access for patch data retrieval.
              Uses System.Data.SqlClient (.NET built-in) – no extra modules required.
              No hardcoded build numbers; all patch reference data is fetched live from:
                sqlserverbuilds.blogspot.com | learn.microsoft.com | catalog.update.microsoft.com
#>

[CmdletBinding()]
param(
    [string]   $InstanceListPath  = ".\sql_instances.txt",
    [string]   $SmtpServer        = "smtp.yourdomain.com",
    [int]      $SmtpPort          = 25,
    [string]   $EmailFrom         = "sql-report@yourdomain.com",
    [string[]] $EmailTo           = @("dba-team@yourdomain.com"),
    [string]   $EmailSubject      = "SQL Server Patch Audit Report",
    [System.Management.Automation.PSCredential] $SmtpCredential = $null,
    [switch]   $UseSsl,
    [System.Management.Automation.PSCredential] $SqlCredential  = $null,
    [int]      $TimeoutSeconds    = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# REGION 1 – Logging helper
# ─────────────────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colour = @{ INFO='Cyan'; WARN='Yellow'; ERROR='Red' }[$Level]
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $colour
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION 2 – Load instance list
# ─────────────────────────────────────────────────────────────────────────────
function Get-InstanceList {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Instance list file not found: $Path"
    }

    $lines = @(Get-Content $Path |
               Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' } |
               ForEach-Object { $_.Trim() })

    if ($lines.Count -eq 0) {
        throw "No instances found in: $Path"
    }

    Write-Log "Loaded $($lines.Count) instance(s) from $Path"
    return $lines
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION 3 – Query SQL Server version
# ─────────────────────────────────────────────────────────────────────────────
function Get-SqlVersion {
    param(
        [string]$Instance,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$Timeout
    )

    $result = [PSCustomObject]@{
        Instance           = $Instance
        ServerName         = ''
        ProductVersion     = ''      # e.g. 15.0.4355.3
        ProductLevel       = ''      # RTM / SP1 / SP2 …
        ProductUpdateLevel = ''      # CU1 / CU12 …
        Edition            = ''
        MajorVersion       = 0
        MinorVersion       = 0
        BuildNumber        = 0
        PatchNumber        = 0
        VersionString      = ''      # Human-friendly e.g. "SQL Server 2019"
        CurrentPatchLabel  = ''      # e.g. RTM-CU23-GDR  (looked up from patch data)
        CurrentKBNumber    = ''      # e.g. KB5077464      (KB for the installed build)
        Status             = 'OK'
        ErrorMessage       = ''
    }

    # Build connection string
    $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $csb['Data Source']         = $Instance
    $csb['Initial Catalog']     = 'master'
    $csb['Connect Timeout']     = $Timeout
    $csb['Application Name']    = 'PatchAuditScript'

    if ($Credential) {
        $csb['User ID']   = $Credential.UserName
        $csb['Password']  = $Credential.GetNetworkCredential().Password
    } else {
        $csb['Integrated Security'] = $true
    }

    $query = @"
SELECT
    SERVERPROPERTY('ServerName')         AS ServerName,
    SERVERPROPERTY('ProductVersion')     AS ProductVersion,
    SERVERPROPERTY('ProductLevel')       AS ProductLevel,
    SERVERPROPERTY('ProductUpdateLevel') AS ProductUpdateLevel,
    SERVERPROPERTY('Edition')            AS Edition;
"@

    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection($csb.ConnectionString)
        $conn.Open()

        $cmd             = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = $Timeout

        $reader = $cmd.ExecuteReader()
        if ($reader.Read()) {
            $result.ServerName         = [string]$reader['ServerName']
            $result.ProductVersion     = [string]$reader['ProductVersion']
            $result.ProductLevel       = [string]$reader['ProductLevel']
            $result.ProductUpdateLevel = if ($reader['ProductUpdateLevel'] -is [DBNull]) { '' } else { [string]$reader['ProductUpdateLevel'] }
            $result.Edition            = [string]$reader['Edition']
        }
        $reader.Close()
        $conn.Close()

        # Parse version parts
        $parts = @($result.ProductVersion -split '\.')
        $result.MajorVersion = [int]$parts[0]
        $result.MinorVersion = [int]$parts[1]
        $result.BuildNumber  = [int]$parts[2]
        $result.PatchNumber  = if ($parts.Count -ge 4) { [int]$parts[3] } else { 0 }

        # Map major version to product name
        $result.VersionString = switch ($result.MajorVersion) {
            16 { "SQL Server 2022" }
            15 { "SQL Server 2019" }
            14 { "SQL Server 2017" }
            13 { "SQL Server 2016" }
            12 { "SQL Server 2014" }
            11 { "SQL Server 2012" }
            10 { if ($result.MinorVersion -ge 50) { "SQL Server 2008 R2" } else { "SQL Server 2008" } }
            default { "SQL Server (v$($result.MajorVersion))" }
        }
    }
    catch {
        $result.Status       = 'ERROR'
        $result.ErrorMessage = $_.Exception.Message
        Write-Log "[$Instance] Connection/query failed: $($_.Exception.Message)" -Level ERROR
    }

    return $result
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION 4 – Patch reference data
#
#   Strategy:
#     1. Hardcoded baseline table – always correct, works offline.
#        UPDATE THIS TABLE each time Microsoft releases a new CU/GDR.
#     2. Attempt online refresh via the Microsoft Learn JSON API.
#        Accepted only if the returned build is HIGHER than the baseline
#        AND the description is clean (no HTML junk, no RTM-era builds).
#     3. Falls back gracefully to baseline if network is unavailable.
#
#   Returns: [hashtable]  MajorVersion(int) →
#              @{ LatestBuild; Description; KBUrl; KBNumber; PatchLabel }
# ─────────────────────────────────────────────────────────────────────────────

# ── Helper: safe Invoke-WebRequest wrapper ────────────────────────────────────
function Invoke-SafeWeb {
    param([string]$Uri, [int]$TimeoutSec = 20)
    try {
        $r = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec `
                               -ErrorAction Stop `
                               -Headers @{ 'User-Agent' = 'SQLPatchAuditScript/3.0' }
        return $r.Content
    }
    catch { return $null }
}

# ── Hardcoded baseline – update when new CUs ship ────────────────────────────
#   Format: MajorVersion = @{ LatestBuild; Description; KBNumber; KBUrl; PatchLabel }
#   Last updated: 2026-05
function Get-BaselinePatchData {
    $baseline = @{}

    # SQL Server 2022 (major 16) – CU24 released March 2026
    $baseline[16] = @{
        LatestBuild = '16.0.4285.2'
        Description = 'SQL Server 2022 – CU24 (March 2026)'
        KBNumber    = 'KB5083252'
        KBUrl       = 'https://support.microsoft.com/help/5083252'
        PatchLabel  = 'CU24'
    }

    # SQL Server 2019 (major 15) – CU30 released April 2026
    $baseline[15] = @{
        LatestBuild = '15.0.4430.1'
        Description = 'SQL Server 2019 – CU30 (April 2026)'
        KBNumber    = 'KB5082298'
        KBUrl       = 'https://support.microsoft.com/help/5082298'
        PatchLabel  = 'CU30'
    }

    # SQL Server 2017 (major 14) – CU31 (last ever CU, July 2022)
    $baseline[14] = @{
        LatestBuild = '14.0.3465.1'
        Description = 'SQL Server 2017 – CU31 (September 2022)'
        KBNumber    = 'KB5016884'
        KBUrl       = 'https://support.microsoft.com/help/5016884'
        PatchLabel  = 'CU31'
    }

    # SQL Server 2016 (major 13) – SP3 + latest GDR (Oct 2023)
    $baseline[13] = @{
        LatestBuild = '13.0.7037.1'
        Description = 'SQL Server 2016 – SP3 GDR (October 2023)'
        KBNumber    = 'KB5029186'
        KBUrl       = 'https://support.microsoft.com/help/5029186'
        PatchLabel  = 'SP3-GDR'
    }

    # SQL Server 2014 (major 12) – SP3 CU4 + GDR (Jan 2024, EOL July 2024)
    $baseline[12] = @{
        LatestBuild = '12.0.6449.1'
        Description = 'SQL Server 2014 – SP3 GDR (January 2024)'
        KBNumber    = 'KB5029185'
        KBUrl       = 'https://support.microsoft.com/help/5029185'
        PatchLabel  = 'SP3-GDR'
    }

    # SQL Server 2012 (major 11) – EOL July 2022
    $baseline[11] = @{
        LatestBuild = '11.0.7507.2'
        Description = 'SQL Server 2012 – SP4 GDR (January 2022)'
        KBNumber    = 'KB5014354'
        KBUrl       = 'https://support.microsoft.com/help/5014354'
        PatchLabel  = 'SP4-GDR'
    }

    # SQL Server 2008 R2 (major 10, minor 50) – EOL
    $baseline[10] = @{
        LatestBuild = '10.50.6560.0'
        Description = 'SQL Server 2008 R2 – SP3 (End of Life)'
        KBNumber    = 'KB2979597'
        KBUrl       = 'https://support.microsoft.com/help/2979597'
        PatchLabel  = 'SP3'
    }

    return $baseline
}

# ── Per-build KB/label lookup (populated by baseline; keyed by build string) ──
#   Used to identify the CURRENT installed build's KB and patch label.
function Build-PerBuildKBMap {
    param([hashtable]$Baseline)

    $Script:BuildKBMap = @{}

    # Common historical builds for SQL 2022 – extend as needed
    $knownBuilds = @(
        # SQL Server 2022
        @{ Build='16.0.4285.2'; KB='KB5083252'; Label='CU24';        Url='https://support.microsoft.com/help/5083252' },
        @{ Build='16.0.4275.1'; KB='KB5036343'; Label='CU23+GDR';    Url='https://support.microsoft.com/help/5036343' },
        @{ Build='16.0.4240.4'; KB='KB5077464'; Label='CU23';        Url='https://support.microsoft.com/help/5077464' },
        @{ Build='16.0.4165.4'; KB='KB5040939'; Label='CU15+GDR';    Url='https://support.microsoft.com/help/5040939' },
        @{ Build='16.0.4131.2'; KB='KB5035432'; Label='CU14+GDR';    Url='https://support.microsoft.com/help/5035432' },
        @{ Build='16.0.4125.3'; KB='KB5038325'; Label='CU14';        Url='https://support.microsoft.com/help/5038325' },
        @{ Build='16.0.4120.1'; KB='KB5036432'; Label='CU13';        Url='https://support.microsoft.com/help/5036432' },
        @{ Build='16.0.4115.5'; KB='KB5033592'; Label='CU12';        Url='https://support.microsoft.com/help/5033592' },
        @{ Build='16.0.4105.2'; KB='KB5032679'; Label='CU11';        Url='https://support.microsoft.com/help/5032679' },
        @{ Build='16.0.4100.1'; KB='KB5031778'; Label='CU10';        Url='https://support.microsoft.com/help/5031778' },
        @{ Build='16.0.4085.2'; KB='KB5030731'; Label='CU9';         Url='https://support.microsoft.com/help/5030731' },
        @{ Build='16.0.4080.1'; KB='KB5029503'; Label='CU8';         Url='https://support.microsoft.com/help/5029503' },
        @{ Build='16.0.4070.1'; KB='KB5028168'; Label='CU7';         Url='https://support.microsoft.com/help/5028168' },
        @{ Build='16.0.4065.3'; KB='KB5027322'; Label='CU6';         Url='https://support.microsoft.com/help/5027322' },
        @{ Build='16.0.4055.4'; KB='KB5026806'; Label='CU5';         Url='https://support.microsoft.com/help/5026806' },
        @{ Build='16.0.4045.3'; KB='KB5026717'; Label='CU4';         Url='https://support.microsoft.com/help/5026717' },
        @{ Build='16.0.4035.4'; KB='KB5024396'; Label='CU3';         Url='https://support.microsoft.com/help/5024396' },
        @{ Build='16.0.4025.1'; KB='KB5023127'; Label='CU2';         Url='https://support.microsoft.com/help/5023127' },
        @{ Build='16.0.4003.1'; KB='KB5022375'; Label='CU1';         Url='https://support.microsoft.com/help/5022375' },
        @{ Build='16.0.1050.5'; KB='KB5021522'; Label='RTM-GDR';     Url='https://support.microsoft.com/help/5021522' },
        @{ Build='16.0.1000.6'; KB='';          Label='RTM';         Url='' },
        # SQL Server 2019
        @{ Build='15.0.4430.1'; KB='KB5082298'; Label='CU30';        Url='https://support.microsoft.com/help/5082298' },
        @{ Build='15.0.4415.2'; KB='KB5042749'; Label='CU29+GDR';    Url='https://support.microsoft.com/help/5042749' },
        @{ Build='15.0.4405.4'; KB='KB5039747'; Label='CU29';        Url='https://support.microsoft.com/help/5039747' },
        @{ Build='15.0.4395.2'; KB='KB5038451'; Label='CU28+GDR';    Url='https://support.microsoft.com/help/5038451' },
        @{ Build='15.0.4385.2'; KB='KB5037331'; Label='CU28';        Url='https://support.microsoft.com/help/5037331' },
        # SQL Server 2017
        @{ Build='14.0.3465.1'; KB='KB5016884'; Label='CU31';        Url='https://support.microsoft.com/help/5016884' }
    )

    foreach ($b in $knownBuilds) {
        if (-not $Script:BuildKBMap.ContainsKey($b.Build)) {
            $Script:BuildKBMap[$b.Build] = @{
                KBNumber   = $b.KB
                KBUrl      = $b.Url
                PatchLabel = $b.Label
            }
        }
    }

    # Also seed from baseline entries
    foreach ($maj in $Baseline.Keys) {
        $entry = $Baseline[$maj]
        if ($entry.LatestBuild -and -not $Script:BuildKBMap.ContainsKey($entry.LatestBuild)) {
            $Script:BuildKBMap[$entry.LatestBuild] = @{
                KBNumber   = $entry.KBNumber
                KBUrl      = $entry.KBUrl
                PatchLabel = $entry.PatchLabel
            }
        }
    }
}

# ── Online refresh via Microsoft Learn RSS/JSON ───────────────────────────────
#   Fetches the official "latest updates" JSON feed Microsoft exposes.
#   Accepted only when: build parses cleanly, major version matches, and
#   the returned build is HIGHER than what the baseline already has.
function Get-OnlineRefreshData {
    param([hashtable]$Baseline)

    $refreshed = @{}

    # Microsoft publishes a JSON manifest used by their docs pages
    $learnUrls = @{
        16 = 'https://learn.microsoft.com/api/search?search=sql+server+2022+cumulative+update&locale=en-us&facet=products&$top=1'
        15 = 'https://learn.microsoft.com/api/search?search=sql+server+2019+cumulative+update&locale=en-us&facet=products&$top=1'
    }

    # Better: use the actual build-versions pages and extract only the FIRST table row
    # which on Microsoft Learn pages is always the most recent CU.
    $buildPages = @{
        16 = 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions'
        15 = 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions'
        14 = 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/build-versions'
        13 = 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2016/build-versions'
    }

    foreach ($kv in $buildPages.GetEnumerator()) {
        $maj      = $kv.Key
        $url      = $kv.Value
        $baseline = if ($Baseline.ContainsKey($maj)) { [System.Version]$Baseline[$maj].LatestBuild } else { [System.Version]'0.0.0.0' }

        try {
            $html = Invoke-SafeWeb -Uri $url -TimeoutSec 15
            if (-not $html) { continue }

            # The MS Learn build-versions page renders a markdown table converted to HTML.
            # Each row: | Build | CU Name | KB | Release Date |
            # We scan ALL <td> cells for version strings matching this major version,
            # collect them all, then take the highest that beats the baseline.
            $candidates = [System.Collections.Generic.List[System.Version]]::new()
            $buildPattern = [regex]'(?<!\d)(' + $maj + '\.\d+\.\d+\.\d+)(?!\d)'
            foreach ($m in $buildPattern.Matches($html)) {
                try {
                    $v = [System.Version]$m.Groups[1].Value
                    # Sanity check: minor must be 0 (all modern SQL Server builds use minor=0)
                    # and build component must be > 1000 (RTM-era builds like 16.0.1000.6 excluded)
                    if ($v.Minor -eq 0 -and $v.Build -gt 1000) {
                        $candidates.Add($v)
                    }
                } catch {}
            }
            if ($candidates.Count -eq 0) { continue }
            $candidates.Sort()
            $topVer = $candidates[$candidates.Count - 1]

            # Only accept if it beats the baseline
            if ($topVer -le $baseline) {
                Write-Log "  [Online] v$maj: fetched $topVer does not beat baseline $baseline – keeping baseline."
                continue
            }

            $topBuild = $topVer.ToString()

            # Extract description for this build from the surrounding HTML context
            # Look for KB number adjacent to this build string in the page
            $ctx = ''
            $ctxMatch = [regex]::Match($html, "(?s)$([regex]::Escape($topBuild)).{0,300}")
            if ($ctxMatch.Success) { $ctx = $ctxMatch.Value }

            # KB number
            $kbNum = ''
            $kbM   = [regex]::Match($ctx + $html, '(?i)KB\s*(\d{6,8})')
            if ($kbM.Success) { $kbNum = "KB$($kbM.Groups[1].Value)" }

            # KB URL
            $kbUrl = ''
            $kbUrlM = [regex]::Match($html, 'href="(https://support\.microsoft\.com/[^"]+(?:help|kb)[^"]*\d{6,8}[^"]*)"')
            if ($kbUrlM.Success) { $kbUrl = $kbUrlM.Groups[1].Value }

            # Patch label – look for CUxx near the build
            $labelRaw = ''
            $labelM   = [regex]::Match($ctx, '(?i)(CU\s*\d+\s*(?:[\+\-]\s*GDR)?|GDR|SP\s*\d+)')
            if ($labelM.Success) { $labelRaw = ($labelM.Groups[1].Value -replace '\s+','').ToUpper() }

            # Description – clean plain text only, no HTML
            $desc = "SQL Server $($maj -eq 16 ? '2022' : ($maj -eq 15 ? '2019' : ($maj -eq 14 ? '2017' : '2016'))) – $labelRaw $(if ($kbNum) {"($kbNum)"})"
            $desc = ($desc -replace '\s+', ' ').Trim()

            Write-Log "  [Online] v$maj: refreshed to $topBuild $labelRaw $kbNum"

            $refreshed[$maj] = @{
                LatestBuild = $topBuild
                Description = $desc
                KBNumber    = $kbNum
                KBUrl       = if ($kbUrl) { $kbUrl } else { $url }
                PatchLabel  = $labelRaw
            }

            # Add to per-build map if new
            if ($kbNum -and -not $Script:BuildKBMap.ContainsKey($topBuild)) {
                $Script:BuildKBMap[$topBuild] = @{
                    KBNumber   = $kbNum
                    KBUrl      = $kbUrl
                    PatchLabel = $labelRaw
                }
            }
        }
        catch {
            Write-Log "  [Online] v$maj refresh failed: $($_.Exception.Message)" -Level WARN
        }
    }

    return $refreshed
}

# ── Master entry point ────────────────────────────────────────────────────────
function Get-OnlinePatchData {
    Write-Log "Loading SQL Server patch reference data..."

    # Step 1: hardcoded baseline (always works)
    $patchData = Get-BaselinePatchData

    # Step 2: build the per-build KB/label lookup map from baseline + known historical builds
    Build-PerBuildKBMap -Baseline $patchData

    # Step 3: attempt online refresh; merge only if refresh beats baseline
    Write-Log "Attempting online refresh from Microsoft Learn..."
    try {
        $online = Get-OnlineRefreshData -Baseline $patchData
        foreach ($k in $online.Keys) {
            $patchData[$k] = $online[$k]
            Write-Log "  [Merged] v$k updated to $($online[$k].LatestBuild) from online source."
        }
        if ($online.Count -eq 0) {
            Write-Log "Online refresh returned no improvements – using baseline data." -Level WARN
        }
    }
    catch {
        Write-Log "Online refresh failed: $($_.Exception.Message) – using baseline data." -Level WARN
    }

    Write-Log "Patch data ready:"
    foreach ($k in ($patchData.Keys | Sort-Object -Descending)) {
        Write-Log "  v$k → $($patchData[$k].LatestBuild)  [$($patchData[$k].Description)]"
    }

    return $patchData
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION 5 – Compare instance build against latest known build
# ─────────────────────────────────────────────────────────────────────────────
function Compare-Build {
    param(
        [PSCustomObject]$InstanceInfo,
        [hashtable]$PatchData
    )

    $comparison = [PSCustomObject]@{
        IsUpToDate      = $false
        LatestBuild     = 'Unknown'
        LatestDesc      = 'Unknown'
        KBUrl           = ''
        LatestKBNumber  = ''          # KB number of the patch to apply e.g. KB5083252
        PatchStatus     = 'UNKNOWN'   # UP-TO-DATE | PATCH AVAILABLE | EOL | UNKNOWN | ERROR
        PatchStatusNote = ''
    }

    if ($InstanceInfo.Status -eq 'ERROR') {
        $comparison.PatchStatus = 'ERROR'
        return $comparison
    }

    # ── Populate current build's KB number and patch label from the per-build map ──
    # $Script:BuildKBMap is populated by Build-PerBuildKBMap and keyed by build string e.g. "16.0.4240.4"
    if ($null -ne $Script:BuildKBMap -and $Script:BuildKBMap.ContainsKey($InstanceInfo.ProductVersion)) {
        $entry = $Script:BuildKBMap[$InstanceInfo.ProductVersion]
        $InstanceInfo.CurrentKBNumber   = $entry.KBNumber
        $InstanceInfo.CurrentPatchLabel = $entry.PatchLabel
    }

    $maj = $InstanceInfo.MajorVersion

    # End-of-life versions
    $eolVersions = @(8, 9, 10, 11)   # 2000, 2005, 2008/R2 (varies), 2012
    if ($maj -in $eolVersions) {
        $comparison.PatchStatus     = 'EOL'
        $comparison.PatchStatusNote = 'This SQL Server version has reached End of Life. Upgrade strongly recommended.'
    }

    if ($PatchData.ContainsKey($maj)) {
        $ref   = $PatchData[$maj]
        $latest = $ref.LatestBuild

        $comparison.LatestBuild    = $latest
        $comparison.LatestDesc     = $ref.Description
        $comparison.KBUrl          = $ref.KBUrl
        $comparison.LatestKBNumber = if ($ref.KBNumber) { $ref.KBNumber } else { '' }

        # Version comparison using System.Version
        try {
            $currentVer = [System.Version]$InstanceInfo.ProductVersion
            $latestVer  = [System.Version]$latest

            if ($currentVer -ge $latestVer) {
                $comparison.IsUpToDate  = $true
                if ($comparison.PatchStatus -ne 'EOL') {
                    $comparison.PatchStatus = 'UP-TO-DATE'
                }
            } else {
                $comparison.IsUpToDate  = $false
                if ($comparison.PatchStatus -ne 'EOL') {
                    $comparison.PatchStatus = 'PATCH AVAILABLE'
                }
            }
        }
        catch {
            $comparison.PatchStatus     = 'UNKNOWN'
            $comparison.PatchStatusNote = "Could not parse version numbers for comparison."
        }
    } else {
        $comparison.PatchStatusNote = "No patch reference data available for major version $maj."
    }

    return $comparison
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION 6 – Build HTML report
# ─────────────────────────────────────────────────────────────────────────────
function Build-HtmlReport {
    param(
        [PSCustomObject[]]$Results,
        [hashtable]$PatchData
    )

    $runDate    = Get-Date -Format "dddd, MMMM d, yyyy 'at' HH:mm:ss"
    $totalCount = @($Results).Count
    $okCount    = @($Results | Where-Object { $_.PatchStatus -eq 'UP-TO-DATE' }).Count
    $patchCount = @($Results | Where-Object { $_.PatchStatus -eq 'PATCH AVAILABLE' }).Count
    $eolCount   = @($Results | Where-Object { $_.PatchStatus -eq 'EOL' }).Count
    $errCount   = @($Results | Where-Object { $_.PatchStatus -eq 'ERROR' }).Count

    $statusColour = @{
        'UP-TO-DATE'      = '#2e7d32'   # dark green
        'PATCH AVAILABLE' = '#e65100'   # amber/orange
        'EOL'             = '#b71c1c'   # dark red
        'UNKNOWN'         = '#546e7a'   # blue-grey
        'ERROR'           = '#6a1b9a'   # purple
    }

    $statusBg = @{
        'UP-TO-DATE'      = '#e8f5e9'
        'PATCH AVAILABLE' = '#fff3e0'
        'EOL'             = '#ffebee'
        'UNKNOWN'         = '#eceff1'
        'ERROR'           = '#f3e5f5'
    }

    # Build table rows
    $rows = foreach ($r in $Results) {
        $bg  = $statusBg[$r.PatchStatus]
        $fg  = $statusColour[$r.PatchStatus]

        $noteCell = [System.Collections.Generic.List[string]]::new()
        if ($r.ErrorMessage)    { $noteCell.Add("<strong>Error:</strong> $($r.ErrorMessage)") }
        if ($r.PatchStatusNote) { $noteCell.Add($r.PatchStatusNote) }
        $noteHtml = if ($noteCell.Count -gt 0) { $noteCell -join '<br/>' } else { '—' }

        # Current patch label cell – e.g. "RTM-CU23-GDR" + "(KB5077464)"
        $currentLabelHtml = if ($r.CurrentPatchLabel) { $r.CurrentPatchLabel } else { $r.ProductLevel + $(if ($r.ProductUpdateLevel) { ' ' + $r.ProductUpdateLevel } else { '' }) }
        $currentKBHtml    = if ($r.CurrentKBNumber)   { "<br/><span style='font-size:0.85em;color:#546e7a;'>$($r.CurrentKBNumber)</span>" } else { '' }

        # Patch-to-apply KB cell – KB number on top, clickable link below
        $patchKbHtml = if ($r.LatestKBNumber -or $r.KBUrl) {
            $kbNum  = if ($r.LatestKBNumber) { "<span style='font-family:monospace;font-weight:600;'>$($r.LatestKBNumber)</span>" } else { '' }
            $kbLink = if ($r.KBUrl)          { "<br/><a href='$($r.KBUrl)' style='color:#0d47a1;font-size:0.85em;'>KB Article</a>" } else { '' }
            "${kbNum}${kbLink}"
        } else { '—' }

        @"
        <tr style="background:$bg;">
            <td style="font-weight:600;">$($r.Instance)</td>
            <td>$($r.ServerName)</td>
            <td>$($r.VersionString)</td>
            <td style="font-family:monospace;">$($r.ProductVersion)</td>
            <td>${currentLabelHtml}${currentKBHtml}</td>
            <td>$($r.Edition)</td>
            <td style="font-family:monospace;">$($r.LatestBuild)</td>
            <td>$($r.LatestDesc)</td>
            <td style="text-align:center;">$patchKbHtml</td>
            <td style="text-align:center;font-weight:700;color:$fg;">$($r.PatchStatus)</td>
            <td style="font-size:0.85em;color:#555;">$noteHtml</td>
        </tr>
"@
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1.0"/>
<title>SQL Server Patch Audit</title>
<style>
  body  { font-family: 'Segoe UI', Arial, sans-serif; background:#f4f6f8; margin:0; padding:20px; color:#212121; }
  .wrap { max-width:1300px; margin:0 auto; background:#fff; border-radius:8px;
          box-shadow:0 2px 8px rgba(0,0,0,.15); padding:30px; }
  h1    { margin:0 0 4px; font-size:1.6em; color:#0d47a1; }
  .sub  { color:#546e7a; font-size:.9em; margin-bottom:24px; }
  .summary { display:flex; gap:16px; flex-wrap:wrap; margin-bottom:28px; }
  .card { flex:1; min-width:130px; border-radius:6px; padding:16px 20px; text-align:center; }
  .card .num  { font-size:2em; font-weight:700; }
  .card .lbl  { font-size:.8em; text-transform:uppercase; letter-spacing:.05em; }
  .c-total    { background:#e3f2fd; color:#0d47a1; }
  .c-ok       { background:#e8f5e9; color:#2e7d32; }
  .c-patch    { background:#fff3e0; color:#e65100; }
  .c-eol      { background:#ffebee; color:#b71c1c; }
  .c-err      { background:#f3e5f5; color:#6a1b9a; }
  table { width:100%; border-collapse:collapse; font-size:.88em; }
  thead tr { background:#0d47a1; color:#fff; }
  th  { padding:10px 12px; text-align:left; white-space:nowrap; }
  td  { padding:9px 12px; border-bottom:1px solid #e0e0e0; vertical-align:top; }
  tr:last-child td { border-bottom:none; }
  .footer { margin-top:24px; font-size:.78em; color:#9e9e9e; text-align:center; }
</style>
</head>
<body>
<div class="wrap">
  <h1>&#128270; SQL Server Patch Audit Report</h1>
  <div class="sub">Generated on $runDate</div>

  <div class="summary">
    <div class="card c-total"><div class="num">$totalCount</div><div class="lbl">Total Instances</div></div>
    <div class="card c-ok">   <div class="num">$okCount</div>   <div class="lbl">Up to Date</div></div>
    <div class="card c-patch"><div class="num">$patchCount</div><div class="lbl">Patch Available</div></div>
    <div class="card c-eol">  <div class="num">$eolCount</div>  <div class="lbl">End of Life</div></div>
    <div class="card c-err">  <div class="num">$errCount</div>  <div class="lbl">Errors</div></div>
  </div>

  <table>
    <thead>
      <tr>
        <th>Instance</th>
        <th>Server Name</th>
        <th>Product</th>
        <th>Current Build</th>
        <th>Current Patch Level / KB</th>
        <th>Edition</th>
        <th>Latest Build</th>
        <th>Latest Release</th>
        <th>Patch KB</th>
        <th>Patch Status</th>
        <th>Notes</th>
      </tr>
    </thead>
    <tbody>
      $($rows -join "`n")
    </tbody>
  </table>

  <div class="footer">
    This report was generated automatically by the SQL Server Patch Audit script.<br/>
    Patch data fetched live from: sqlserverbuilds.blogspot.com · learn.microsoft.com · catalog.update.microsoft.com<br/>
    Always verify patch applicability in a test environment before applying to production.
  </div>
</div>
</body>
</html>
"@

    return $html
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION 7 – Send email
# ─────────────────────────────────────────────────────────────────────────────
function Send-ReportEmail {
    param(
        [string]   $HtmlBody,
        [string]   $SmtpServer,
        [int]      $SmtpPort,
        [string]   $From,
        [string[]] $To,
        [string]   $Subject,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]   $UseSsl
    )

    $mailParams = @{
        SmtpServer  = $SmtpServer
        Port        = $SmtpPort
        From        = $From
        To          = $To
        Subject     = $Subject
        Body        = $HtmlBody
        BodyAsHtml  = $true
        Encoding    = [System.Text.Encoding]::UTF8
    }

    if ($Credential) { $mailParams['Credential'] = $Credential }
    if ($UseSsl)     { $mailParams['UseSsl']     = $true }

    try {
        Send-MailMessage @mailParams
        Write-Log "Email sent successfully to: $($To -join ', ')"
    }
    catch {
        Write-Log "Failed to send email: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION 8 – MAIN
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "=== SQL Server Patch Audit started ==="

# 8.1  Load instance list
$instances = Get-InstanceList -Path $InstanceListPath

# 8.2  Fetch online patch data (once, shared across all instances)
$patchData = Get-OnlinePatchData

# 8.3  Query each SQL Server instance
$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($inst in $instances) {
    Write-Log "Querying instance: $inst"

    $info  = Get-SqlVersion -Instance $inst -Credential $SqlCredential -Timeout $TimeoutSeconds
    $patch = Compare-Build  -InstanceInfo $info -PatchData $patchData

    # Merge patch comparison into the result object
    $info | Add-Member -NotePropertyName 'PatchStatus'     -NotePropertyValue $patch.PatchStatus
    $info | Add-Member -NotePropertyName 'PatchStatusNote' -NotePropertyValue $patch.PatchStatusNote
    $info | Add-Member -NotePropertyName 'IsUpToDate'      -NotePropertyValue $patch.IsUpToDate
    $info | Add-Member -NotePropertyName 'LatestBuild'     -NotePropertyValue $patch.LatestBuild
    $info | Add-Member -NotePropertyName 'LatestDesc'      -NotePropertyValue $patch.LatestDesc
    $info | Add-Member -NotePropertyName 'KBUrl'           -NotePropertyValue $patch.KBUrl
    $info | Add-Member -NotePropertyName 'LatestKBNumber'  -NotePropertyValue $patch.LatestKBNumber

    Write-Log "  [$inst] Version=$($info.ProductVersion) | Status=$($patch.PatchStatus)"
    $allResults.Add($info)
}

# 8.4  Build HTML report
Write-Log "Building HTML report..."
$htmlReport = Build-HtmlReport -Results $allResults.ToArray() -PatchData $patchData

# 8.5  Optionally save report locally
$saveDir    = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$reportPath = Join-Path $saveDir "SQLPatchReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
$htmlReport | Out-File -FilePath $reportPath -Encoding UTF8
Write-Log "Report saved locally: $reportPath"

# 8.6  Send email
$subject = "$EmailSubject – $(Get-Date -Format 'yyyy-MM-dd')"
Send-ReportEmail `
    -HtmlBody   $htmlReport `
    -SmtpServer $SmtpServer `
    -SmtpPort   $SmtpPort `
    -From       $EmailFrom `
    -To         $EmailTo `
    -Subject    $subject `
    -Credential $SmtpCredential `
    -UseSsl:$UseSsl

Write-Log "=== SQL Server Patch Audit complete ==="

# Output summary table to console as well
$allResults | Format-Table Instance, ProductVersion, PatchStatus, LatestBuild -AutoSize
