# device.ps1
# Handles: department selection, device type detection, serial number retrieval,
#          and user profile name resolution (for User naming mode)

# -- Valid Values -------------------------------------------------------------
# Extend these arrays as new departments or device classes are introduced.

$script:VALID_DEPARTMENTS = @("CS", "SR", "OP", "HQ", "IT", "WS")
$script:DEVICE_TYPES      = @("VM", "SV", "MD", "ET", "LT", "DT", "PB", "TB")
# -----------------------------------------------------------------------------

function Get-Department {
    <#
    .SYNOPSIS
        Prompts the user to enter a valid department code.
        Returns "WS" immediately in NonInteractive mode.
    #>
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
    <#
    .SYNOPSIS
        Pure decision logic that maps already-collected WMI values to a device
        type code. WMI-free and unit-testable -- Get-DeviceType collects the
        inputs, this function owns the priority chain.

    .NOTES
        Priority order (first match wins):
          VM  Model contains "Virtual"
          SV  ProductType is not 1 (not a Workstation OS)
          TB  ChassisTypes contains 30 (Tablet) or 31 (Convertible)
          MD  Architecture is 5 (ARM)
          LT  Model contains "Laptop"
          PB  ChassisTypes contains 5 (Pizza Box)
          DT  default fallback

        TB is checked before MD so an ARM convertible (e.g. some Surface models)
        is recorded by its more descriptive form factor. SV is checked before the
        chassis tests so a server OS always wins regardless of enclosure.
    #>
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
    <#
    .SYNOPSIS
        Auto-detects device type from WMI, then optionally allows an override.

    .NOTES
        Fires four CIM queries in parallel and hands the results to
        Resolve-DeviceType (which owns the priority chain). The WMI objects in
        scope for any new detection logic are:
          $os  Win32_OperatingSystem  -- ProductType, Caption
          $cs  Win32_ComputerSystem   -- Model, PCSystemType
          $cpu Win32_Processor        -- Architecture
          $enc Win32_SystemEnclosure  -- ChassisTypes

        All jobs are captured into $jobs before the try block so the finally
        clause can always clean them up, even if a query throws mid-flight.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive prompt header -- must write to host so output is not captured downstream when paired with Read-Host')]
    param (
        [switch]$NonInteractive
    )

    $type = "DT"    # default
    $jobs = @()     # declared outside try so finally can always reference it

    try {
        # Fire all CIM queries simultaneously -- cuts detection time substantially
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

        # Win32_SystemEnclosure may return more than one instance; flatten the
        # ChassisTypes arrays into a single list. @() keeps it an array even when
        # $enc is $null, which would otherwise throw under Set-StrictMode -Latest.
        $chassis = @($enc | ForEach-Object { $_.ChassisTypes })

        $type = Resolve-DeviceType `
            -Model        $cs.Model `
            -ProductType  ([int]$os.ProductType) `
            -Architecture ([int]$cpu.Architecture) `
            -ChassisTypes ([int[]]$chassis)
    } catch {
        Write-Warning "WMI query failed during device type detection -- defaulting to DT."
    } finally {
        # Clean up all job objects regardless of how the try block exited
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
    <#
    .SYNOPSIS
        Cleans a raw serial string and returns its last 4 alphanumeric
        characters, left-padded with zeros when fewer than 4 remain.
        WMI-free and unit-testable.
    #>
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
    <#
    .SYNOPSIS
        Returns the last 4 alphanumeric characters of the BIOS serial number.
        The cleaning/padding logic lives in ConvertTo-SerialLast4 so it can be
        tested without a real device.
    #>
    $serial = (Get-CimInstance Win32_BIOS).SerialNumber
    return ConvertTo-SerialLast4 -Serial $serial
}

function ConvertTo-CleanUserName {
    <#
    .SYNOPSIS
        Cleans a profile folder name into a device-name-safe token.
        WMI/filesystem-free and unit-testable.

    .NOTES
        Steps:
          1. Strip from the first @ or _ onward
             (Entra UPN suffixes: jane.doe@contoso.com, JaneDoe_contoso.com)
          2. Remove any remaining non-alphanumeric characters
             (also removes dots: jane.doe -> janedoe)
          3. Truncate to 11 characters
             (maximum that fits {WH}{LOC}-{NAME} within the 15-char limit)
        Throws if cleaning leaves an empty string.
    #>
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
    <#
    .SYNOPSIS
        Selects a profile folder and returns its cleaned name (via
        ConvertTo-CleanUserName) for use in a device name.

    .NOTES
        Search path defaults to C:\Users; override with -FolderPath (e.g. a
        redirected-profiles location). -Username narrows the candidates by
        case-insensitive partial match:
          - Interactive    : the filtered list is shown to choose from.
          - NonInteractive : the most recently active match is chosen.
        With no -Username, NonInteractive picks the most recently active profile
        overall. Name cleaning is delegated to ConvertTo-CleanUserName so the
        logic is unit-tested without touching the filesystem.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive numbered profile list -- must write to host so output is not captured downstream when paired with Read-Host')]
    param (
        [switch]$NonInteractive,
        [string]$FolderPath,
        [string]$Username
    )

    $root = if ([string]::IsNullOrWhiteSpace($FolderPath)) { "C:\Users" } else { $FolderPath }

    if (-not (Test-Path -LiteralPath $root)) {
        throw "Profile search path '$root' does not exist. Check -FolderPath or use Gateway mode."
    }

    # Well-known Windows system profile folders that are never valid user names
    $systemFolders = @(
        "Public", "Default", "DefaultAppPool", "defaultuser0",
        "Administrator", "Guest", "WDAGUtilityAccount"
    )

    # @() forces an array even when Get-ChildItem returns a single object,
    # which would otherwise cause .Count to throw under Set-StrictMode -Version Latest
    $profiles = @(
        Get-ChildItem -Path $root -Directory |
            Where-Object { $_.Name -notin $systemFolders } |
            Sort-Object  LastWriteTime -Descending
    )

    if ($profiles.Count -eq 0) {
        throw "No user profile folders found under '$root'."
    }

    # Narrow by -Username (case-insensitive partial match) when supplied
    if (-not [string]::IsNullOrWhiteSpace($Username)) {
        $profiles = @($profiles | Where-Object { $_.Name -like "*$Username*" })
        if ($profiles.Count -eq 0) {
            throw "No profile folder under '$root' matches -Username '$Username'."
        }
    }

    if ($NonInteractive) {
        # Most recently active (of the matches, if -Username narrowed the set)
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
