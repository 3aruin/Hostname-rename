# device.ps1
# Handles: department selection, device type detection, serial number retrieval,
#          and user profile name resolution (for User naming mode)

# -- Valid values
$script:VALID_DEPARTMENTS = @("CS", "SR", "OP", "HQ", "IT", "WS")
$script:DEVICE_TYPES      = @("VM", "SV", "MD", "ET", "LT", "DT", "PB", "TB")

function Get-Department {
    # Prompts for a valid department code; returns "WS" in NonInteractive mode.
    param (
        [switch]$NonInteractive
    )

    if ($NonInteractive) { return "WS" }

    # Bounded retries: on exhausted/redirected stdin Read-Host returns "" forever,
    # which previously spun this loop for eternity (F-08.4).
    $attempts = 0
    do {
        if (++$attempts -gt 10) {
            throw "No valid department code after 10 attempts (is console input redirected?). Use -NonInteractive, or enter one of: $($script:VALID_DEPARTMENTS -join ', ')."
        }
        $raw  = Read-Host "Department ($($script:VALID_DEPARTMENTS -join ', '))"
        $dept = $raw.ToUpper().Trim()
    } until ($script:VALID_DEPARTMENTS -contains $dept)

    return $dept
}

function Resolve-DeviceType {
    # Pure, unit-testable: maps collected WMI values to a device-type code via the priority chain below.
    # SV before the chassis tests so a server OS always wins; TB before MD so an ARM convertible keeps its form factor.
    param (
        [string]$Model,
        [int]$ProductType  = 1,
        [int]$Architecture = -1,
        [int[]]$ChassisTypes = @()
    )

    if ($Model -match "Virtual")                                  { return "VM" }
    if ($ProductType -ne 1)                                       { return "SV" }
    if ($ChassisTypes -contains 30 -or $ChassisTypes -contains 31) { return "TB" }
    if ($Architecture -eq 5)                                      { return "MD" }
    # Chassis 9 (Laptop) / 10 (Notebook) is the authoritative LT signal; the
    # Model substring stays as a fallback for firmware that reports chassis 3/etc.
    if ($ChassisTypes -contains 9 -or $ChassisTypes -contains 10) { return "LT" }
    if ($Model -match "Laptop")                                   { return "LT" }
    if ($ChassisTypes -contains 5)                                { return "PB" }
    return "DT"
}

function Get-DeviceType {
    # Auto-detects device type from WMI (sequential CIM queries -> Resolve-DeviceType), then allows an interactive override.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive prompt header paired with Read-Host -- must write to host, not the success stream.')]
    param (
        [switch]$NonInteractive,
        # A previously detected type (e.g. rename.ps1's pre-GUI probe) -- skips the
        # WMI queries so a GUI-fallback run does not pay the detection cost twice
        # (F-08.6); the interactive override prompt below still runs either way.
        [string]$Detected
    )

    $type = "DT"

    if ($Detected -and $script:DEVICE_TYPES -contains $Detected) {
        $type = $Detected
    } else {
        try {
            # Sequential on purpose: Get-CimInstance has no -AsJob parameter on any
            # PowerShell edition (BUG-015 -- the previous "parallel" calls threw a
            # binding error and every device silently detected as DT). Each local
            # query is tens of milliseconds; parallelism buys nothing here.
            $os  = Get-CimInstance Win32_OperatingSystem
            $cs  = Get-CimInstance Win32_ComputerSystem
            $cpu = Get-CimInstance Win32_Processor
            $enc = Get-CimInstance Win32_SystemEnclosure

            # Win32_SystemEnclosure may return multiple instances; flatten. @() keeps it an array even if $enc is $null (StrictMode-safe).
            $chassis = @($enc | ForEach-Object { $_.ChassisTypes })

            $type = Resolve-DeviceType `
                -Model        $cs.Model `
                -ProductType  ([int]$os.ProductType) `
                -Architecture ([int]$cpu.Architecture) `
                -ChassisTypes ([int[]]$chassis)
        } catch {
            # Surface the real error -- a generic message is how BUG-015 masqueraded
            # as a WMI failure for three releases.
            Write-Warning "Device type detection failed -- defaulting to DT. ($($_.Exception.Message))"
        }
    }

    if (-not $NonInteractive) {
        Write-Host "Detected device type: $type"
        $raw = Read-Host "Override? Press Enter to accept, or enter a type ($($script:DEVICE_TYPES -join ', '))"
        if ($raw -and $script:DEVICE_TYPES -contains $raw.ToUpper()) {
            $type = $raw.ToUpper()
        }
    }

    return $type
}

