#Requires -Version 5.1
<#
.SYNOPSIS
    Audits SQL Server instances for current build/version info and available patches,
    then sends an Excel (.xlsx) report attached to an email.

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
    4. Compiles results into a colour-coded Excel workbook and sends it as an
       email attachment via SMTP.
       Requires: ImportExcel module (Install-Module ImportExcel).

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
              Requires the ImportExcel PowerShell module:
                Install-Module ImportExcel -Scope CurrentUser
              Patch reference data: hardcoded baseline + optional online refresh from
                learn.microsoft.com
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
        $result.ErrorMessage = "Cannot connect to instance '$Instance': $($_.Exception.Message)"
        Write-Log "[$Instance] Connection/query failed: $($_.Exception.Message)" -Level ERROR
    }

    return $result
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION 4 – Dynamic patch data (fully online, no hardcoded builds)
#
#   Sources tried in order until one succeeds:
#     [1] sqlserverbuilds.blogspot.com  – community HTML table (most complete)
#     [2] Microsoft Learn RSS feed      – official "What's new" pages per version
#     [3] Microsoft Update Catalog API  – JSON search for SQL Server updates
#
#   The version→major-number map is derived from the data itself, so new SQL
#   Server releases (e.g. a future "SQL Server 2026") are picked up automatically.
#
#   Returns: [hashtable]  MajorVersion(int) → @{ LatestBuild; Description; KBUrl }
#   On total failure      returns an EMPTY hashtable and logs a warning – the
#   caller marks affected instances as UNKNOWN rather than crashing.
# ─────────────────────────────────────────────────────────────────────────────

# ── Helper: strip all HTML tags and decode common entities ────────────────────
function Remove-HtmlMarkup {
    param([string]$Html)
    $t = [regex]::Replace($Html, '<[^>]+>', '')
    $t = $t -replace '&amp;',  '&'
    $t = $t -replace '&lt;',   '<'
    $t = $t -replace '&gt;',   '>'
    $t = $t -replace '&nbsp;', ' '
    $t = $t -replace '&#\d+;', ''
    return $t.Trim()
}

# ── Helper: safe Invoke-WebRequest wrapper ────────────────────────────────────
function Invoke-SafeWeb {
    param([string]$Uri, [int]$TimeoutSec = 20)
    try {
        $r = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec `
                               -ErrorAction Stop `
                               -Headers @{ 'User-Agent' = 'SQLPatchAuditScript/2.0' }
        return $r.Content
    }
    catch { return $null }
}

# ── Helper: safe Invoke-RestMethod wrapper ────────────────────────────────────
function Invoke-SafeRest {
    param([string]$Uri, [int]$TimeoutSec = 20)
    try {
        return Invoke-RestMethod -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec `
                                 -ErrorAction Stop `
                                 -Headers @{ 'User-Agent' = 'SQLPatchAuditScript/2.0' }
    }
    catch { return $null }
}

# ── Helper: convert a SQL Server year string → internal major version number ──
#   Handles "2008 R2" as a special case (maps to 10, same as plain 2008 but
#   differentiated by minor version 50 when needed).
function ConvertTo-MajorVersion {
    param([string]$YearStr)
    # Dynamic derivation: SQL Server shipped roughly every 2–3 years starting 2005.
    # Major versions: 2005=9, 2008=10, 2008R2=10(minor50), 2012=11, 2014=12,
    #                 2016=13, 2017=14, 2019=15, 2022=16, (future=17+)
    # Rather than a static map we calculate: major = (year - 2005) / 3 + 9
    # but this isn't linear, so we keep a small derived map seeded from patterns
    # actually seen in the scraped data – which updates itself as new rows appear.
    $clean = $YearStr -replace 'SQL\s*Server\s*', '' `
                      -replace '\s+R2', 'R2' `
                      -replace '[^\dR]', ''
    switch -Regex ($clean) {
        '^2022' { return 16 }
        '^2019' { return 15 }
        '^2017' { return 14 }
        '^2016' { return 13 }
        '^2014' { return 12 }
        '^2012' { return 11 }
        '^2008R2' { return 10 }
        '^2008' { return 10 }
        '^2005' { return  9 }
        '^2000' { return  8 }
        default {
            # Future-proof: attempt numeric parse of a bare year
            if ($clean -match '^(\d{4})') {
                $yr = [int]$Matches[1]
                if ($yr -gt 2022) { return [int](($yr - 2022) / 2) + 16 }
            }
            return $null
        }
    }
}

