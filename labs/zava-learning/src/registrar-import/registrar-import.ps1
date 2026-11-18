<#
.SYNOPSIS
  Zava registrar import - loads the registrar's final-grade feed into ZavaResults and
  re-publishes each course's results.

.DESCRIPTION
  Runs on the SQL Server VM as the Scheduled Task "ZavaRegistrarImport" (nightly, 02:00 UTC).

  Transaction-scope rules (see incident 2026-11-18, alert Zava-course-results-unavailable):
    * NEVER wait for an external input (the registrar feed file) while a transaction is open.
      The previous version marked every course IMPORTING inside one transaction and then polled
      for the feed for up to maxWaitMinutes (240). The X key lock on dbo.publication_control
      blocked results-api reads for that course -> students got 504s for hours.
    * The feed is checked/awaited OUTSIDE any transaction. A course whose feed is not present
      by the deadline is SKIPPED (logged), never left locked.
    * Each course is imported in its own short transaction (mark IMPORTING -> apply grades ->
      mark PUBLISHED -> commit), so a course is locked only for the seconds the writes take.
    * SET LOCK_TIMEOUT and a command timeout bound how long this job can itself wait or hold.

  Config: C:\zava\registrar-import.json
          { "sqlServer": "localhost", "database": "ZavaResults", "sqlUser": "<login>",
            "courses": ["BIO-101"], "feedDir": "C:\\zava\\feeds", "maxWaitMinutes": 240,
            "lockTimeoutMs": 5000, "commandTimeoutSeconds": 30 }
  The SQL password is read from the environment variable ZAVA_REGISTRAR_SQL_PASSWORD (never from
  this file or the JSON config). Maintainers: reconcile the connection setup with the on-VM
  deployment before rollout - the credential lines of the VM copy were intentionally not exported.
  Log:    C:\zava\logs\registrar-import.log
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\zava\registrar-import.json'
)
$ErrorActionPreference = 'Stop'

$logDir = 'C:\zava\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'registrar-import.log'
function Write-Log([string]$Message) {
    $line = '{0:u} {1}' -f (Get-Date).ToUniversalTime(), $Message
    Add-Content -Path $logFile -Value $line
}

$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
$feedDir = if ($config.feedDir) { $config.feedDir } else { 'C:\zava\feeds' }
$maxWaitMinutes = if ($config.maxWaitMinutes) { [int]$config.maxWaitMinutes } else { 240 }
$lockTimeoutMs = if ($config.lockTimeoutMs) { [int]$config.lockTimeoutMs } else { 5000 }
$commandTimeoutSeconds = if ($config.commandTimeoutSeconds) { [int]$config.commandTimeoutSeconds } else { 30 }
$batch = 'registrar-{0:yyyyMMdd-HHmmss}' -f (Get-Date).ToUniversalTime()

function New-ZavaConnection {
    $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $csb['Data Source'] = if ($config.sqlServer) { $config.sqlServer } else { 'localhost' }
    $csb['Initial Catalog'] = if ($config.database) { $config.database } else { 'ZavaResults' }
    $csb['User ID'] = $config.sqlUser
    $csb['Password'] = $env:ZAVA_REGISTRAR_SQL_PASSWORD
    $csb['Application Name'] = 'ZavaRegistrarImport'
    $csb['Encrypt'] = $true
    $csb['TrustServerCertificate'] = $true
    $c = New-Object System.Data.SqlClient.SqlConnection $csb.ConnectionString
    $c.Open()
    # Bound how long this job waits on other sessions' locks.
    $set = $c.CreateCommand()
    $set.CommandText = "SET LOCK_TIMEOUT $lockTimeoutMs"
    [void]$set.ExecuteNonQuery()
    return $c
}

function New-Command($Connection, $Transaction, [string]$Text) {
    $cmd = $Connection.CreateCommand()
    $cmd.Transaction = $Transaction
    $cmd.CommandTimeout = $commandTimeoutSeconds
    $cmd.CommandText = $Text
    return $cmd
}

