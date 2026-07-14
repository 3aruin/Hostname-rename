# tools/Get-Hashes.ps1
#
# Run this locally after ANY change to the module files.
# Copy the output block into launcher.ps1's $MANIFEST, then commit and note the SHA.
#
# Usage:
#   cd YOUR_REPO_ROOT
#   .\tools\Get-Hashes.ps1

$files = @("logging.ps1", "network.ps1", "device.ps1", "naming.ps1", "gui.ps1", "rename.ps1")
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

    # Hash the exact on-disk bytes (BUG-017). The launcher hashes the UTF-8 bytes
    # of the *downloaded string*, which equals the raw file bytes only while every
    # module is ASCII, BOM-free, and LF-normalized (.gitattributes pins *.ps1 to
    # LF, matching what raw.githubusercontent.com serves from a normalized repo).
    # Warn when a file breaks those assumptions instead of emitting a hash that
    # cannot match at runtime.
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Write-Warning "$file has a UTF-8 BOM -- the launcher's decoded-content hash will not match. Remove the BOM (repo policy is ASCII-only, no BOM)."
    }
    if ([System.Array]::IndexOf($bytes, [byte]13) -ge 0) {
        Write-Warning "$file contains CR (CRLF line endings) -- GitHub raw serves LF from a normalized repo, so this hash will not match at runtime. Normalize to LF and re-run (see .gitattributes)."
    }
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $hex  = ([BitConverter]::ToString($hash) -replace '-').ToLower()

    '    "{0}" = "{1}"' -f $file, $hex
}

"}"
""
"# Next steps:"
"#   1. Replace `$COMMIT_SHA in launcher.ps1 with your new commit SHA"
"#   2. Commit launcher.ps1 with the updated manifest"
"#   3. Your iwr URL should pin to that commit SHA"
