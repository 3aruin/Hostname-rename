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

    do {
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
    if ($Model -match "Laptop")                                   { return "LT" }
    if ($ChassisTypes -contains 5)                                { return "PB" }
    return "DT"
}

function Get-DeviceType {
    # Auto-detects device type from WMI (parallel CIM queries -> Resolve-DeviceType), then allows an interactive override.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive prompt header paired with Read-Host -- must write to host, not the success stream.')]
    param (
        [switch]$NonInteractive
    )

    $type = "DT"
    $jobs = @()     # declared before try so finally can always reach it

    try {
        $jobs = @(
            (Get-CimInstance Win32_OperatingSystem -AsJob),
            (Get-CimInstance Win32_ComputerSystem  -AsJob),
            (Get-CimInstance Win32_Processor       -AsJob),
            (Get-CimInstance Win32_SystemEnclosure -AsJob)
        )

        $os  = $jobs[0] | Wait-Job | Receive-Job
        $cs  = $jobs[1] | Wait-Job | Receive-Job
        $cpu = $jobs[2] | Wait-Job | Receive-Job
        $enc = $jobs[3] | Wait-Job | Receive-Job

        # Win32_SystemEnclosure may return multiple instances; flatten. @() keeps it an array even if $enc is $null (StrictMode-safe).
        $chassis = @($enc | ForEach-Object { $_.ChassisTypes })

        $type = Resolve-DeviceType `
            -Model        $cs.Model `
            -ProductType  ([int]$os.ProductType) `
            -Architecture ([int]$cpu.Architecture) `
            -ChassisTypes ([int[]]$chassis)
    } catch {
        Write-Warning "WMI query failed during device type detection -- defaulting to DT."
    } finally {
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
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
        Get-ChildItem -Path $root -Directory |
            Where-Object { $_.Name -notin $systemFolders } |
            Sort-Object  LastWriteTime -Descending
    )

    if ($profiles.Count -eq 0) {
        throw "No user profile folders found under '$root'."
    }

    if (-not [string]::IsNullOrWhiteSpace($Username)) {
        $profiles = @($profiles | Where-Object { $_.Name -like "*$Username*" })
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

        do {
            $choice = Read-Host "User number"
        } until ($choice -as [int] -and [int]$choice -ge 1 -and [int]$choice -le $profiles.Count)

        $selected = $profiles[[int]$choice - 1].Name
    }

    return ConvertTo-CleanUserName -Name $selected
}