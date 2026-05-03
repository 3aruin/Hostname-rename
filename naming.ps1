# naming.ps1
# Handles: naming mode selection and device name construction
# Depends on: network.ps1 (Get-NetworkContext)

function Select-NamingMode {
    <#
    .SYNOPSIS
        Determines whether to name the device by gateway (dept/type/serial) or
        by user profile (location + employee name).
        Explicit switches take priority. Interactive mode presents a 15-second
        timed prompt.

    .NOTES
        The timed prompt uses [Console]::KeyAvailable polling so it works
        correctly in a console session. Start-Job { Read-Host } cannot receive
        console input and must not be used here.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive mode-selection prompt — must write to host stream so output is not captured downstream')]
    param (
        [switch]$Folder,
        [switch]$Gateway,
        [switch]$NonInteractive
    )

    if ($Folder)         { return "User" }
    if ($Gateway)        { return "Gateway" }
    if ($NonInteractive) { return "Gateway" }

    Write-Host ""
    Write-Host "Select naming mode:"
    Write-Host "  1. Gateway  (standard: dept / type / serial)"
    Write-Host "  2. User     (location + employee name)"
    Write-Host ""
    Write-Host "Press 1 or 2 -- defaulting to Gateway in 8 seconds..."

    $deadline = [DateTime]::Now.AddSeconds(8)
    $keyChar  = $null

    while ([DateTime]::Now -lt $deadline) {
        if ([Console]::KeyAvailable) {
            $keyChar = ([Console]::ReadKey($true)).KeyChar.ToString()
            break
        }
        Start-Sleep -Milliseconds 200
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
    <#
    .SYNOPSIS
        Assembles the Gateway-mode device name from its components.

    .NOTES
        Format:  {ORG}{WH}{LOC}-{Dept}{Type}-{Serial}   (max 15 chars)
        If the full name exceeds 15 characters, the department segment is dropped:
                 {ORG}{WH}{LOC}-{Type}-{Serial}
        Throws if even the shortened form exceeds 15 characters.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure function — assembles a string from parameters and returns it. Does not change any system state. Verb New- is correct per Get-Verb (it produces a new value).')]
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
    <#
    .SYNOPSIS
        Assembles the User-mode device name from location and employee name.

    .NOTES
        Format:  {WH}{LOC}-{Name}   (max 15 chars)
        Example: 01R-JaneDoe
        Name is already truncated to 11 chars by Get-UserName, but a safety
        check is applied here as well.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure function — assembles a string from parameters and returns it. Does not change any system state.')]
    param (
        [string]$WH,
        [string]$LOC,
        [string]$Name
    )

    $prefix = "$WH$LOC-"
    $result = "$prefix$Name"

    if ($result.Length -le 15) { return $result }

    # Safety truncation (Get-UserName should have already handled this)
    $maxName  = 15 - $prefix.Length
    $result   = "$prefix$($Name.Substring(0, $maxName))"
    Write-Warning "Name truncated to fit 15-char limit: '$result'"
    return $result
}