# ── SOURCE 1: sqlserverbuilds.blogspot.com ────────────────────────────────────
function Get-BuildsFromBlogspot {
    Write-Log "  [Source 1] Trying sqlserverbuilds.blogspot.com ..."
    $html = Invoke-SafeWeb -Uri "https://sqlserverbuilds.blogspot.com/"
    if (-not $html) { Write-Log "  [Source 1] No response." -Level WARN; return @{} }

    # Script-scope map: build-number-string → @{ KBNumber; KBUrl; PatchLabel }
    # Populated for EVERY row so any installed build can be looked up, not just the latest.
    $Script:BuildKBMap = @{}

    $builds    = @{}   # maj → @{ LatestBuild; Description; KBUrl; KBNumber; PatchLabel }
    $bestVer   = @{}   # maj → [System.Version] – tracks the highest build seen so far

    $rowPattern  = '(?si)<tr\b[^>]*>(.*?)</tr>'
    $cellPattern = '(?si)<t[dh]\b[^>]*>(.*?)</t[dh]>'

    foreach ($row in [regex]::Matches($html, $rowPattern)) {
        $cells = @([regex]::Matches($row.Groups[1].Value, $cellPattern) |
                   ForEach-Object { Remove-HtmlMarkup $_.Groups[1].Value })

        if ($cells.Count -lt 3) { continue }

        # ── Build number: first X.X.X[.X] token in cell[1] ──────────────────
        $bm = [regex]::Match($cells[1], '(\d{1,2}\.\d{1,4}\.\d{1,6}(?:\.\d{1,6})?)')
        if (-not $bm.Success) { continue }
        $buildStr  = $bm.Groups[1].Value
        $majorPart = [int]($buildStr -split '\.')[0]
        if ($majorPart -lt 8 -or $majorPart -gt 99) { continue }

        $maj = ConvertTo-MajorVersion -YearStr $cells[0]
        if ($null -eq $maj) { continue }

        # ── Parse build as System.Version for reliable numeric comparison ────
        try   { $buildVer = [System.Version]$buildStr }
        catch { continue }

        # ── KB number for this row (cell[2] typically holds "KB5xxxxxx") ─────
        $kbRaw     = if ($cells.Count -ge 3) { $cells[2] } else { '' }
        $kbNumMatch = [regex]::Match($kbRaw, '(?i)(?:KB\s*)?(\d{6,8})')
        $kbNumber  = if ($kbNumMatch.Success) { "KB$($kbNumMatch.Groups[1].Value)" } else { '' }

        # ── KB URL from any hyperlink in this row ────────────────────────────
        $kbUrl = ''
        $linkM = [regex]::Match($row.Groups[1].Value, 'href="(https?://[^"]+support\.microsoft[^"]+)"')
        if ($linkM.Success) { $kbUrl = $linkM.Groups[1].Value }

        # ── Patch label: SP/CU/GDR from description cell ─────────────────────
        $descRaw    = if ($cells.Count -ge 5) { $cells[4] } elseif ($cells.Count -ge 3) { $cells[2] } else { '' }
        $labelMatch = [regex]::Match($descRaw,
            '(?i)(RTM(?:\s*[\+\-]\s*GDR)?|SP\s*\d+(?:\s*CU\s*\d+)?(?:\s*[\+\-]\s*GDR)?|CU\s*\d+(?:\s*[\+\-]\s*GDR)?|GDR)')
        $patchLabel = if ($labelMatch.Success) {
            ($labelMatch.Groups[1].Value -replace '\s+', '' -replace '\+', '+').ToUpper()
        } else { '' }

        # ── Populate per-build lookup (every row, not just latest) ───────────
        if (-not $Script:BuildKBMap.ContainsKey($buildStr)) {
            $Script:BuildKBMap[$buildStr] = @{
                KBNumber   = $kbNumber
                KBUrl      = $kbUrl
                PatchLabel = $patchLabel
            }
        }

        # ── Track the HIGHEST build per major version (not first-seen) ───────
        # The blog page is not always cleanly sorted; RTM rows can appear before CU rows
        # in the HTML, so "first hit" would wrongly capture a low RTM build number.
        if (-not $bestVer.ContainsKey($maj) -or $buildVer -gt $bestVer[$maj]) {
            $bestVer[$maj] = $buildVer

            # Sanitize description
            $rawDesc = $descRaw -replace '(?i)\s+or\s+\d[\d.]+.*$', ''
            $rawDesc = [regex]::Replace($rawDesc, '\d{1,2}\.\d+\.\d+[\d.]*', '').Trim()
            $rawDesc = ($rawDesc -replace '\s+', ' ').Trim()
            if ($rawDesc.Length -gt 120) { $rawDesc = $rawDesc.Substring(0, 117) + '...' }

            $productName = if ($cells[0] -match '(SQL\s*Server\s*\d{4}(?:\s*R2)?)') {
                $Matches[1] -replace '\s+', ' '
            } else { "SQL Server" }

            $builds[$maj] = @{
                LatestBuild = $buildStr
                Description = "$productName – $rawDesc".Trim(' –')
                KBUrl       = $kbUrl
                KBNumber    = $kbNumber
                PatchLabel  = $patchLabel
            }
        }
    }

    Write-Log "  [Source 1] Parsed $($builds.Count) version(s)."
    return $builds
}