function ConvertTo-SerialLast4 {
    # Cleans a serial and returns its last 4 alphanumerics, left-padded with zeros if fewer than 4 remain. WMI-free.
    param (
        [string]$Serial
    )

    $clean = ($Serial -replace '[^A-Za-z0-9]', '').ToUpper()

    if ($clean.Length -ge 4) {
        return $clean.Substring($clean.Length - 4)
    }

    return $clean.PadLeft(4, '0')
}

function Get-SerialLast4 {
    # Last 4 alphanumerics of the BIOS serial; cleaning/padding in ConvertTo-SerialLast4.
    $serial = (Get-CimInstance Win32_BIOS).SerialNumber
    return ConvertTo-SerialLast4 -Serial $serial
}

function ConvertTo-CleanUserName {
    # Cleans a profile folder name into a device-name-safe token: strips Entra UPN suffix at @ or _, drops non-alphanumerics.
    # Truncates to 11 -- the max that fits {WH}{LOC}-{NAME} within 15 chars. Throws if nothing remains.
    param (
        [string]$Name
    )

    $clean = $Name
    foreach ($sep in '@', '_') {
        $idx = $clean.IndexOf($sep)
        if ($idx -gt 0) { $clean = $clean.Substring(0, $idx) }
    }

    $clean = ($clean -replace '[^a-zA-Z0-9]', '')

    if ($clean.Length -eq 0) {
        throw "Profile name '$Name' produced an empty string after cleaning. Rename the profile folder or use Gateway mode."
    }

    return $clean.Substring(0, [Math]::Min(11, $clean.Length))
}

function Get-UserName {
    # Selects a profile folder and returns its cleaned name (via ConvertTo-CleanUserName).
    # -FolderPath overrides the C:\Users search root; -Username partial-matches candidates (interactive lists matches, NonInteractive picks the most recently active).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive numbered profile list paired with Read-Host -- must write to host, not the success stream.')]
    param (
        [switch]$NonInteractive,
        [string]$FolderPath,
        [string]$Username
    )

    $root = if ([string]::IsNullOrWhiteSpace($FolderPath)) { "C:\Users" } else { $FolderPath }

    if (-not (Test-Path -LiteralPath $root)) {
        throw "Profile search path '$root' does not exist. Check -FolderPath or use Gateway mode."
    }

    # Windows system profile folders -- never valid user names
    $systemFolders = @(
        "Public", "Default", "DefaultAppPool", "defaultuser0",
        "Administrator", "Guest", "WDAGUtilityAccount"
    )

    # @() forces an array even when Get-ChildItem returns one object; .Count would otherwise throw under StrictMode.
    $profiles = @(
        Get-ChildItem -LiteralPath $root -Directory |
            Where-Object { $_.Name -notin $systemFolders } |
            Sort-Object  LastWriteTime -Descending
    )

    if ($profiles.Count -eq 0) {
        throw "No user profile folders found under '$root'."
    }

    if (-not [string]::IsNullOrWhiteSpace($Username)) {
        # Escape wildcard metacharacters so -Username is matched as a literal substring,
        # not a pattern (a '*'/'?'/'[' in the value would otherwise match unintended profiles).
        $pattern  = "*" + [System.Management.Automation.WildcardPattern]::Escape($Username) + "*"
        $profiles = @($profiles | Where-Object { $_.Name -like $pattern })
        if ($profiles.Count -eq 0) {
            throw "No profile folder under '$root' matches -Username '$Username'."
        }
    }

    if ($NonInteractive) {
        $selected = $profiles[0].Name
        Write-Host "Auto-selected profile: $selected"
    } else {
        Write-Host ""
        Write-Host "Select user:"
        for ($i = 0; $i -lt $profiles.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $profiles[$i].Name)
        }
        Write-Host ""

        # Bounded retries, same rationale as Get-Department (F-08.4).
        $attempts = 0
        do {
            if (++$attempts -gt 10) {
                throw "No valid profile selection after 10 attempts (is console input redirected?). Use -NonInteractive or -Username."
            }
            $choice = Read-Host "User number"
        } until ($choice -as [int] -and [int]$choice -ge 1 -and [int]$choice -le $profiles.Count)

        $selected = $profiles[[int]$choice - 1].Name
    }

    return ConvertTo-CleanUserName -Name $selected
}