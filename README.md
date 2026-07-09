# MySQL 8.0 → 8.4 LTS Pre-Upgrade Assessment Script

A read-only PowerShell script that scans a running MySQL 5.7/8.0 instance for the
most common breaking changes encountered when upgrading to **MySQL 8.4 LTS**, and
produces a text + HTML report you can review before scheduling the upgrade.

The script makes **no changes** to your server, users, or data. It only runs
`SELECT`-style diagnostic queries, reads local config/script files, and (optionally)
invokes the official `mysqlsh` Upgrade Checker utility.

## What it checks

| # | Check | Why it matters |
|---|-------|-----------------|
| 1 | Accounts using `mysql_native_password` | This plugin is disabled by default in MySQL 8.4 — affected accounts can lose the ability to authenticate. |
| 2 | Deprecated/removed `my.cnf` / `my.ini` parameters (`default_authentication_plugin`, `expire_logs_days`, `log_warnings`, `slave_parallel_workers`, `query_cache_*`, etc.) | These cause MySQL to fail to start after upgrade if left in place. |
| 3 | Foreign keys not backed by a full `PRIMARY KEY` / `UNIQUE KEY` on the referenced column(s) | MySQL 8.4 enforces stricter foreign key referencing rules. |
| 4 | Legacy replication terminology (`SHOW SLAVE STATUS`, `CHANGE MASTER TO`, `Seconds_Behind_Master`, etc.) in local scripts | These commands are removed/renamed in favor of `REPLICA`/`SOURCE` syntax. |
| 5 | Tables/columns still using `utf8` / `utf8mb3` | Legacy 3-byte charset, worth migrating to `utf8mb4` before/alongside the upgrade. |
| 6 | Official MySQL Shell Upgrade Checker (`mysqlsh ... util check-for-server-upgrade`) | Runs Oracle's own authoritative compatibility checker if `mysqlsh` is available, for cross-verification. |

## Requirements

- **PowerShell 5.1+** (Windows PowerShell or PowerShell 7+/Core, Windows/macOS/Linux)
- **MySQL command-line client** (`mysql.exe` / `mysql`) reachable on `PATH`, or pass its
  location with `-MySqlClientPath`
- *(Optional, recommended)* **MySQL Shell** (`mysqlsh`) on `PATH` for the official
  upgrade checker step — install it separately if you don't already have it
- A MySQL user with `SELECT` privileges on:
  - `mysql.user`
  - `information_schema.*`
  - (no write privileges required)

## Files

- `MySQL84-PreUpgrade-Check.ps1` — the script
- `README.md` — this file

## Usage

Basic run against a local server:

```powershell
.\MySQL84-PreUpgrade-Check.ps1 -User root
```

Full example with config and script scanning:

```powershell
.\MySQL84-PreUpgrade-Check.ps1 `
  -MySqlHost "db01.internal" `
  -Port 3306 `
  -User "dba_readonly" `
  -ConfigPath "C:\ProgramData\MySQL\MySQL Server 8.0\my.ini" `
  -ScriptsPath "D:\ops\scripts" `
  -OutputFolder "D:\reports\mysql84"
```

If you omit `-Password`, the script prompts securely (masked input) instead of
taking the password as plain text on the command line — safer for shared shells
and shell history.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-MySqlHost` | `localhost` | MySQL server hostname/IP |
| `-Port` | `3306` | MySQL port |
| `-User` | `root` | MySQL username |
| `-Password` | *(prompted)* | MySQL password; omit to be prompted securely |
| `-ConfigPath` | *(auto-detect common paths)* | Path to `my.cnf` / `my.ini` to scan |
| `-ScriptsPath` | `.` (current directory) | Folder to recursively scan for legacy replication syntax in `.sql`, `.sh`, `.ps1`, `.py`, `.yml`, `.yaml` files |
| `-OutputFolder` | `.\MySQL84_UpgradeReport` | Where reports are written |
| `-MySqlClientPath` | `mysql` | Path to `mysql` client binary if not on `PATH` |
| `-MySqlShPath` | `mysqlsh` | Path to `mysqlsh` binary if not on `PATH` |

## Output

Each run creates timestamped files in `-OutputFolder`:

- `MySQL84_UpgradeReport_<timestamp>.txt` — plain-text findings, grouped by severity
- `MySQL84_UpgradeReport_<timestamp>.html` — color-coded HTML report (Critical → red,
  High → orange, Medium → yellow, Info → blue)
- `mysqlsh_upgrade_checker_<timestamp>.txt` — raw output from the official upgrade
  checker utility, if `mysqlsh` was found and ran successfully

Findings are also printed to the console in real time as each check runs.

## Severity levels

- **Critical** — will very likely break the upgrade or lock out access (e.g. connection
  failure, `mysql_native_password` accounts)
- **High** — will very likely cause startup failure or query errors post-upgrade
  (e.g. removed config parameters, legacy replication syntax, non-compliant foreign keys)
- **Medium** — should be addressed but won't typically block the upgrade outright
  (e.g. `utf8mb3` usage, missing config file to scan)
- **Info** — informational only (e.g. successful connection, checker executed)

## Recommended workflow

1. Run this script against production (all checks are read-only and lightweight) or
   against a restored backup / read replica if you prefer zero risk.
2. Review the HTML report, starting with Critical and High findings.
3. Remediate each finding (migrate auth plugins, update config, fix schema, update
   scripts/tooling).
4. Re-run the script to confirm a clean report.
5. Cross-check with the `mysqlsh` Upgrade Checker output for anything the heuristic
   SQL checks in this script might miss (it does not cover every possible 8.4
   incompatibility — treat it as a first-pass triage tool, not a complete substitute
   for the official checker).
6. Proceed with the upgrade in a maintenance window, with a tested rollback/backup plan.

## Limitations

- The foreign-key check (Item 3) uses a heuristic `information_schema` query and may
  produce false positives/negatives on complex schemas — always cross-verify with
  `mysqlsh util check-for-server-upgrade`.
- The config file scan only checks the file(s) you provide or a small set of common
  default paths; it does not parse `!includedir` directives or multiple included files.
- The script does not check storage engine compatibility, third-party plugin
  compatibility, or application-level query compatibility — those require separate
  testing (e.g. a staging environment upgrade dry run).
