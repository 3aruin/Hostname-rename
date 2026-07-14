# logging.ps1
# Run logging for Hostname-Rename. Loaded first by launcher.ps1 so the
# orchestrator can log throughout a run.
#
# Design rule: logging must NEVER block a rename. Init failures disable logging
# and warn; write failures are swallowed (-ErrorAction SilentlyContinue) -- a
# device must still be renamed even if the log share is unreachable.

# Days a run log is kept before Initialize-Log prunes it. Applies only to the
# default %TEMP%\Hostname-Rename directory -- an explicit -LogPath (e.g. a shared
# UNC log share holding other machines' logs) is never pruned; retention there
# is the share owner's policy.
$script:LOG_RETENTION_DAYS = 30

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

        # A UNC LogPath means every log write authenticates this (elevated) machine to a
        # remote SMB host -- an NTLM handshake a hostile share can capture/relay. Surface it
        # so a coerced or mistyped -LogPath is visible, rather than leaking silently.
        if ($dir -match '^\\\\') {
            Write-Warning "LogPath '$dir' is a UNC path -- writing the run log authenticates this machine to that host over SMB (NTLM). Use it only against a trusted share."
        }

        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }

        # Old computer name + timestamp keeps per-machine files distinct on a shared UNC (avoids concurrent-append contention).
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $file  = "Hostname-Rename_{0}_{1}.log" -f $env:COMPUTERNAME, $stamp
        $script:LOG_FILE = Join-Path $dir $file

        Write-Log -Level INFO -Message "Logging started. Host=$env:COMPUTERNAME LogFile=$script:LOG_FILE"

        # Retention housekeeping -- default directory only (see LOG_RETENTION_DAYS note).
        if ([string]::IsNullOrWhiteSpace($LogPath)) {
            Remove-OldLogFile -Directory $dir -RetentionDays $script:LOG_RETENTION_DAYS
        }
    } catch {
        Write-Warning "Could not initialise log (LogPath='$LogPath') -- continuing without a log file. $($_.Exception.Message)"
        $script:LOG_FILE = $null
    }
}

function Remove-OldLogFile {
    # Prunes run logs older than -RetentionDays from -Directory. Housekeeping only:
    # per the design rule above it never throws -- any failure degrades to "old logs
    # stay on disk", never to a blocked rename. Only files matching this tool's own
    # Hostname-Rename_*.log pattern are considered.
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$Directory,

        [ValidateRange(1, 3650)]
        [int]$RetentionDays = 30
    )

    try {
        if (-not (Test-Path -LiteralPath $Directory)) { return }

        $cutoff  = (Get-Date).AddDays(-$RetentionDays)
        $expired = @(
            Get-ChildItem -LiteralPath $Directory -Filter "Hostname-Rename_*.log" -File -ErrorAction Stop |
                Where-Object { $_.LastWriteTime -lt $cutoff }
        )

        $removed = 0
        foreach ($file in $expired) {
            if ($PSCmdlet.ShouldProcess($file.FullName, "Remove run log older than $RetentionDays days")) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                $removed++
            }
        }

        if ($removed -gt 0) {
            Write-Log -Level INFO -Message "Log retention: removed $removed run log(s) older than $RetentionDays days from '$Directory'."
        }
    } catch {
        # Never let housekeeping interfere with the run.
        Write-Verbose "Log retention skipped: $($_.Exception.Message)"
    }
}

function Write-Log {
    # Appends a timestamped line to the run log; no-op if uninitialised. Never throws or blocks.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'False positive: the analyzers core-6.1.0-windows compatibility profile lists a Write-Log cmdlet that does not exist on any PowerShell edition this project targets (ADR-005, no third-party modules; verified via Get-Command on PS 7.6 and Windows PowerShell 5.1).')]
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