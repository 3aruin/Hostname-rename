# device.ps1
# Handles: department selection, device type detection, serial number retrieval,
#          and user profile name resolution (for User naming mode)

# -- Valid Values -------------------------------------------------------------
# Extend these arrays as new departments or device classes are introduced.

$script:VALID_DEPARTMENTS = @("CS", "SR", "OP", "HQ", "IT", "WS")
$script:DEVICE_TYPES      = @("VM", "SV", "MD", "ET", "LT", "DT")
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

function Get-DeviceType {
    <#
    .SYNOPSIS
        Auto-detects device type from WMI, then optionally allows an override.

    .NOTES
        Detection order:
          Virtual Machine  -- Win32_ComputerSystem.Model contains "Virtual"
          Server           -- Win32_OperatingSystem.ProductType is not 1 (Workstation)
          Mobile/ARM       -- Win32_Processor.Architecture eq 5 (ARM)
          Laptop           -- Win32_ComputerSystem.Model contains "Laptop"
          Desktop          -- default fallback
    #>
    param (
        [switch]$NonInteractive
    )

    $type = "DT"    # default

    try {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        $cpu = Get-CimInstance Win32_Processor

        if    ($cs.Model       -match "Virtual") { $type = "VM" }
        elseif ($os.ProductType -ne 1)           { $type = "SV" }
        elseif ($cpu.Architecture -eq 5)         { $type = "MD" }
        elseif ($cs.Model       -match "Laptop") { $type = "LT" }
    } catch {
        Write-Warning "WMI query failed during device type detection -- defaulting to DT."
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

function Get-SerialLast4 {
    <#
    .SYNOPSIS
        Returns the last 4 alphanumeric characters of the BIOS serial number.
        Pads with leading zeros if the cleaned serial is shorter than 4 characters.
    #>
    $serial = (Get-CimInstance Win32_BIOS).SerialNumber
    $clean  = ($serial -replace '[^A-Za-z0-9]', '').ToUpper()

    if ($clean.Length -ge 4) {
        return $clean.Substring($clean.Length - 4)
    }

    return $clean.PadLeft(4, '0')
}

function Get-UserName {
    <#
    .SYNOPSIS
        Presents a numbered list of C:\Users profile folders and returns the
        chosen name cleaned for use in a device name.

        In NonInteractive mode, the most recently active profile is selected
        automatically (sorted by folder LastWriteTime descending).

    .NOTES
        Name cleaning steps applied to the selected folder name:
          1. Strip from the first @ or _ onward
             (handles Entra UPN suffixes: jane.doe@contoso.com, JaneDoe_contoso.com)
          2. Remove dots
             (handles Entra UPN prefix style: jane.doe -> janedoe)
          3. Remove any remaining non-alphanumeric characters
          4. Truncate to 11 characters
             (maximum that fits in {WH}{LOC}-{NAME} within the 15-char limit)
    #>
    param (
        [switch]$NonInteractive
    )

    # Well-known Windows system profile folders that are never valid user names
    $systemFolders = @(
        "Public", "Default", "DefaultAppPool", "defaultuser0",
        "Administrator", "Guest", "WDAGUtilityAccount"
    )

    $profiles = Get-ChildItem -Path "C:\Users" -Directory |
        Where-Object  { $_.Name -notin $systemFolders } |
        Sort-Object   LastWriteTime -Descending

    if (-not $profiles) {
        throw "No user profile folders found under C:\Users."
    }

    if ($NonInteractive) {
        # Most recently active profile
        $selected = $profiles[0].Name
        Write-Host "Auto-selected profile: $selected"
    } else {
        Write-Host ""
        Write-Host "Select user:"
        for ($i = 0; $i -lt $profiles.Count; $i++) {
            "  {0}. {1}" -f ($i + 1), $profiles[$i].Name
        }
        Write-Host ""

        do {
            $choice = Read-Host "User number"
        } until ($choice -as [int] -and [int]$choice -ge 1 -and [int]$choice -le $profiles.Count)

        $selected = $profiles[[int]$choice - 1].Name
    }

    # Step 1 -- strip domain suffix at @ or _
    $clean = $selected
    foreach ($sep in '@', '_') {
        $idx = $clean.IndexOf($sep)
        if ($idx -gt 0) { $clean = $clean.Substring(0, $idx) }
    }

    # Step 2 & 3 -- remove dots and any remaining non-alphanumeric characters
    $clean = ($clean -replace '[^a-zA-Z0-9]', '')

    if ($clean.Length -eq 0) {
        throw "Profile name '$selected' produced an empty string after cleaning. Rename the profile folder or use Gateway mode."
    }

    # Step 4 -- truncate to 11 chars
    return $clean.Substring(0, [Math]::Min(11, $clean.Length))
}
