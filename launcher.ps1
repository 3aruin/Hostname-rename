# launcher.ps1
# Entry point -- run via:
#   iex (iwr "https://raw.githubusercontent.com/3aruin/Hostname-rename/COMMIT_SHA/launcher.ps1").Content
#
# With parameters:
#   & ([scriptblock]::Create(
#       (iwr "https://raw.githubusercontent.com/3aruin/Hostname-rename/COMMIT_SHA/launcher.ps1").Content
#   )) -NonInteractive -Gateway

[CmdletBinding()]
param (
    [switch]$Folder,
    [switch]$Gateway,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Config -------------------------------------------------------------------
# For production/MDM: replace REPLACE_WITH_COMMIT_SHA with a real commit SHA
# and fill in $MANIFEST hashes by running .\tools\Get-Hashes.ps1.
# See README.md -> Deployment Workflow for the full step-by-step.

$REPO_BASE  = "https://raw.githubusercontent.com/3aruin/Hostname-rename"
$COMMIT_SHA = "REPLACE_WITH_COMMIT_SHA"

$MODULES = @("network.ps1", "device.ps1", "naming.ps1", "rename.ps1")

# Expected SHA-256 hashes for each module.
# Regenerate with .\tools\Get-Hashes.ps1 after any change, then commit.
$MANIFEST = @{
    "network.ps1" = "REPLACE_WITH_HASH"
    "device.ps1"  = "REPLACE_WITH_HASH"
    "naming.ps1"  = "REPLACE_WITH_HASH"
    "rename.ps1"  = "REPLACE_WITH_HASH"
}
# -----------------------------------------------------------------------------

# -- Elevation ----------------------------------------------------------------
function Invoke-SelfElevation {
    <#
    .SYNOPSIS
        Relaunches the script as administrator if not already elevated.
    .PARAMETER FallbackUrl
        URL to re-download and invoke when running via iex (no $PSCommandPath).
    .PARAMETER ScriptParams
        The calling script's $PSBoundParameters hashtable, forwarded to the
        elevated process so all parameter values survive the relaunch.
    #>
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

    # Build argument list from the caller's bound parameters
    $argList = @()
    foreach ($entry in $ScriptParams.GetEnumerator()) {
        if ($entry.Value -is [switch]) {
            if ($entry.Value) { $argList += "-$($entry.Key)" }
        } elseif ($entry.Value -is [array]) {
            foreach ($val in $entry.Value) {
                $argList += "-$($entry.Key)"
                $argList += "$val"
            }
        } else {
            $argList += "-$($entry.Key)"
            $argList += "$($entry.Value)"
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
# -----------------------------------------------------------------------------

# Resolve the ref before elevation so the fallback URL is always correct
$ref = $COMMIT_SHA
if ($ref -eq "REPLACE_WITH_COMMIT_SHA") {
    Write-Warning "COMMIT_SHA is not set -- fetching modules from 'main'. Pin to a real commit SHA for production/MDM use."
    $ref = "main"
}

# Elevate if needed. The fallback URL re-downloads this launcher in the elevated
# session so iex-based runs survive the UAC hop without losing parameters.
$launcherUrl = "$REPO_BASE/$ref/launcher.ps1"
if (Invoke-SelfElevation -FallbackUrl $launcherUrl -ScriptParams $PSBoundParameters) {
    exit  # Non-elevated session exits; the new elevated session carries on
}

# Fetch, verify, and dot-source each module in dependency order
foreach ($FileName in $MODULES) {
    $url = "$REPO_BASE/$ref/$FileName"
    Write-Verbose "Fetching $FileName from $ref..."

    try {
        $content = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
    } catch {
        throw "Failed to fetch $FileName from $url`n$_"
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

# Hand off to the orchestrator
Rename-DeviceSmart `
    -Folder:$Folder `
    -Gateway:$Gateway `
    -NonInteractive:$NonInteractive
