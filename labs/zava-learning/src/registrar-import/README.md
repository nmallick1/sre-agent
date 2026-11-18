# registrar-import

Nightly job that loads the registrar's final-grade feed into `ZavaResults` and re-publishes each
course's results. Runs on the SQL Server VM (`vm-zava-sql-*`) as the Windows scheduled task
`ZavaRegistrarImport` (daily 02:00 UTC). The task runs `powershell.exe -File C:\zava\registrar-import.ps1`.

## Files on the VM
| Path | Purpose |
|---|---|
| `C:\zava\registrar-import.ps1` | this script |
| `C:\zava\registrar-import.json` | config: `sqlServer`, `database`, `sqlUser`, `courses`, `feedDir`, `maxWaitMinutes`, `lockTimeoutMs`, `commandTimeoutSeconds` |
| `C:\zava\feeds\<course>.csv` | registrar feed (`student_id,score_pct`) |
| `C:\zava\logs\registrar-import.log` | job log |

The SQL password comes from the machine environment variable `ZAVA_REGISTRAR_SQL_PASSWORD`. Never
put it in the JSON config or in this repo.

## Transaction-scope rules (do not regress)
1. Never wait for external input (feed files, HTTP, user action) while a SQL transaction is open.
   Holding the `publication_control` row lock blocks `results-api` reads for that course: students
   see 504 on results/certificates.
2. One short transaction per course, opened only after its feed has been read into memory.
3. `SET LOCK_TIMEOUT` and command timeouts are always set.
4. A course whose feed is late is skipped and logged (`SKIPPED`), with exit code 1, so the task
   result surfaces it. It is never left locked.

## Deploy / rollback
Copy `registrar-import.ps1` to `C:\zava\` on the SQL VM (for example with a managed run command or
your config-management tool), and confirm the scheduled task action still points at it. Roll back
by restoring the previous file. Re-running a skipped or stopped import is an operator decision once
the feed exists: `Start-ScheduledTask -TaskName ZavaRegistrarImport`.
