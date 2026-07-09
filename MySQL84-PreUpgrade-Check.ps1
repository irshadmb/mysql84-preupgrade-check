<#
.SYNOPSIS
    MySQL 8.0 -> 8.4 LTS Pre-Upgrade Compatibility Assessment Script

.DESCRIPTION
    This script performs a READ-ONLY assessment of a running MySQL 5.7/8.0
    instance and flags the incompatibilities that commonly break upgrades
    to MySQL 8.4 LTS:

      1. Accounts still using mysql_native_password (disabled by default in 8.4)
      2. Legacy / removed configuration parameters in my.cnf / my.ini
         (default_authentication_plugin, expire_logs_days, log_warnings,
          slave_parallel_workers, etc.)
      3. Foreign keys that do not reference a full PRIMARY KEY / UNIQUE KEY
      4. Legacy MASTER/SLAVE replication terminology used in local scripts
      5. Tables/columns still using utf8 / utf8mb3 instead of utf8mb4
      6. Runs the official MySQL Shell Upgrade Checker (mysqlsh ... util
         check-for-server-upgrade) if mysqlsh is available on PATH

    It does NOT modify any data, users, or configuration. It only reads
    and reports, then writes a timestamped HTML + text report you can
    review before planning the actual upgrade.

.PARAMETER MySqlHost
    MySQL server hostname or IP. Default: localhost

.PARAMETER Port
    MySQL port. Default: 3306

.PARAMETER User
    MySQL user with access to mysql.*, information_schema.*, and
    performance_schema (a user with SELECT on those is sufficient).

.PARAMETER Password
    Password for -User. If omitted you will be prompted securely.

.PARAMETER ConfigPath
    Path to my.cnf / my.ini to scan for deprecated parameters.
    Default: attempts common Windows/Linux locations if reachable.

.PARAMETER ScriptsPath
    Folder to recursively scan for legacy MASTER/SLAVE replication syntax
    in operational scripts (*.sql, *.sh, *.ps1, *.py, *.yml, *.yaml).
    Default: current directory.

.PARAMETER OutputFolder
    Folder to write the report to. Default: .\MySQL84_UpgradeReport

.PARAMETER MySqlShPath
    Full path to mysqlsh.exe if not on PATH. Optional.

.EXAMPLE
    .\MySQL84-PreUpgrade-Check.ps1 -MySqlHost "db01.internal" -User root -ConfigPath "C:\ProgramData\MySQL\MySQL Server 8.0\my.ini"

.EXAMPLE
    .\MySQL84-PreUpgrade-Check.ps1 -User admin -ScriptsPath "D:\ops\scripts" -OutputFolder "D:\reports"

.NOTES
    Requires the MySQL command-line client (mysql.exe) on PATH or reachable
    via -MySqlClientPath. Optionally uses mysqlsh.exe for the official
    Oracle Upgrade Checker utility.
    This script performs assessment only. No destructive action is taken.
#>

[CmdletBinding()]
param(
    [string]$MySqlHost = "localhost",
    [int]$Port = 3306,
    [string]$User = "root",
    [string]$Password,
    [string]$ConfigPath,
    [string]$ScriptsPath = ".",
    [string]$OutputFolder = ".\MySQL84_UpgradeReport",
    [string]$MySqlClientPath = "mysql",
    [string]$MySqlShPath = "mysqlsh"
)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
$ErrorActionPreference = "Stop"
$timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$reportItems = New-Object System.Collections.Generic.List[object]

if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}
$txtReportPath  = Join-Path $OutputFolder "MySQL84_UpgradeReport_$timestamp.txt"
$htmlReportPath = Join-Path $OutputFolder "MySQL84_UpgradeReport_$timestamp.html"

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor Cyan
}

