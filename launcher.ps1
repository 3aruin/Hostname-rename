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
    [string]$FolderPath   = "",
    [string]$Username     = "",
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

# If $COMMIT_SHA is still a placeholder, fall back to 'main' with a warning.
# Pin to a real SHA for any production or MDM deployment.
$ref = $COMMIT_SHA
if ($ref -eq "REPLACE_WITH_COMMIT_SHA") {
    Write-Warning "COMMIT_SHA is not set -- fetching modules from 'main'. Pin to a real commit SHA for production/MDM use."
    $ref = "main"
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
    -FolderPath $FolderPath `
    -Username $Username `
    -NonInteractive:$NonInteractive