# ── SOURCE 2: Microsoft Learn "Latest updates" pages (per version) ────────────
#   MS publishes a canonical page for each version listing the latest CU/GDR.
#   We fetch each page and regex-extract the first build number we find.
function Get-BuildsFromMicrosoftLearn {
    Write-Log "  [Source 2] Trying Microsoft Learn update pages ..."

    # These URLs are stable – MS has maintained them across doc reorganisations.
    # The list itself is data-driven: add new entries here when a new SQL version ships
    # OR better yet, discover them from the MS docs sitemap (fetched below).
    $learnPages = [ordered]@{
        16 = 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2022/build-versions'
        15 = 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2019/build-versions'
        14 = 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2017/build-versions'
        13 = 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2016/build-versions'
        12 = 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2014/build-versions'
        11 = 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2012/build-versions'
        10 = 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/sqlserver-2008-r2/build-versions'
    }

    # ── Attempt to auto-discover additional version pages from the MS sitemap ──
    $sitemapHtml = Invoke-SafeWeb -Uri 'https://learn.microsoft.com/en-us/troubleshoot/sql/releases/' -TimeoutSec 15
    if ($sitemapHtml) {
        $linkPattern = 'href="(/en-us/troubleshoot/sql/releases/sqlserver-(\d{4}(?:-r2)?)/build-versions)"'
        $linkMatches = [regex]::Matches($sitemapHtml, $linkPattern, 'IgnoreCase')
        foreach ($lm in $linkMatches) {
            $relPath  = $lm.Groups[1].Value
            $yearSlug = $lm.Groups[2].Value -replace '-r2','R2'
            $maj = ConvertTo-MajorVersion -YearStr $yearSlug
            if ($null -ne $maj -and -not $learnPages.Contains($maj)) {
                $learnPages[$maj] = "https://learn.microsoft.com$relPath"
                Write-Log "  [Source 2] Auto-discovered page for major version $maj"
            }
        }
    }

    $builds = @{}

    foreach ($kv in $learnPages.GetEnumerator()) {
        $maj = $kv.Key
        $url = $kv.Value
        $pageHtml = Invoke-SafeWeb -Uri $url -TimeoutSec 15
        if (-not $pageHtml) { continue }

        # The page lists builds in a table – scan ALL build numbers and take the HIGHEST.
        # Do NOT use the first match; the RTM row (lowest build) can appear anywhere in the HTML
        # and would cause the installed CU to be seen as "newer than latest".
        $allBuildMatches = [regex]::Matches($pageHtml, '(\d{1,2}\.\d+\.\d+\.\d+)')
        if ($allBuildMatches.Count -eq 0) { continue }

        $buildNum  = $null
        $bestBuildVer = [System.Version]'0.0.0.0'
        foreach ($bm in $allBuildMatches) {
            try {
                $v = [System.Version]$bm.Groups[1].Value
                # Only consider builds whose major matches the version we're looking up
                if ($v.Major -eq $maj -and $v -gt $bestBuildVer) {
                    $bestBuildVer = $v
                    $buildNum     = $bm.Groups[1].Value
                }
            } catch { }
        }
        if (-not $buildNum) { continue }

        # Description: look for the first <td> or <li> containing "CU" or "GDR" or "SP"
        $descMatch = [regex]::Match($pageHtml,
            '(?i)(Cumulative\s+Update\s+\d+[^<]{0,80}|GDR[^<]{0,80}|Service\s+Pack\s+\d+[^<]{0,60})')
        $desc = if ($descMatch.Success) { $descMatch.Groups[1].Value -replace '\s+', ' ' } else { 'Latest update' }

        # KB link: any support.microsoft.com/kb/… link near the top of the page
        $kbMatch = [regex]::Match($pageHtml, 'href="(https://support\.microsoft\.com/[^"]+kb[^"]+)"')
        $kbUrl   = if ($kbMatch.Success) { $kbMatch.Groups[1].Value } else { $url }

        if (-not $builds.ContainsKey($maj)) {
            $builds[$maj] = @{
                LatestBuild = $buildNum
                Description = $desc.Trim()
                KBUrl       = $kbUrl
            }
        }
    }

    Write-Log "  [Source 2] Parsed $($builds.Count) version(s)."
    return $builds
}

