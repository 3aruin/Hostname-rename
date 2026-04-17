# tools/Get-Hashes.ps1
#
# Run this locally after ANY change to the module files.
# Copy the output block into launcher.ps1's $MANIFEST, then commit and note the SHA.
#
# Usage:
#   cd YOUR_REPO_ROOT
#   .\tools\Get-Hashes.ps1

$files = @("network.ps1", "device.ps1", "naming.ps1", "rename.ps1")
$root  = Split-Path $PSScriptRoot -Parent

Write-Host ""
Write-Host "# Paste this block into launcher.ps1 -> `$MANIFEST"
Write-Host ""
Write-Host "`$MANIFEST = [ordered]@{"

foreach ($file in $files) {
    $path = Join-Path $root $file

    if (-not (Test-Path $path)) {
        Write-Warning "File not found, skipping: $path"
        continue
    }

    # Read raw bytes to match exactly what GitHub serves
    $content = Get-Content $path -Raw -Encoding UTF8
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($content)
    $hash    = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $hex     = ([BitConverter]::ToString($hash) -replace '-').ToLower()

    '    "{0}" = "{1}"' -f $file, $hex
}

Write-Host "}"
Write-Host ""
Write-Host "# Next steps:"
Write-Host "#   1. Replace `$COMMIT_SHA in launcher.ps1 with your new commit SHA"
Write-Host "#   2. Commit launcher.ps1 with the updated manifest"
Write-Host "#   3. Your iwr URL should pin to that commit SHA"
