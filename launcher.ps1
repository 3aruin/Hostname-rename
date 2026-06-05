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
    Justification = 'False positive on the Start-Job ScriptBlock around line 150. The block uses param($u) plus -ArgumentList $url to pass the URL into the job, which is the idiomatic and preferred pattern. The analyzer cannot see that $u inside the script block is the param, not an outer-scope reference. Switching to $using: would be wrong here.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
    Justification = 'SupportsShouldProcess is declared so -WhatIf can be accepted through the iex/scriptblock deployment surface and forwarded to Rename-DeviceSmart, which owns the actual ShouldProcess gate on Rename-Computer. The launcher itself only fetches modules and self-elevates; the single state change (the rename) is gated downstream.')]
param (
    [switch]$Folder,
    [switch]$Gateway,
    [switch]$NonInteractive,
    [string]$FolderPath,
    [string]$Username,
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Config -------------------------------------------------------------------
# For production/MDM: replace REPLACE_WITH_COMMIT_SHA with a real commit SHA
# and fill in $MANIFEST hashes by running .\tools\Get-Hashes.ps1.
# See README.md -> Deployment Workflow for the full step-by-step.

$REPO_BASE  = "https://raw.githubusercontent.com/3aruin/Hostname-rename"
$COMMIT_SHA = "REPLACE_WITH_COMMIT_SHA"

# logging.ps1 loads first so the orchestrator can log throughout the run.
$MODULES = @("logging.ps1", "network.ps1", "device.ps1", "naming.ps1", "rename.ps1")

# Expected SHA-256 hashes for each module.
# Regenerate with .\tools\Get-Hashes.ps1 after any change, then commit.
# (Ordered to match Get-Hashes.ps1 output for a clean paste.)
$MANIFEST = [ordered]@{
    "logging.ps1" = "REPLACE_WITH_HASH"
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

    # Build argument list from the caller's bound parameters. Parameter names and
    # bare switches stay unquoted; VALUES are single-quoted (and embedded quotes
    # doubled) so a value containing spaces -- e.g. -FolderPath "D:\User Profiles"
    # -- survives both the array (-File) and string (-Command / wt.exe) relaunch
    # paths intact.
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

# Kick off all module fetches simultaneously
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

# Hand off to the orchestrator. -WhatIf:$WhatIfPreference forwards a launcher-level
# dry run down to where the ShouldProcess gate actually lives.
Rename-DeviceSmart `
    -Folder:$Folder `
    -Gateway:$Gateway `
    -NonInteractive:$NonInteractive `
    -FolderPath $FolderPath `
    -Username $Username `
    -LogPath $LogPath `
    -WhatIf:$WhatIfPreference