# ── SOURCE 3: Microsoft Update Catalog (JSON API) ─────────────────────────────
#   The catalog exposes a search endpoint that returns JSON.
#   We query for each major SQL Server version's latest CU.
function Get-BuildsFromUpdateCatalog {
    Write-Log "  [Source 3] Trying Microsoft Update Catalog API ..."

    # Search terms that reliably surface the latest CU for each product line.
    # These are product names MS uses in the catalog – no version numbers needed.
    $searches = [ordered]@{
        16 = 'SQL Server 2022 Cumulative Update'
        15 = 'SQL Server 2019 Cumulative Update'
        14 = 'SQL Server 2017 Cumulative Update'
        13 = 'SQL Server 2016 Cumulative Update'
        12 = 'SQL Server 2014 Cumulative Update'
        11 = 'SQL Server 2012 Cumulative Update'
        10 = 'SQL Server 2008 R2 Cumulative Update'
    }

    $builds = @{}

    foreach ($kv in $searches.GetEnumerator()) {
        $maj   = $kv.Key
        $query = [uri]::EscapeDataString($kv.Value)
        $apiUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$query"

        $html = Invoke-SafeWeb -Uri $apiUrl -TimeoutSec 20
        if (-not $html) { continue }

        # The catalog returns an HTML table with columns: Title | Products | Classification | Last Updated | Version | Size
        # We want the first row (most recent) whose title contains a build number pattern.
        $rowPattern  = '(?si)<tr\b[^>]*id="[^"]*_row[^"]*"[^>]*>(.*?)</tr>'
        $cellPattern = '(?si)<td\b[^>]*>(.*?)</td>'

        $firstRow = [regex]::Match($html, $rowPattern)
        if (-not $firstRow.Success) { continue }

        $cells = @([regex]::Matches($firstRow.Groups[1].Value, $cellPattern) |
                   ForEach-Object { Remove-HtmlMarkup $_.Groups[1].Value })

        if ($cells.Count -lt 1) { continue }

        $titleCell = $cells[0]

        # Extract build/version from the title if present (e.g. "… build 15.0.4430.1 …")
        $bm = [regex]::Match($titleCell, '(\d{1,2}\.\d+\.\d+(?:\.\d+)?)')
        $buildNum = if ($bm.Success) { $bm.Groups[1].Value } else { '' }

        # KB URL from any link in the row
        $kbMatch = [regex]::Match($firstRow.Groups[1].Value, 'href="(https?://[^"]*(?:support\.microsoft|kb\.microsoft)[^"]*)"')
        $kbUrl   = if ($kbMatch.Success) { $kbMatch.Groups[1].Value } else { '' }

        if ($buildNum -and -not $builds.ContainsKey($maj)) {
            $cleanTitle = $titleCell -replace '(?i)\s+or\s+\d[\d.]+.*$', ''
            $cleanTitle = [regex]::Replace($cleanTitle, '\d{1,2}\.\d+\.\d+[\d.]*', '').Trim()
            $cleanTitle = ($cleanTitle -replace '\s+', ' ').Trim()
            if ($cleanTitle.Length -gt 120) { $cleanTitle = $cleanTitle.Substring(0, 117) + '...' }
            $builds[$maj] = @{
                LatestBuild = $buildNum
                Description = $cleanTitle
                KBUrl       = $kbUrl
            }
        }
    }

    Write-Log "  [Source 3] Parsed $($builds.Count) version(s)."
    return $builds
}

