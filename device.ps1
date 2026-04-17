# device.ps1
# Handles: department selection, device type detection, serial number retrieval

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