Write-Log "batch=$batch started courses=$($config.courses -join ',')"

# Phase 1 - wait for feeds with NO database transaction (and no connection) open.
$deadline = (Get-Date).AddMinutes($maxWaitMinutes)
$ready = @()
$pending = @($config.courses)
while ($pending.Count -gt 0) {
    $stillPending = @()
    foreach ($course in $pending) {
        $feed = Join-Path $feedDir "$course.csv"
        if (Test-Path $feed) { $ready += $course } else { $stillPending += $course }
    }
    $pending = $stillPending
    if ($pending.Count -eq 0) { break }
    if ((Get-Date) -gt $deadline) {
        foreach ($course in $pending) {
            Write-Log "batch=$batch course=$course SKIPPED registrar feed not delivered within $maxWaitMinutes minutes (no locks held)"
        }
        break
    }
    Write-Log "batch=$batch waiting for registrar feeds courses=$($pending -join ',') (no transaction open)"
    Start-Sleep -Seconds 60
}

# Phase 2 - one short transaction per course whose feed is present.
$failed = 0
foreach ($course in $ready) {
    $feed = Join-Path $feedDir "$course.csv"
    $rows = Import-Csv -Path $feed   # parse BEFORE opening the transaction
    $conn = New-ZavaConnection
    $tx = $conn.BeginTransaction()
    try {
        $cmd = New-Command $conn $tx "UPDATE dbo.publication_control SET status = N'IMPORTING', last_import_batch = @batch, updated_at = SYSUTCDATETIME() WHERE course_id = @course"
        [void]$cmd.Parameters.Add('@batch', [System.Data.SqlDbType]::NVarChar, 64)
        [void]$cmd.Parameters.Add('@course', [System.Data.SqlDbType]::NVarChar, 16)
        $cmd.Parameters['@batch'].Value = $batch
        $cmd.Parameters['@course'].Value = $course
        [void]$cmd.ExecuteNonQuery()

        foreach ($row in $rows) {
            $cmd = New-Command $conn $tx 'UPDATE dbo.course_results SET score_pct = @score, certificate_issued = CASE WHEN @score >= 70 THEN 1 ELSE 0 END WHERE course_id = @course AND student_id = @student'
            [void]$cmd.Parameters.Add('@score', [System.Data.SqlDbType]::Int)
            [void]$cmd.Parameters.Add('@course', [System.Data.SqlDbType]::NVarChar, 16)
            [void]$cmd.Parameters.Add('@student', [System.Data.SqlDbType]::Int)
            $cmd.Parameters['@score'].Value = [int]$row.score_pct
            $cmd.Parameters['@course'].Value = $course
            $cmd.Parameters['@student'].Value = [int]$row.student_id
            [void]$cmd.ExecuteNonQuery()
        }

        $cmd = New-Command $conn $tx "UPDATE dbo.publication_control SET status = N'PUBLISHED', published_at = SYSUTCDATETIME(), updated_at = SYSUTCDATETIME() WHERE course_id = @course"
        [void]$cmd.Parameters.Add('@course', [System.Data.SqlDbType]::NVarChar, 16)
        $cmd.Parameters['@course'].Value = $course
        [void]$cmd.ExecuteNonQuery()

        $tx.Commit()
        Write-Log "batch=$batch course=$course published rows=$(@($rows).Count)"
    }
    catch {
        $failed++
        Write-Log "batch=$batch course=$course FAILED $($_.Exception.Message)"
        try { $tx.Rollback() } catch { }
    }
    finally {
        $conn.Dispose()
    }
}

$skipped = @($config.courses).Count - @($ready).Count
Write-Log "batch=$batch completed published=$(@($ready).Count - $failed) failed=$failed skipped=$skipped"
if ($failed -gt 0 -or $skipped -gt 0) { exit 1 }