function Add-Finding {
    param(
        [string]$Category,
        [ValidateSet("Critical","High","Medium","Info")]
        [string]$Severity,
        [string]$Summary,
        [string]$Detail
    )
    $reportItems.Add([PSCustomObject]@{
        Category = $Category
        Severity = $Severity
        Summary  = $Summary
        Detail   = $Detail
    }) | Out-Null

    $color = switch ($Severity) {
        "Critical" { "Red" }
        "High"     { "Yellow" }
        "Medium"   { "DarkYellow" }
        default    { "Gray" }
    }
    Write-Host "  [$Severity] $Summary" -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Resolve MySQL client
# ---------------------------------------------------------------------------
function Get-MySqlCommand {
    if (-not (Get-Command $MySqlClientPath -ErrorAction SilentlyContinue)) {
        throw "mysql client not found at '$MySqlClientPath'. Install MySQL client tools or pass -MySqlClientPath."
    }
    return $MySqlClientPath
}

if (-not $Password) {
    $secure = Read-Host -Prompt "Enter password for MySQL user '$User'" -AsSecureString
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

function Invoke-MySqlQuery {
    param(
        [Parameter(Mandatory)] [string]$Sql,
        [switch]$Raw
    )
    $mysqlExe = Get-MySqlCommand
    $args = @(
        "-h", $MySqlHost,
        "-P", $Port,
        "-u", $User,
        "--password=$Password",
        "-N",              # skip column names for parsing (unless -Raw)
        "-B",              # batch/tab-separated
        "-e", $Sql
    )
    if ($Raw) { $args = $args | Where-Object { $_ -ne "-N" } }

    try {
        $output = & $mysqlExe $args 2>&1
        return $output
    }
    catch {
        Write-Warning "MySQL query failed: $($_.Exception.Message)"
        return $null
    }
}

Write-Section "MySQL 8.0 -> 8.4 LTS Pre-Upgrade Assessment"
Write-Host "Target        : $MySqlHost`:$Port"
Write-Host "User          : $User"
Write-Host "Config path   : $(if ($ConfigPath) { $ConfigPath } else { '(not provided)' })"
Write-Host "Scripts path  : $ScriptsPath"
Write-Host "Output folder : $OutputFolder"

# ---------------------------------------------------------------------------
# 0. Connectivity + version check
# ---------------------------------------------------------------------------
Write-Section "0. Connectivity & Version Check"
$version = Invoke-MySqlQuery -Sql "SELECT VERSION();"
if (-not $version) {
    Add-Finding -Category "Connectivity" -Severity "Critical" `
        -Summary "Could not connect to MySQL server" `
        -Detail "Check host/port/credentials and that mysql.exe is reachable."
} else {
    $verString = ($version | Select-Object -First 1).ToString().Trim()
    Write-Host "Connected. MySQL version: $verString" -ForegroundColor Green
    Add-Finding -Category "Connectivity" -Severity "Info" `
        -Summary "Connected successfully" -Detail "Server reports version $verString"
}

# ---------------------------------------------------------------------------
# 1. mysql_native_password accounts (disabled by default in 8.4)
# ---------------------------------------------------------------------------
Write-Section "1. Accounts using mysql_native_password"
$nativePwSql = @"
SELECT CONCAT(user,'@',host,' -> ',plugin)
FROM mysql.user
WHERE plugin = 'mysql_native_password';
"@
$nativeAccounts = Invoke-MySqlQuery -Sql $nativePwSql
if ($nativeAccounts -and $nativeAccounts.Count -gt 0 -and $nativeAccounts[0] -notmatch "^ERROR") {
    foreach ($row in $nativeAccounts) {
        if ([string]::IsNullOrWhiteSpace($row)) { continue }
        Add-Finding -Category "Authentication" -Severity "Critical" `
            -Summary "Account uses mysql_native_password: $row" `
            -Detail "MySQL 8.4 disables mysql_native_password by default. Migrate with: ALTER USER '<user>'@'<host>' IDENTIFIED WITH caching_sha2_password BY '<password>';"
    }
} else {
    Write-Host "  No accounts found using mysql_native_password (or query failed)." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 2. Legacy / removed configuration parameters
# ---------------------------------------------------------------------------
Write-Section "2. Legacy / Removed Configuration Parameters"

$deprecatedParams = @(
    "default_authentication_plugin",
    "log_warnings",
    "expire_logs_days",
    "slave_parallel_workers",
    "old_passwords",
    "log_slow_admin_statements",
    "innodb_locks_unsafe_for_binlog",
    "query_cache_size",
    "query_cache_type",
    "secure_auth"
)

$candidateConfigPaths = @()
if ($ConfigPath) {
    $candidateConfigPaths += $ConfigPath
} else {
    # common default locations (best-effort; harmless if missing)
    $candidateConfigPaths += @(
        "C:\ProgramData\MySQL\MySQL Server 8.0\my.ini",
        "C:\ProgramData\MySQL\MySQL Server 5.7\my.ini",
        "/etc/my.cnf",
        "/etc/mysql/my.cnf"
    )
}

$foundConfig = $false
foreach ($cfgPath in $candidateConfigPaths) {
    if (Test-Path $cfgPath) {
        $foundConfig = $true
        Write-Host "  Scanning config file: $cfgPath"
        $lines = Get-Content $cfgPath
        foreach ($param in $deprecatedParams) {
            $matches = $lines | Select-String -Pattern "^\s*$param\s*="
            foreach ($m in $matches) {
                Add-Finding -Category "Configuration" -Severity "High" `
                    -Summary "Deprecated/removed parameter '$param' found in $cfgPath (line $($m.LineNumber))" `
                    -Detail "Line: $($m.Line.Trim()). This parameter is removed or obsolete in MySQL 8.4 and can cause startup abort. Review the MySQL 8.4 reference manual for the supported replacement (e.g. expire_logs_days -> binlog_expire_logs_seconds)."
            }
        }
    }
}
if (-not $foundConfig) {
    Add-Finding -Category "Configuration" -Severity "Medium" `
        -Summary "No configuration file scanned" `
        -Detail "Pass -ConfigPath explicitly pointing to my.cnf / my.ini to enable this check."
}

# ---------------------------------------------------------------------------
# 3. Foreign keys not referencing a full PRIMARY/UNIQUE key
# ---------------------------------------------------------------------------
Write-Section "3. Foreign Keys Not Referencing a Full Unique Index"

$fkSql = @"
SELECT
  CONCAT(kcu.TABLE_SCHEMA,'.',kcu.TABLE_NAME,'.',kcu.CONSTRAINT_NAME,
         ' -> references ', kcu.REFERENCED_TABLE_SCHEMA,'.',kcu.REFERENCED_TABLE_NAME)
FROM information_schema.KEY_COLUMN_USAGE kcu
WHERE kcu.REFERENCED_TABLE_NAME IS NOT NULL
  AND kcu.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  AND NOT EXISTS (
    SELECT 1
    FROM information_schema.STATISTICS s
    WHERE s.TABLE_SCHEMA = kcu.REFERENCED_TABLE_SCHEMA
      AND s.TABLE_NAME   = kcu.REFERENCED_TABLE_NAME
      AND s.NON_UNIQUE = 0
      AND s.COLUMN_NAME = kcu.REFERENCED_COLUMN_NAME
      AND (
        SELECT COUNT(*) FROM information_schema.STATISTICS s2
        WHERE s2.TABLE_SCHEMA = s.TABLE_SCHEMA
          AND s2.TABLE_NAME = s.TABLE_NAME
          AND s2.INDEX_NAME = s.INDEX_NAME
      ) = 1
  );
"@
$fkFindings = Invoke-MySqlQuery -Sql $fkSql
if ($fkFindings -and $fkFindings.Count -gt 0 -and $fkFindings[0] -notmatch "^ERROR") {
    foreach ($row in $fkFindings) {
        if ([string]::IsNullOrWhiteSpace($row)) { continue }
        Add-Finding -Category "Schema" -Severity "High" `
            -Summary "Foreign key may not reference a full unique index: $row" `
            -Detail "Run 'mysqlsh -- util check-for-server-upgrade' to confirm via the official foreignKeyReferences check, and add a dedicated UNIQUE KEY on the referenced column(s) or extend the FK to the full composite key."
    }
} else {
    Write-Host "  No obviously non-compliant foreign keys detected by heuristic scan (verify with mysqlsh Upgrade Checker)." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 4. Legacy MASTER/SLAVE replication terminology in local scripts
# ---------------------------------------------------------------------------
Write-Section "4. Legacy Replication Terminology in Scripts ($ScriptsPath)"

$legacyPatterns = @(
    "SHOW SLAVE STATUS",
    "START SLAVE",
    "STOP SLAVE",
    "SHOW MASTER STATUS",
    "CHANGE MASTER TO",
    "Seconds_Behind_Master"
)

if (Test-Path $ScriptsPath) {
    $scriptFiles = Get-ChildItem -Path $ScriptsPath -Recurse -Include *.sql,*.sh,*.ps1,*.py,*.yml,*.yaml -ErrorAction SilentlyContinue
    foreach ($file in $scriptFiles) {
        $content = Get-Content $file.FullName -ErrorAction SilentlyContinue
        foreach ($pattern in $legacyPatterns) {
            $hits = $content | Select-String -Pattern $pattern -SimpleMatch
            foreach ($hit in $hits) {
                Add-Finding -Category "Replication Tooling" -Severity "High" `
                    -Summary "Legacy replication syntax '$pattern' found in $($file.FullName) (line $($hit.LineNumber))" `
                    -Detail "Replace with modern SOURCE/REPLICA syntax, e.g. SHOW SLAVE STATUS -> SHOW REPLICA STATUS, CHANGE MASTER TO -> CHANGE REPLICATION SOURCE TO, Seconds_Behind_Master -> Seconds_Behind_Source."
            }
        }
    }
    if (-not $scriptFiles) {
        Write-Host "  No .sql/.sh/.ps1/.py/.yml/.yaml files found under $ScriptsPath" -ForegroundColor Gray
    }
} else {
    Write-Warning "ScriptsPath '$ScriptsPath' not found; skipping replication terminology scan."
}

# ---------------------------------------------------------------------------
# 5. utf8mb3 / utf8 character set usage
# ---------------------------------------------------------------------------
Write-Section "5. Deprecated utf8mb3 (utf8) Character Set Usage"

$charsetSql = @"
SELECT CONCAT(TABLE_SCHEMA,'.',TABLE_NAME,' [table default charset]')
FROM information_schema.TABLES
WHERE TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  AND TABLE_COLLATION LIKE 'utf8_%' OR TABLE_COLLATION LIKE 'utf8mb3_%'
UNION ALL
SELECT CONCAT(TABLE_SCHEMA,'.',TABLE_NAME,'.',COLUMN_NAME,' [column charset: ',CHARACTER_SET_NAME,']')
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
  AND CHARACTER_SET_NAME IN ('utf8','utf8mb3');
"@
$charsetFindings = Invoke-MySqlQuery -Sql $charsetSql
if ($charsetFindings -and $charsetFindings.Count -gt 0 -and $charsetFindings[0] -notmatch "^ERROR") {
    foreach ($row in $charsetFindings) {
        if ([string]::IsNullOrWhiteSpace($row)) { continue }
        Add-Finding -Category "Character Set" -Severity "Medium" `
            -Summary "utf8/utf8mb3 usage: $row" `
            -Detail "Convert to utf8mb4: ALTER TABLE <table> CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci; Test index lengths and collation behavior after conversion."
    }
} else {
    Write-Host "  No utf8/utf8mb3 usage detected." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 6. Official MySQL Shell Upgrade Checker (if mysqlsh available)
# ---------------------------------------------------------------------------
Write-Section "6. MySQL Shell Upgrade Checker (mysqlsh util check-for-server-upgrade)"

$mysqlshCmd = Get-Command $MySqlShPath -ErrorAction SilentlyContinue
if ($mysqlshCmd) {
    Write-Host "  mysqlsh found at $($mysqlshCmd.Source). Running official upgrade checker..."
    $connString = "$User@$MySqlHost`:$Port"
    try {
        $env:MYSQLSH_PWD = $Password
        $checkerOutput = & $MySqlShPath --passwords-from-stdin $connString -- util check-for-server-upgrade 2>&1 <<< $Password
        $checkerOutput | Out-File -FilePath (Join-Path $OutputFolder "mysqlsh_upgrade_checker_$timestamp.txt") -Encoding UTF8
        Add-Finding -Category "Upgrade Checker" -Severity "Info" `
            -Summary "mysqlsh Upgrade Checker executed" `
            -Detail "Full output saved to mysqlsh_upgrade_checker_$timestamp.txt in $OutputFolder. Review it for authoritative results."
    }
    catch {
        Add-Finding -Category "Upgrade Checker" -Severity "Medium" `
            -Summary "mysqlsh Upgrade Checker failed to run" `
            -Detail $_.Exception.Message
    }
    finally {
        Remove-Item Env:\MYSQLSH_PWD -ErrorAction SilentlyContinue
    }
} else {
    Add-Finding -Category "Upgrade Checker" -Severity "Medium" `
        -Summary "mysqlsh not found on PATH" `
        -Detail "Install MySQL Shell and re-run, or manually execute: mysqlsh $User@$MySqlHost`:$Port -- util check-for-server-upgrade"
}

# ---------------------------------------------------------------------------
# Report generation
# ---------------------------------------------------------------------------
Write-Section "Generating Reports"

# Text report
$txtLines = @()
$txtLines += "MySQL 8.0 -> 8.4 LTS Pre-Upgrade Assessment Report"
$txtLines += "Generated: $(Get-Date)"
$txtLines += "Target: $MySqlHost`:$Port (user: $User)"
$txtLines += ("=" * 78)
$grouped = $reportItems | Group-Object Severity | Sort-Object { switch ($_.Name) { "Critical" {0} "High" {1} "Medium" {2} default {3} } }
foreach ($grp in $grouped) {
    $txtLines += ""
    $txtLines += "== $($grp.Name) ($($grp.Count)) =="
    foreach ($item in $grp.Group) {
        $txtLines += "- [$($item.Category)] $($item.Summary)"
        $txtLines += "    $($item.Detail)"
    }
}
$txtLines | Out-File -FilePath $txtReportPath -Encoding UTF8

# HTML report
$sevColor = @{ Critical="#c0392b"; High="#e67e22"; Medium="#d4ac0d"; Info="#2e86c1" }
$htmlRows = ($reportItems | ForEach-Object {
    "<tr><td style='color:$($sevColor[$_.Severity]);font-weight:bold;'>$($_.Severity)</td><td>$($_.Category)</td><td>$($_.Summary)</td><td>$($_.Detail)</td></tr>"
}) -join "`n"

$html = @"
<html>
<head>
<meta charset="utf-8" />
<title>MySQL 8.0 -> 8.4 LTS Pre-Upgrade Assessment</title>
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #222; }
 h1 { color: #1a5276; }
 table { border-collapse: collapse; width: 100%; }
 th, td { border: 1px solid #ddd; padding: 8px; vertical-align: top; text-align: left; }
 th { background-color: #1a5276; color: white; }
 tr:nth-child(even) { background-color: #f7f7f7; }
</style>
</head>
<body>
<h1>MySQL 8.0 &rarr; 8.4 LTS Pre-Upgrade Assessment</h1>
<p><b>Generated:</b> $(Get-Date)<br/>
<b>Target:</b> $MySqlHost`:$Port (user: $User)</p>
<table>
<tr><th>Severity</th><th>Category</th><th>Summary</th><th>Detail</th></tr>
$htmlRows
</table>
</body>
</html>
"@
$html | Out-File -FilePath $htmlReportPath -Encoding UTF8

Write-Host ""
Write-Host "Assessment complete." -ForegroundColor Green
Write-Host "Text report : $txtReportPath"
Write-Host "HTML report : $htmlReportPath"

$critCount = ($reportItems | Where-Object { $_.Severity -eq "Critical" }).Count
$highCount = ($reportItems | Where-Object { $_.Severity -eq "High" }).Count
Write-Host ""
Write-Host "Summary: $critCount Critical, $highCount High severity findings." -ForegroundColor $(if ($critCount -gt 0) { "Red" } elseif ($highCount -gt 0) { "Yellow" } else { "Green" })
Write-Host "Review findings before scheduling the MySQL 8.4 upgrade maintenance window."
