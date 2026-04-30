# tools/Get-Hashes.ps1
# Regenerates SHA-256 hashes for all launcher modules.
# Run from the repo root after any change to module files, then paste the
# output into the $MANIFEST block in launcher.ps1.
#
# Usage:
#   .\tools\Get-Hashes.ps1

$modules = @("network.ps1", "device.ps1", "naming.ps1", "rename.ps1")
$repoRoot = Split-Path -Parent $PSScriptRoot

Write-Host ""
Write-Host "# Paste this block into the `$MANIFEST hashtable in launcher.ps1:"
Write-Host ""
Write-Host "`$MANIFEST = @{"

foreach ($file in $modules) {
    $path = Join-Path $repoRoot $file

    if (-not (Test-Path $path)) {
        Write-Warning "File not found, skipping: $path"
        continue
    }

    $content = Get-Content -Path $path -Raw -Encoding UTF8
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($content)
    $hash    = [System.BitConverter]::ToString(
                   [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
               ) -replace '-'

    '    "{0}" = "{1}"' -f $file, $hash
}

Write-Host "}"
Write-Host ""
Write-Host "Run this again after every change. Commit the updated launcher.ps1 alongside"
Write-Host "the changed module(s), then use the resulting commit SHA in your deployment URL."
