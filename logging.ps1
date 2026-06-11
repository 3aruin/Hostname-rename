# logging.ps1
# Run logging for Hostname-Rename. Loaded first by launcher.ps1 so the
# orchestrator can log throughout a run.
#
# Design rule: logging must NEVER block a rename. Init failures disable logging
# and warn; write failures are swallowed (-ErrorAction SilentlyContinue) -- a
# device must still be renamed even if the log share is unreachable.

function Initialize-Log {
    # Resolves the per-run log file (default %TEMP%\Hostname-Rename; -LogPath overrides the dir).
    param (
        [string]$LogPath
    )

    $script:LOG_FILE = $null

    try {
        $dir = if ([string]::IsNullOrWhiteSpace($LogPath)) {
            Join-Path $env:TEMP "Hostname-Rename"
        } else {
            $LogPath
        }

        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }

        # Old computer name + timestamp keeps per-machine files distinct on a shared UNC (avoids concurrent-append contention).
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $file  = "Hostname-Rename_{0}_{1}.log" -f $env:COMPUTERNAME, $stamp
        $script:LOG_FILE = Join-Path $dir $file

        Write-Log -Level INFO -Message "Logging started. Host=$env:COMPUTERNAME LogFile=$script:LOG_FILE"
    } catch {
        Write-Warning "Could not initialise log (LogPath='$LogPath') -- continuing without a log file. $($_.Exception.Message)"
        $script:LOG_FILE = $null
    }
}

function Write-Log {
    # Appends a timestamped line to the run log; no-op if uninitialised. Never throws or blocks.
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    if (-not $script:LOG_FILE) { return }

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message

    # SilentlyContinue (not try/catch) so a transient write failure degrades to "no log line", not an abort.
    Add-Content -LiteralPath $script:LOG_FILE -Value $line -ErrorAction SilentlyContinue
}