# launcher.ps1
# Entry point — run via:
#   iex (iwr "https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/COMMIT_SHA/launcher.ps1").Content
#
# With parameters:
#   & ([scriptblock]::Create((iwr "https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/COMMIT_SHA/launcher.ps1").Content)) -NonInteractive -Gateway

[CmdletBinding()]
param (
    [switch]$Folder,
    [switch]$Gateway,
    [string]$FolderPath  = "",
    [string]$Username    = "",
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Manifest ──────────────────────────────────────────────────────────────────
# IMPORTANT: Pin to a specific commit SHA — never point at 'main'.
# After every push, run tools/Get-Hashes.ps1 locally to regenerate hashes,
# update this block, commit, and use the new commit SHA in your iwr URL.

$REPO_BASE  = "https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO"
$COMMIT_SHA = "REPLACE_WITH_COMMIT_SHA"

$MANIFEST = [ordered]@{
    "network.ps1" = "REPLACE_WITH_SHA256"
    "device.ps1"  = "REPLACE_WITH_SHA256"
    "naming.ps1"  = "REPLACE_WITH_SHA256"
    "rename.ps1"  = "REPLACE_WITH_SHA256"
}
# ─────────────────────────────────────────────────────────────────────────────

function Get-VerifiedScript {
    param (
        [string]$FileName,
        [string]$ExpectedHash
    )

    $url = "$REPO_BASE/$COMMIT_SHA/$FileName"

    try {
        $content = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
    } catch {
        throw "Failed to fetch $FileName from $url`n$_"
    }

    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($content)
    $hash   = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $actual = ([BitConverter]::ToString($hash) -replace '-').ToLower()

    if ($actual -ne $ExpectedHash.ToLower()) {
        throw "HASH MISMATCH — $FileName`n  Expected : $ExpectedHash`n  Actual   : $actual`nAborting."
    }

    return $content
}

# Load and dot-source each verified module in dependency order
foreach ($file in $MANIFEST.Keys) {
    Write-Verbose "Verifying and loading $file..."
    $script = Get-VerifiedScript -FileName $file -ExpectedHash $MANIFEST[$file]
    . ([scriptblock]::Create($script))
}

# Hand off to the orchestrator
Rename-DeviceSmart `
    -Folder:$Folder `
    -Gateway:$Gateway `
    -FolderPath $FolderPath `
    -Username $Username `
    -NonInteractive:$NonInteractive
