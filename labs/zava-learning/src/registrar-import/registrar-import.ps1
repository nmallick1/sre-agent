<#
.SYNOPSIS
  Zava registrar import - loads the registrar's final-grade feed into ZavaResults and
  re-publishes each course's results.

.DESCRIPTION
  Runs on the SQL Server VM as the Scheduled Task "ZavaRegistrarImport".

  Locking contract (see incident b352b8ff, 2026-11-17):
    * NEVER wait for an external dependency (the registrar feed file) while a database
      transaction is open. The previous version marked the course IMPORTING inside a
      transaction and then polled for the feed for up to 240 minutes, holding an X key lock
      on dbo.publication_control and blocking every results-api read for that course
      (LCK_M_S -> 8 s request timeout -> HTTP 504).
    * Feed availability is checked first, with NO connection open. A course whose feed is
      missing is skipped (logged) and never touched in the database.
    * Each course is applied in its own short transaction (mark IMPORTING -> apply rows ->
      mark PUBLISHED -> commit), so locks are held only for the duration of the writes.
    * SET LOCK_TIMEOUT and CommandTimeout bound how long the job itself can wait.

  Config: C:/zava/registrar-import.json
          { "courses": ["BIO-101"], "feedDir": "C:/zava/feeds", "maxWaitMinutes": 240,
            "lockTimeoutMs": 5000, "commandTimeoutSeconds": 30 }
  Connection: read from the machine-level environment variable ZAVA_RESULTS_SQL_CONNECTION
          (provisioned on the VM; never committed to source control). The job appends
          "Application Name=ZavaRegistrarImport" so its sessions stay identifiable.
  Log:    C:/zava/logs/registrar-import.log
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:/zava/registrar-import.json'
)
$ErrorActionPreference = 'Stop'

$logDir = 'C:/zava/logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'registrar-import.log'
function Write-Log([string]$Message) {
    $line = '{0:u} {1}' -f (Get-Date).ToUniversalTime(), $Message
    Add-Content -Path $logFile -Value $line
}

$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
$feedDir = if ($config.feedDir) { $config.feedDir } else { 'C:/zava/feeds' }
$maxWaitMinutes = if ($config.maxWaitMinutes) { [int]$config.maxWaitMinutes } else { 240 }
$lockTimeoutMs = if ($config.lockTimeoutMs) { [int]$config.lockTimeoutMs } else { 5000 }
$commandTimeoutSeconds = if ($config.commandTimeoutSeconds) { [int]$config.commandTimeoutSeconds } else { 30 }
$batch = 'registrar-{0:yyyyMMdd-HHmmss}' -f (Get-Date).ToUniversalTime()

Write-Log "batch=$batch started courses=$($config.courses -join ',')"

# --- Phase 1: wait for registrar feeds WITHOUT any database connection or transaction ---
$deadline = (Get-Date).AddMinutes($maxWaitMinutes)
$ready = @()
foreach ($course in $config.courses) {
    $feed = Join-Path $feedDir "$course.csv"
    while (-not (Test-Path $feed) -and (Get-Date) -lt $deadline) {
        Write-Log "batch=$batch course=$course waiting for registrar feed $feed (no transaction open)"
        Start-Sleep -Seconds 60
    }
    if (Test-Path $feed) {
        $ready += $course
    } else {
        Write-Log "batch=$batch course=$course SKIPPED registrar feed $feed not delivered within $maxWaitMinutes minutes; course left PUBLISHED and untouched"
    }
}

if ($ready.Count -eq 0) {
    Write-Log "batch=$batch completed with no courses ready"
    exit 2
}

# --- Phase 2: apply each ready course in its own short transaction ---
$connString = [Environment]::GetEnvironmentVariable('ZAVA_RESULTS_SQL_CONNECTION', 'Machine')
if (-not $connString) { throw 'ZAVA_RESULTS_SQL_CONNECTION is not set' }
$builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($connString)
$builder['Application Name'] = 'ZavaRegistrarImport'
$conn = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)

function New-Command([System.Data.SqlClient.SqlTransaction]$Tx, [string]$Sql) {
    $c = $conn.CreateCommand()
    $c.Transaction = $Tx
    $c.CommandTimeout = $commandTimeoutSeconds
    $c.CommandText = $Sql
    return $c
}

$failed = 0
try {
    $conn.Open()
    $init = $conn.CreateCommand()
    $init.CommandText = "SET LOCK_TIMEOUT $lockTimeoutMs"
    [void]$init.ExecuteNonQuery()

    foreach ($course in $ready) {
        # Parse the feed before opening the transaction so file I/O never runs under locks.
        $rows = @(Import-Csv -Path (Join-Path $feedDir "$course.csv"))
        $tx = $conn.BeginTransaction()
        try {
            $cmd = New-Command $tx "UPDATE dbo.publication_control SET status = N'IMPORTING', last_import_batch = @batch, updated_at = SYSUTCDATETIME() WHERE course_id = @course"
            [void]$cmd.Parameters.Add('@batch', [System.Data.SqlDbType]::NVarChar, 64)
            [void]$cmd.Parameters.Add('@course', [System.Data.SqlDbType]::NVarChar, 16)
            $cmd.Parameters['@batch'].Value = $batch
            $cmd.Parameters['@course'].Value = $course
            [void]$cmd.ExecuteNonQuery()

            foreach ($row in $rows) {
                $cmd = New-Command $tx 'UPDATE dbo.course_results SET score_pct = @score, certificate_issued = CASE WHEN @score >= 70 THEN 1 ELSE 0 END WHERE course_id = @course AND student_id = @student'
                [void]$cmd.Parameters.Add('@score', [System.Data.SqlDbType]::Int)
                [void]$cmd.Parameters.Add('@course', [System.Data.SqlDbType]::NVarChar, 16)
                [void]$cmd.Parameters.Add('@student', [System.Data.SqlDbType]::Int)
                $cmd.Parameters['@score'].Value = [int]$row.score_pct
                $cmd.Parameters['@course'].Value = $course
                $cmd.Parameters['@student'].Value = [int]$row.student_id
                [void]$cmd.ExecuteNonQuery()
            }

            $cmd = New-Command $tx "UPDATE dbo.publication_control SET status = N'PUBLISHED', published_at = SYSUTCDATETIME(), updated_at = SYSUTCDATETIME() WHERE course_id = @course"
            [void]$cmd.Parameters.Add('@course', [System.Data.SqlDbType]::NVarChar, 16)
            $cmd.Parameters['@course'].Value = $course
            [void]$cmd.ExecuteNonQuery()

            $tx.Commit()
            Write-Log "batch=$batch course=$course published rows=$($rows.Count)"
        }
        catch {
            $failed++
            Write-Log "batch=$batch course=$course FAILED $($_.Exception.Message)"
            try { $tx.Rollback() } catch { }
        }
    }
}
finally {
    $conn.Dispose()
}

if ($failed -gt 0) {
    Write-Log "batch=$batch completed with $failed failed course(s)"
    exit 1
}
Write-Log "batch=$batch completed"
