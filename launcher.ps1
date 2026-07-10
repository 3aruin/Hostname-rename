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
    [string]$LogPath
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

    # Single-quote values (doubling embedded quotes) so a value with spaces survives both relaunch paths; names/switches stay unquoted.
    $argList = @()
    foreach ($entry in $ScriptParams.GetEnumerator()) {
        if ($entry.Value -is [switch]) {
            if ($entry.Value) { $argList += "-$($entry.Key)" }
        } elseif ($entry.Value -is [array]) {
            foreach ($val in $entry.Value) {
                $argList += "-$($entry.Key)"
                $argList += "'" + ("$val" -replace "'", "''") + "'"
            }
        } else {
            $argList += "-$($entry.Key)"
            $argList += "'" + ("$($entry.Value)" -replace "'", "''") + "'"
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
        ) + $argList

        $finalArgs = if ($processCmd -eq "wt.exe") {
            "$powershellCmd " + ($baseArgs -join ' ')
        } else {
            $baseArgs
        }

    } elseif ($FallbackUrl) {
        # Running via iex (irm 'url') -- re-download and invoke in elevated session
        $escapedUrl = $FallbackUrl -replace "'", "''"
        $command    = "iex (irm '$escapedUrl') $($argList -join ' ')"

        $finalArgs  = if ($processCmd -eq "wt.exe") {
            "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$command`""
        } else {
            "-ExecutionPolicy Bypass -NoProfile -Command `"$command`""
        }

    } else {
        throw "Cannot self-elevate: no script path or fallback URL provided."
    }

    Start-Process $processCmd -ArgumentList $finalArgs -Verb RunAs
    return $true
}

# Resolve the ref before elevation so the fallback URL is always correct
$ref = $COMMIT_SHA
if ($ref -eq "REPLACE_WITH_COMMIT_SHA") {
    Write-Warning "COMMIT_SHA is not set -- fetching modules from 'main'. Pin to a real commit SHA for production/MDM use."
    $ref = "main"
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
        (Invoke-WebRequest -Uri $u -UseBasicParsing).Content
    } -ArgumentList $url
}

# Collect in dependency order, verify hashes, then dot-source
foreach ($FileName in $MODULES) {
    Write-Verbose "Loading $FileName..."
    try {
        $content = Receive-Job $jobs[$FileName] -Wait -ErrorAction Stop
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
    -WhatIf:$WhatIfPreference
