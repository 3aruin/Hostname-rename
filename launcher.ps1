# launcher.ps1
# Entry point â€” run via:
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

# â”€â”€ Config â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# IMPORTANT: Pin to a specific commit SHA â€” never point at 'main'.
# Update $COMMIT_SHA here after every push, then commit and use the new SHA
# in your iwr URL.

$REPO_BASE  = "https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO"
$COMMIT_SHA = "REPLACE_WITH_COMMIT_SHA"

$MODULES = @("network.ps1", "device.ps1", "naming.ps1", "rename.ps1")
# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

# Fetch and dot-source each module in dependency order
foreach ($file in $MODULES) {
    $url = "$REPO_BASE/$COMMIT_SHA/$file"
    Write-Verbose "Loading $file..."
    try {
        $content = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
    } catch {
        throw "Failed to fetch $file from $url`n$_"
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
