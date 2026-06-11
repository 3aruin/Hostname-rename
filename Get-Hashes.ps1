# tools/Get-Hashes.ps1
# Regenerates the $MANIFEST block for launcher.ps1 after any module change.
# Run from the repo root: .\tools\Get-Hashes.ps1

$files = @("logging.ps1", "network.ps1", "device.ps1", "naming.ps1", "rename.ps1")
$root  = Split-Path $PSScriptRoot -Parent

""
"# Paste this block into launcher.ps1 -> `$MANIFEST"
""
"`$MANIFEST = [ordered]@{"

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

"}"
""
"# Next steps:"
"#   1. Replace `$COMMIT_SHA in launcher.ps1 with your new commit SHA"
"#   2. Commit launcher.ps1 with the updated manifest"
"#   3. Your iwr URL should pin to that commit SHA"