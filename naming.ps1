# naming.ps1
# Handles: naming mode selection and device name construction
# Depends on: network.ps1 (Get-NetworkContext)

function Select-NamingMode {
    # Selects naming mode: Gateway (dept/type/serial) or User (location + profile name).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive prompt -- must write to host stream.')]
    param (
        [switch]$Folder,
        [switch]$Gateway,
        [switch]$NonInteractive,
        [string]$FolderPath,
        [string]$Username,
        [ValidateRange(1, 300)]
        [int]$PromptTimeoutSeconds = 8
    )

    if ($Folder)  { return "User" }
    if ($Gateway) { return "Gateway" }

    # -FolderPath / -Username imply User mode unless an explicit switch was given above.
    if ((-not [string]::IsNullOrWhiteSpace($FolderPath)) -or
        (-not [string]::IsNullOrWhiteSpace($Username))) {
        return "User"
    }

    if ($NonInteractive) { return "Gateway" }

    Write-Host ""
    Write-Host "Select naming mode:"
    Write-Host "  1. Gateway  (standard: dept / type / serial)"
    Write-Host "  2. User     (location + employee name)"
    Write-Host ""
    Write-Host "Press 1 or 2 -- defaulting to Gateway in $PromptTimeoutSeconds seconds..."

    # Poll [Console]::KeyAvailable -- Start-Job { Read-Host } can't read console input.
    $deadline = [DateTime]::Now.AddSeconds($PromptTimeoutSeconds)
    $keyChar  = $null

    try {
        while ([DateTime]::Now -lt $deadline) {
            if ([Console]::KeyAvailable) {
                $keyChar = ([Console]::ReadKey($true)).KeyChar.ToString()
                break
            }
            Start-Sleep -Milliseconds 200
        }
    } catch [System.InvalidOperationException] {
        # [Console]::KeyAvailable throws when stdin is not a real console (piped
        # input, some remoting hosts and RMM agents). Same outcome as the timeout:
        # the documented Gateway default, not a crash (BUG-018).
        Write-Host ""
        Write-Host "Console input is redirected -- defaulting to Gateway."
        return "Gateway"
    }

    if (-not $keyChar) {
        Write-Host ""
        Write-Host "No input received -- defaulting to Gateway."
        return "Gateway"
    }

    if ($keyChar -eq "2") { return "User" }
    return "Gateway"
}

function New-DeviceName {
    # Builds the Gateway-mode name {ORG}{WH}{LOC}-{Dept}{Type}-{Serial} (max 15 chars; drops Dept on overflow).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure string-builder; no state change. New- verb is correct.')]
    param (
        [string]$ORG,
        [string]$WH,
        [string]$LOC,
        [string]$Department,
        [string]$Type,
        [string]$Serial
    )

    $full      = "$ORG$WH$LOC-$Department$Type-$Serial"
    $shortened = "$ORG$WH$LOC-$Type-$Serial"

    if ($full.Length -le 15)      { return $full }
    if ($shortened.Length -le 15) {
        Write-Warning "Full name '$full' exceeded 15 chars -- department omitted: '$shortened'"
        return $shortened
    }

    throw "Device name '$shortened' still exceeds 15 characters. Review ORG/WH/LOC/Serial values."
}

function New-UserDeviceName {
    # Builds the User-mode name {WH}{LOC}-{Name} (max 15 chars).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure string-builder; no state change.')]
    param (
        [string]$WH,
        [string]$LOC,
        [string]$Name
    )

    $prefix = "$WH$LOC-"
    $result = "$prefix$Name"

    if ($result.Length -le 15) { return $result }

    # Safety truncation (Get-UserName should have already handled this)
    $maxName = 15 - $prefix.Length
    if ($maxName -le 0) {
        # Malformed GATEWAY_MAP values (oversized WH/LOC) would otherwise surface
        # as an ArgumentOutOfRange from Substring instead of an actionable error.
        throw "Prefix '$prefix' leaves no room for a user name within the 15-character limit. Review the WH/LOC values in GATEWAY_MAP."
    }
    $result = "$prefix$($Name.Substring(0, $maxName))"
    Write-Warning "Name truncated to fit 15-char limit: '$result'"
    return $result
}