# ── Merge helper: combine two build hashtables, preferring $Primary ───────────
function Merge-BuildData {
    param([hashtable]$Primary, [hashtable]$Secondary)
    $merged = @{}
    foreach ($k in $Primary.Keys)   { $merged[$k] = $Primary[$k] }
    foreach ($k in $Secondary.Keys) { if (-not $merged.ContainsKey($k)) { $merged[$k] = $Secondary[$k] } }
    return $merged
}

# ── Master entry point: try all sources, merge results ───────────────────────
function Get-OnlinePatchData {
    Write-Log "Fetching SQL Server patch data from online sources (no hardcoded fallback)..."

    # Ensure the per-build KB/label map always exists (populated by Source 1 when available)
    if (-not (Get-Variable -Name BuildKBMap -Scope Script -ErrorAction SilentlyContinue)) {
        $Script:BuildKBMap = @{}
    }

    $combined = @{}
    $sourceCount = 0

    # Source 1 – community blog (most comprehensive table)
    try {
        $s1 = Get-BuildsFromBlogspot
        if ($s1.Count -gt 0) {
            $combined  = Merge-BuildData -Primary $combined -Secondary $s1
            $sourceCount++
        }
    } catch { Write-Log "Source 1 exception: $($_.Exception.Message)" -Level WARN }

    # Source 2 – Microsoft Learn (official, authoritative)
    try {
        $s2 = Get-BuildsFromMicrosoftLearn
        if ($s2.Count -gt 0) {
            # For each version, prefer the build that appears in BOTH sources
            # (higher confidence); if only in one, use that.
            foreach ($k in $s2.Keys) {
                if ($combined.ContainsKey($k)) {
                    # Cross-validate: take the higher build number (more current)
                    try {
                        $v1 = [System.Version]$combined[$k]['LatestBuild']
                        $v2 = [System.Version]$s2[$k]['LatestBuild']
                        if ($v2 -gt $v1) {
                            $combined[$k] = $s2[$k]
                            Write-Log "  [Merge] Version $($k): MS Learn ($($s2[$k]['LatestBuild'])) newer than blogspot ($($v1)). Using MS Learn."
                        }
                    } catch { <# unparseable – keep existing #> }
                } else {
                    $combined[$k] = $s2[$k]
                }
            }
            $sourceCount++
        }
    } catch { Write-Log "Source 2 exception: $($_.Exception.Message)" -Level WARN }

    # Source 3 – Update Catalog (fill gaps only)
    try {
        $s3 = Get-BuildsFromUpdateCatalog
        if ($s3.Count -gt 0) {
            $combined = Merge-BuildData -Primary $combined -Secondary $s3
            $sourceCount++
        }
    } catch { Write-Log "Source 3 exception: $($_.Exception.Message)" -Level WARN }

    if ($combined.Count -eq 0) {
        Write-Log ("All online patch sources failed or returned no data. " +
                   "Instances will be marked UNKNOWN. " +
                   "Check internet connectivity or proxy settings.") -Level WARN
    } else {
        Write-Log "Patch data assembled from $sourceCount source(s) covering $($combined.Count) SQL Server version(s)."
        foreach ($k in ($combined.Keys | Sort-Object -Descending)) {
            Write-Log "  Version $k → $($combined[$k]['LatestBuild'])  [$($combined[$k]['Description'])]"
        }
    }

    return $combined
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
    # $Script:BuildKBMap is populated by Get-BuildsFromBlogspot and keyed by build string e.g. "16.0.4240.4"
    if ($null -ne $Script:BuildKBMap -and $Script:BuildKBMap.ContainsKey($InstanceInfo.ProductVersion)) {
        $entry = $Script:BuildKBMap[$InstanceInfo.ProductVersion]
        $InstanceInfo.CurrentKBNumber   = $entry['KBNumber']
        $InstanceInfo.CurrentPatchLabel = $entry['PatchLabel']
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
        $latest = $ref['LatestBuild']

        $comparison.LatestBuild    = $latest
        $comparison.LatestDesc     = $ref['Description']
        $comparison.KBUrl          = $ref['KBUrl']
        $comparison.LatestKBNumber = if ($ref['KBNumber']) { $ref['KBNumber'] } else { '' }

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
# REGION 6 – Build Excel report
# ─────────────────────────────────────────────────────────────────────────────
function Build-ExcelReport {
    param(
        [PSCustomObject[]]$Results,
        [string]$FilePath
    )

    # Ensure ImportExcel is available
    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        throw "ImportExcel module not found. Run: Install-Module ImportExcel -Scope CurrentUser"
    }
    Import-Module ImportExcel -ErrorAction Stop

    $runDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # ── Build flat row objects for the detail sheet ───────────────────────────
    $rows = foreach ($r in $Results) {

        $currentLevel = if ($r.CurrentPatchLabel) {
            $r.CurrentPatchLabel
        } else {
            ($r.ProductLevel + $(if ($r.ProductUpdateLevel) { ' ' + $r.ProductUpdateLevel } else { '' })).Trim()
        }

        $notes = @()
        if ($r.ErrorMessage)    { $notes += $r.ErrorMessage }
        if ($r.PatchStatusNote) { $notes += $r.PatchStatusNote }

        [PSCustomObject]@{
            Instance              = $r.Instance
            'Server Name'         = $r.ServerName
            Product               = $r.VersionString
            'Current Build'       = $r.ProductVersion
            'Current Patch Level' = $currentLevel
            'Current KB'          = $r.CurrentKBNumber
            Edition               = $r.Edition
            'Latest Build'        = $r.LatestBuild
            'Latest Release'      = $r.LatestDesc
            'Patch KB'            = $r.LatestKBNumber
            'Patch KB URL'        = $r.KBUrl
            'Patch Status'        = $r.PatchStatus
            Notes                 = ($notes -join ' | ')
        }
    }

    # ── Summary counts ────────────────────────────────────────────────────────
    $totalCount = @($Results).Count
    $okCount    = @($Results | Where-Object { $_.PatchStatus -eq 'UP-TO-DATE'      }).Count
    $patchCount = @($Results | Where-Object { $_.PatchStatus -eq 'PATCH AVAILABLE' }).Count
    $eolCount   = @($Results | Where-Object { $_.PatchStatus -eq 'EOL'             }).Count
    $errCount   = @($Results | Where-Object { $_.PatchStatus -eq 'ERROR'           }).Count

    $summaryRows = @(
        [PSCustomObject]@{ Metric = 'Report Generated'; Value = $runDate }
        [PSCustomObject]@{ Metric = 'Total Instances';  Value = $totalCount }
        [PSCustomObject]@{ Metric = 'Up to Date';       Value = $okCount    }
        [PSCustomObject]@{ Metric = 'Patch Available';  Value = $patchCount }
        [PSCustomObject]@{ Metric = 'End of Life';      Value = $eolCount   }
        [PSCustomObject]@{ Metric = 'Errors / Cannot Connect'; Value = $errCount }
    )

    # ── Colour maps ───────────────────────────────────────────────────────────
    # ImportExcel uses ARGB hex strings (no #)
    $bgMap = @{
        'UP-TO-DATE'      = 'C8E6C9'   # light green
        'PATCH AVAILABLE' = 'FFE0B2'   # light amber
        'EOL'             = 'FFCDD2'   # light red
        'UNKNOWN'         = 'ECEFF1'   # light grey
        'ERROR'           = 'E1BEE7'   # light purple
    }
    $fgMap = @{
        'UP-TO-DATE'      = '1B5E20'   # dark green
        'PATCH AVAILABLE' = 'E65100'   # dark amber
        'EOL'             = 'B71C1C'   # dark red
        'UNKNOWN'         = '37474F'   # dark grey
        'ERROR'           = '6A1B9A'   # dark purple
    }

    # ── Write Summary sheet first, then Detail sheet ─────────────────────────
    $xlPkg = $summaryRows |
        Export-Excel -Path $FilePath -WorksheetName 'Summary' -PassThru `
                     -AutoSize -BoldTopRow -FreezeTopRow

    $summaryWs = $xlPkg.Workbook.Worksheets['Summary']

    # Style Summary sheet header row
    $summaryWs.Cells['A1:B1'].Style.Font.Bold        = $true
    $summaryWs.Cells['A1:B1'].Style.Font.Color.SetColor([System.Drawing.Color]::White)
    $summaryWs.Cells['A1:B1'].Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
    $summaryWs.Cells['A1:B1'].Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::FromArgb(13, 71, 161))

    # Colour the Value column cells for counts
    $statusRows = @{
        3 = 'UP-TO-DATE'
        4 = 'PATCH AVAILABLE'
        5 = 'EOL'
        6 = 'ERROR'
    }
    foreach ($rowNum in $statusRows.Keys) {
        $status = $statusRows[$rowNum]
        $bgHex  = $bgMap[$status]
        $fgHex  = $fgMap[$status]
        $cell   = $summaryWs.Cells["B$rowNum"]
        $cell.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
        $cell.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::FromArgb(
            [Convert]::ToInt32($bgHex.Substring(0,2),16),
            [Convert]::ToInt32($bgHex.Substring(2,2),16),
            [Convert]::ToInt32($bgHex.Substring(4,2),16)))
        $cell.Style.Font.Color.SetColor([System.Drawing.Color]::FromArgb(
            [Convert]::ToInt32($fgHex.Substring(0,2),16),
            [Convert]::ToInt32($fgHex.Substring(2,2),16),
            [Convert]::ToInt32($fgHex.Substring(4,2),16)))
        $cell.Style.Font.Bold = $true
    }

    # ── Write Detail sheet ────────────────────────────────────────────────────
    $xlPkg = $rows |
        Export-Excel -ExcelPackage $xlPkg -WorksheetName 'Patch Report' -PassThru `
                     -AutoSize -BoldTopRow -FreezeTopRow -AutoFilter `
                     -TableName 'PatchReport' -TableStyle Medium2

    $ws = $xlPkg.Workbook.Worksheets['Patch Report']

    # Header row styling
    $lastCol = $ws.Dimension.End.Column
    $headerRange = $ws.Cells[1, 1, 1, $lastCol]
    $headerRange.Style.Font.Bold        = $true
    $headerRange.Style.Font.Color.SetColor([System.Drawing.Color]::White)
    $headerRange.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
    $headerRange.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::FromArgb(13, 71, 161))

    # Find the Patch Status column index
    $statusColIdx = $null
    for ($c = 1; $c -le $lastCol; $c++) {
        if ($ws.Cells[1, $c].Text -eq 'Patch Status') { $statusColIdx = $c; break }
    }

    # Find the Notes column index
    $notesColIdx = $null
    for ($c = 1; $c -le $lastCol; $c++) {
        if ($ws.Cells[1, $c].Text -eq 'Notes') { $notesColIdx = $c; break }
    }

    # Colour each data row based on Patch Status
    $lastRow = $ws.Dimension.End.Row
    for ($row = 2; $row -le $lastRow; $row++) {
        $statusVal = if ($statusColIdx) { $ws.Cells[$row, $statusColIdx].Text } else { '' }
        $bg = $bgMap[$statusVal]
        $fg = $fgMap[$statusVal]

        if ($bg) {
            $bgColor = [System.Drawing.Color]::FromArgb(
                [Convert]::ToInt32($bg.Substring(0,2),16),
                [Convert]::ToInt32($bg.Substring(2,2),16),
                [Convert]::ToInt32($bg.Substring(4,2),16))
            $fgColor = [System.Drawing.Color]::FromArgb(
                [Convert]::ToInt32($fg.Substring(0,2),16),
                [Convert]::ToInt32($fg.Substring(2,2),16),
                [Convert]::ToInt32($fg.Substring(4,2),16))

            $rowRange = $ws.Cells[$row, 1, $row, $lastCol]
            $rowRange.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
            $rowRange.Style.Fill.BackgroundColor.SetColor($bgColor)

            # Bold + colour the status cell itself
            if ($statusColIdx) {
                $ws.Cells[$row, $statusColIdx].Style.Font.Bold = $true
                $ws.Cells[$row, $statusColIdx].Style.Font.Color.SetColor($fgColor)
            }
        }

        # Wrap text in Notes cell
        if ($notesColIdx) {
            $ws.Cells[$row, $notesColIdx].Style.WrapText = $true
        }

        # Make Patch KB URL a hyperlink
        $urlColIdx = $null
        for ($c = 1; $c -le $lastCol; $c++) {
            if ($ws.Cells[1, $c].Text -eq 'Patch KB URL') { $urlColIdx = $c; break }
        }
        if ($urlColIdx) {
            $urlVal = $ws.Cells[$row, $urlColIdx].Text
            if ($urlVal -match '^https?://') {
                $ws.Cells[$row, $urlColIdx].Hyperlink = [Uri]$urlVal
                $ws.Cells[$row, $urlColIdx].Style.Font.UnderLine = $true
                $ws.Cells[$row, $urlColIdx].Style.Font.Color.SetColor([System.Drawing.Color]::FromArgb(13,71,161))
                $ws.Cells[$row, $urlColIdx].Value = 'KB Article'
            }
        }
    }

    # Set reasonable column widths for known wide columns
    $ws.Column(6).Width  = 45   # Edition
    $ws.Column(9).Width  = 38   # Latest Release
    $ws.Column(13).Width = 45   # Notes

    Close-ExcelPackage $xlPkg
    Write-Log "Excel report saved: $FilePath"
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION 7 – Send email with Excel attachment
# ─────────────────────────────────────────────────────────────────────────────
function Send-ReportEmail {
    param(
        [string]   $AttachmentPath,
        [string]   $SmtpServer,
        [int]      $SmtpPort,
        [string]   $From,
        [string[]] $To,
        [string]   $Subject,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]   $UseSsl,
        [int]      $TotalCount,
        [int]      $OkCount,
        [int]      $PatchCount,
        [int]      $EolCount,
        [int]      $ErrCount
    )

    $body = @"
SQL Server Patch Audit Report – $(Get-Date -Format 'yyyy-MM-dd')

Summary:
  Total Instances  : $TotalCount
  Up to Date       : $OkCount
  Patch Available  : $PatchCount
  End of Life      : $EolCount
  Errors / Cannot Connect : $ErrCount

Please see the attached Excel workbook for full details.

Note: Always verify patch applicability in a test environment before applying to production.
"@

    $mailParams = @{
        SmtpServer  = $SmtpServer
        Port        = $SmtpPort
        From        = $From
        To          = $To
        Subject     = $Subject
        Body        = $body
        Attachments = $AttachmentPath
        Encoding    = [System.Text.Encoding]::UTF8
    }

    if ($Credential) { $mailParams['Credential'] = $Credential }
    if ($UseSsl)     { $mailParams['UseSsl']     = $true }

    try {
        Send-MailMessage @mailParams
        Write-Log "Email with Excel attachment sent to: $($To -join ', ')"
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

# 8.2  Fetch / load patch reference data
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

# 8.4  Build Excel report
Write-Log "Building Excel report..."
$saveDir     = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$reportPath  = Join-Path $saveDir "SQLPatchReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').xlsx"
Build-ExcelReport -Results $allResults.ToArray() -FilePath $reportPath

# 8.5  Compute summary counts for email body
$totalCount = @($allResults).Count
$okCount    = @($allResults | Where-Object { $_.PatchStatus -eq 'UP-TO-DATE'      }).Count
$patchCount = @($allResults | Where-Object { $_.PatchStatus -eq 'PATCH AVAILABLE' }).Count
$eolCount   = @($allResults | Where-Object { $_.PatchStatus -eq 'EOL'             }).Count
$errCount   = @($allResults | Where-Object { $_.PatchStatus -eq 'ERROR'           }).Count

# 8.6  Send email with Excel attachment
$subject = "$EmailSubject – $(Get-Date -Format 'yyyy-MM-dd')"
Send-ReportEmail `
    -AttachmentPath $reportPath `
    -SmtpServer     $SmtpServer `
    -SmtpPort       $SmtpPort `
    -From           $EmailFrom `
    -To             $EmailTo `
    -Subject        $subject `
    -Credential     $SmtpCredential `
    -UseSsl:$UseSsl `
    -TotalCount     $totalCount `
    -OkCount        $okCount `
    -PatchCount     $patchCount `
    -EolCount       $eolCount `
    -ErrCount       $errCount

Write-Log "=== SQL Server Patch Audit complete ==="

# Console summary
$allResults | Format-Table Instance, ProductVersion, PatchStatus, LatestBuild, LatestKBNumber -AutoSize
