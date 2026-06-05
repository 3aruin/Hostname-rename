# logging.ps1
# Lightweight run logging for Hostname-Rename (OQ-001).
#
# Loaded FIRST by launcher.ps1 so the orchestrator can log throughout a run.
#
# Initialize-Log chooses the destination (default %TEMP%\Hostname-Rename;
# override the directory -- local or UNC -- with -LogPath). Write-Log appends
# timestamped lines.
#
# Design rule: logging must NEVER block a rename. Initialisation failures
# disable logging and warn; individual write failures are swallowed
# (-ErrorAction SilentlyContinue). A device must still get renamed even if the
# log share is unreachable.

function Initialize-Log {
    <#
    .SYNOPSIS
        Resolves and prepares the per-run log file. Defaults to
        %TEMP%\Hostname-Rename; -LogPath overrides the directory.

    .NOTES
        Stores the resolved file in $script:LOG_FILE. On any failure, sets
        $script:LOG_FILE to $null (logging disabled for the run) and warns.
        Returns nothing -- callers do not branch on the result.
    #>
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

        # Old computer name + timestamp keeps per-machine files distinct on a
        # shared UNC and avoids concurrent-append contention.
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
    <#
    .SYNOPSIS
        Appends a timestamped line to the current run log. No-op when logging
        was not initialised or failed. Never throws and never blocks.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    if (-not $script:LOG_FILE) { return }

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message

    # SilentlyContinue (not try/catch) so a transient write failure -- e.g. a UNC
    # share dropping mid-run -- degrades to "no log line" instead of aborting.
    Add-Content -LiteralPath $script:LOG_FILE -Value $line -ErrorAction SilentlyContinue
}
