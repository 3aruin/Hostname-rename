# launcher.ps1
# Entry point -- run via:
#   iex (iwr "https://raw.githubusercontent.com/3aruin/Hostname-rename/COMMIT_SHA/launcher.ps1").Content
#
# With parameters:
#   & ([scriptblock]::Create(
#       (iwr "https://raw.githubusercontent.com/3aruin/Hostname-rename/COMMIT_SHA/launcher.ps1").Content
#   )) -NonInteractive -Gateway

[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
    Justification = 'Start-Job block takes $u via param()/-ArgumentList; $using: would be wrong here.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
    Justification = 'Launcher only fetches/elevates; -WhatIf is forwarded to Rename-DeviceSmart, which owns the ShouldProcess gate.')]
param (
    [switch]$Folder,
    [switch]$Gateway,
    [switch]$NonInteractive,
    [switch]$Gui,
    [string]$FolderPath,
    [string]$Username,
    [string]$LogPath,
    [ValidateRange(1, 300)]
    [int]$PromptTimeoutSeconds = 8,
    [switch]$AllowUnverified
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Config --
# Production/MDM: set $COMMIT_SHA to a real SHA and fill $MANIFEST via .\tools\Get-Hashes.ps1 (see README -> Deployment Workflow).
$REPO_BASE  = "https://raw.githubusercontent.com/3aruin/Hostname-rename"
$COMMIT_SHA = "REPLACE_WITH_COMMIT_SHA"

# logging.ps1 loads first so the orchestrator can log throughout the run.
# gui.ps1 loads after naming.ps1 (its live preview calls the name builders)
# and before rename.ps1 (which calls Show-RenameGui).
$MODULES = @("logging.ps1", "network.ps1", "device.ps1", "naming.ps1", "gui.ps1", "rename.ps1")

# SHA-256 per module; regenerate via .\tools\Get-Hashes.ps1 after any change. [ordered] matches its output for a clean paste.
$MANIFEST = [ordered]@{
    "logging.ps1" = "REPLACE_WITH_HASH"
    "network.ps1" = "REPLACE_WITH_HASH"
    "device.ps1"  = "REPLACE_WITH_HASH"
    "naming.ps1"  = "REPLACE_WITH_HASH"
    "gui.ps1"     = "REPLACE_WITH_HASH"
    "rename.ps1"  = "REPLACE_WITH_HASH"
}

# -- Elevation --
function Invoke-SelfElevation {
    # Relaunch as admin if not already elevated; bound params are forwarded so they survive the relaunch.
    [CmdletBinding()]
    param(
        [string]$FallbackUrl,
        [hashtable]$ScriptParams = @{}
    )

    $isAdmin = ([Security.Principal.WindowsPrincipal] (
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) { return $false }

    Write-Verbose "Elevation required. Relaunching as Administrator..."

    # A literal double-quote in a value would terminate the outer -Command "..." string
    # on the iex relaunch path (a command-line break), and single-quoting cannot
    # neutralise it there. Windows paths, usernames, and the allow-listed dept/type
    # tokens never legitimately contain ", so refuse rather than emit a broken/
    # injectable relaunch command (SEC-003).
    $rejectQuote = {
        param($key, $value)
        if ("$value" -match '"') {
            throw "Refusing to forward -$key across the elevation relaunch: value contains a double-quote, which cannot be safely escaped."
        }
    }

    # Values are quoted PER RELAUNCH PATH (BUG-014). The -File path goes through the
    # native command line, where double quotes group arguments and single quotes are
    # LITERAL -- single-quoted values arrived quote-wrapped (and split on spaces), and
    # non-string parameters failed to bind. The iex path is spliced into a
    # -Command "..." string, where single quotes are the safe wrapper (embedded '
    # doubled; embedded " already refused above). Names/switches stay unquoted.
    $fileArgs = @()   # tokens for the -File relaunch:  "value"
    $iexArgs  = @()   # tokens for the iex relaunch:    'value'
    foreach ($entry in $ScriptParams.GetEnumerator()) {
        if ($entry.Value -is [switch]) {
            if ($entry.Value) {
                $fileArgs += "-$($entry.Key)"
                $iexArgs  += "-$($entry.Key)"
            }
            continue
        }
        $values = if ($entry.Value -is [array]) { $entry.Value } else { @($entry.Value) }
        foreach ($val in $values) {
            & $rejectQuote $entry.Key $val
            $fileArgs += "-$($entry.Key)"
            $fileArgs += "`"$val`""
            $iexArgs  += "-$($entry.Key)"
            $iexArgs  += "'" + ("$val" -replace "'", "''") + "'"
        }
    }

    $powershellCmd = if (Get-Command pwsh   -ErrorAction SilentlyContinue) { "pwsh"   } else { "powershell" }
    $processCmd    = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { $powershellCmd }

    if ($PSCommandPath) {
        # Running from a saved .ps1 file -- relaunch the file directly
        $baseArgs = @(
            "-ExecutionPolicy", "Bypass",
            "-NoProfile",
            "-File", "`"$PSCommandPath`""
        ) + $fileArgs

        $finalArgs = if ($processCmd -eq "wt.exe") {
            # wt.exe splits its command line into panes on ';' -- escape as '\;'
            # (wt's own escape) so a script path containing a semicolon survives
            # the relaunch (F-08.5, noted alongside the SEC-003 quote refusal).
            ("$powershellCmd " + ($baseArgs -join ' ')) -replace ';', '\;'
        } else {
            $baseArgs
        }

    } elseif ($FallbackUrl) {
        # Running via iex (irm 'url') -- re-download and invoke in elevated session.
        # Invoked as a scriptblock, NOT "iex (...) <args>": Invoke-Expression takes a
        # single -Command argument, so any token spliced after it is a parameter-binding
        # error, never an argument to the downloaded script (BUG-016). This is the same
        # form the header comment documents for parameterized one-liners.
        $escapedUrl = $FallbackUrl -replace "'", "''"
        $command    = "& ([scriptblock]::Create((irm '$escapedUrl'))) $($iexArgs -join ' ')"

        $finalArgs  = if ($processCmd -eq "wt.exe") {
            # Same wt.exe ';' escape as the -File path (F-08.5) -- a URL or
            # forwarded value containing a semicolon must not split into panes.
            ("$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$command`"") -replace ';', '\;'
        } else {
            "-ExecutionPolicy Bypass -NoProfile -Command `"$command`""
        }

    } else {
        throw "Cannot self-elevate: no script path or fallback URL provided."
    }

    try {
        Start-Process $processCmd -ArgumentList $finalArgs -Verb RunAs
    } catch {
        # Most common cause: the operator clicked "No" on the UAC consent prompt
        # (ERROR_CANCELLED). Surface an instruction instead of the raw exception --
        # under wt.exe the elevated window closes before a raw error can be read (F-08.1).
        throw ("Elevation was declined or failed ($($_.Exception.Message)). " +
               "This tool needs administrator rights to rename the computer -- " +
               "accept the UAC prompt, or re-run from an already-elevated PowerShell session.")
    }
    return $true
}

# Resolve the ref before elevation so the fallback URL is always correct
$ref = $COMMIT_SHA
if ($ref -eq "REPLACE_WITH_COMMIT_SHA") {
    # Unpinned: modules would be fetched from 'main' and, because every $MANIFEST entry
    # is still a placeholder, dot-sourced into an ELEVATED process with NO hash check --
    # i.e. run-as-admin of whatever 'main' currently holds, no integrity guarantee. That is
    # not a safe default, so it is refused unless the operator explicitly opts in. A real
    # deployment pins $COMMIT_SHA and fills $MANIFEST (README -> Deployment Workflow), so
    # this guard never fires for production/MDM -- only for the unconfigured/dev state.
    if (-not $AllowUnverified) {
        throw (
            "COMMIT_SHA is not set. This launcher would fetch modules from 'main' with no hash " +
            "verification and run them elevated. Refusing by default. Pin a real 40-character " +
            "commit SHA and fill `$MANIFEST via .\tools\Get-Hashes.ps1 for production/MDM use, or " +
            "pass -AllowUnverified to fetch from 'main' without hash checks (development only, " +
            "against a repo you trust)."
        )
    }
    Write-Warning "COMMIT_SHA is not set and -AllowUnverified was given -- fetching modules from 'main' WITHOUT hash verification. Development use only; do not use for production/MDM."
    $ref = "main"
}

# Fail closed on a mixed manifest: once a real SHA is pinned (production/MDM), every
# module must have a real hash. A placeholder entry alongside a pinned SHA means the
# manifest was only half-regenerated -- that module would load UNVERIFIED (its hash
# check is skipped below) while the rest are verified, a silent partial-integrity gap.
# Skipped when $ref is 'main' (the dev/canonical template state, hashes not yet filled).
if ($ref -ne "main") {
    $placeholders = @($MANIFEST.GetEnumerator() | Where-Object { $_.Value -eq "REPLACE_WITH_HASH" } |
                        Select-Object -ExpandProperty Key)
    if ($placeholders.Count -gt 0) {
        throw ("Pinned to commit '$ref' but $($placeholders.Count) manifest entr(y/ies) still hold REPLACE_WITH_HASH " +
               "($($placeholders -join ', ')). Re-run .\tools\Get-Hashes.ps1 and paste the full block before deploying. " +
               "Halting -- a pinned deployment must verify every module, not just some.")
    }
}

# Elevate if needed; the fallback URL re-downloads this launcher so iex runs survive the UAC hop with their params.
$launcherUrl = "$REPO_BASE/$ref/launcher.ps1"
if (Invoke-SelfElevation -FallbackUrl $launcherUrl -ScriptParams $PSBoundParameters) {
    exit  # Non-elevated session exits; the elevated one carries on
}

# Fetch all modules in parallel
$jobs = [ordered]@{}
foreach ($FileName in $MODULES) {
    $url = "$REPO_BASE/$ref/$FileName"
    Write-Verbose "Queuing fetch: $FileName"
    $jobs[$FileName] = Start-Job -ScriptBlock {
        param($u)
        # -TimeoutSec bounds the transfer: iwr's default is no timeout at all, so a
        # stalled connection used to hang an unattended MDM run forever (BUG-020).
        (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 60).Content
    } -ArgumentList $url
}

# Collect in dependency order, verify hashes, then dot-source
foreach ($FileName in $MODULES) {
    Write-Verbose "Loading $FileName..."
    try {
        # Bounded wait (BUG-020): belt to the in-job -TimeoutSec's braces -- if the
        # job itself wedges, Receive-Job -Wait would still block forever.
        if (-not (Wait-Job $jobs[$FileName] -Timeout 90)) {
            throw "Timed out after 90 seconds waiting for the download job."
        }
        $content = Receive-Job $jobs[$FileName] -ErrorAction Stop
    } catch {
        throw "Failed to fetch $FileName from $REPO_BASE/$ref/$FileName`n$_"
    } finally {
        # -WhatIf:$false so a launcher-level dry run still tidies its fetch jobs.
        Remove-Job $jobs[$FileName] -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }

    # Integrity check -- skipped when manifest entry is still a placeholder
    $expected = $MANIFEST[$FileName]
    if ($expected -and $expected -ne "REPLACE_WITH_HASH") {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
        $hash  = [System.BitConverter]::ToString(
                     [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
                 ) -replace '-'
        if ($hash -ne $expected) {
            throw "Hash mismatch for $FileName -- expected $expected, got $hash. Re-run .\tools\Get-Hashes.ps1 and update the manifest."
        }
        Write-Verbose "$FileName hash OK."
    }

    . ([scriptblock]::Create($content))
}

# Hand off to the orchestrator; -WhatIf:$WhatIfPreference forwards a dry run to the ShouldProcess gate downstream.
Rename-DeviceSmart `
    -Folder:$Folder `
    -Gateway:$Gateway `
    -NonInteractive:$NonInteractive `
    -Gui:$Gui `
    -FolderPath $FolderPath `
    -Username $Username `
    -LogPath $LogPath `
    -PromptTimeoutSeconds $PromptTimeoutSeconds `
    -WhatIf:$WhatIfPreference
