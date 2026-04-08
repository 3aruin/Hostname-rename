<#
.SYNOPSIS
    Device Renaming Script (IEX Standard)

.DESCRIPTION
    Automatically renames a device based on:
    - Organization
    - Network Gateway (Warehouse + Location)
    - Department
    - Device Type
    - Serial Number (last 4)

    Includes logging to network and local fallback.

.NOTES
    Author: 3aruin
    Org: for RB
    Version: 1.1.0
#>

param (
    [string]$Org = "RB",
    [string]$NetworkLog = "\\YourServer\Logs\RenameLog.csv",
    [string]$LocalLog = "C:\Temp\RenameLog.csv",
    [switch]$NonInteractive
)

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "Hostname-rename needs to be run as Administrator. Attempting to relaunch."
    $argList = @()

    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $argList += if ($_.Value -is [switch] -and $_.Value) {
            "-$($_.Key)"
        } elseif ($_.Value -is [array]) {
            "-$($_.Key) $($_.Value -join ',')"
        } elseif ($_.Value) {
            "-$($_.Key) '$($_.Value)'"
        }
    }

    $script = if ($PSCommandPath) {
        "& { & `'$($PSCommandPath)`' $($argList -join ' ') }"
    } else {
        "&([ScriptBlock]::Create((irm https://github.com/3aruin/Hostname-rename/releases/latest/download/winutil.ps1))) $($argList -join ' ')"
    }

    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $processCmd = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { "$powershellCmd" }

    if ($processCmd -eq "wt.exe") {
        Start-Process $processCmd -ArgumentList "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    } else {
        Start-Process $processCmd -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    }

    break
}

# --- Ensure Local Log Directory Exists ---
$localDir = Split-Path $LocalLog
if (-not (Test-Path $localDir)) {
    New-Item -Path $localDir -ItemType Directory | Out-Null
}

# --- Gateway Mapping ---
$GatewayMap = @{
    "10.72.0.1" = @{ WH = "00"; LOC = "A" }
    "10.72.1.1" = @{ WH = "01"; LOC = "R" }
    "10.72.2.1" = @{ WH = "02"; LOC = "W" }
    "10.72.3.1" = @{ WH = "03"; LOC = "F" }
    "10.72.4.1" = @{ WH = "04"; LOC = "C" }
    "10.72.9.1" = @{ WH = "09"; LOC = "S" }
}

# --- Get Default Gateway ---
$gateway = (Get-CimInstance Win32_NetworkAdapterConfiguration |
    Where-Object { $_.IPEnabled -and $_.DefaultIPGateway } |
    Select-Object -ExpandProperty DefaultIPGateway -First 1)

# --- Map Gateway ---
$gatewayMapping = $GatewayMap[$gateway]
if ($gatewayMapping) {
    $warehouse = $gatewayMapping.WH
    $location  = $gatewayMapping.LOC
} else {
    $warehouse = "XX"
    $location  = "X"
}

# --- Department Selection (Prompt if Interactive) ---
$validDepartments = @("CS", "SR", "OP", "HQ", "IT")

if ($NonInteractive) {
    $department = "IT"
} else {
    do {
        $department = (Read-Host "Enter Department (CS, SR, OP, HQ, IT)").ToUpper()
    } until ($validDepartments -contains $department)
}

# --- Detect Device Type ---
$detectedType = "DT"  # Default to DT in case of error

try {
    # Get the OS and Computer System instances once to reduce redundant calls
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $processor = Get-CimInstance Win32_Processor

    # Detect Virtual Machine (VM)
    if ($cs.Model -match "Virtual|VMware|VirtualBox|Hyper-V") {
        $detectedType = "VM"
    }
    # Detect Server (SV)
    elseif ($os.ProductType -ne 1) {  # Non-workstation types are typically Server
        $detectedType = "SV"
    }
    # Detect Tablet or Mobile (MD)
    elseif ($processor.Architecture -eq 5 -or $os.Caption -match "Windows.*ARM") {
        $detectedType = "MD"
    }
    # Detect Embedded/IoT (ET)
    elseif ($cs.Model -match "Embedded|IoT|ThinClient") {
        $detectedType = "ET"
    }
    # Detect Laptop (LT)
    elseif ($cs.Model -match "Laptop|Portable") {
        $detectedType = "LT"
    }
    # Default to Desktop (DT)
    else {
        $chassis = Get-CimInstance Win32_SystemEnclosure
        if ($chassis.ChassisTypes -match "9|10|14") {
            $detectedType = "LT"
        } else {
            $detectedType = "DT"
        }
    }
}
catch {
    # If any error occurs, default to DT
    Write-Warning "Error detecting device type: $_"
}

# Final device type assignment
$type = $detectedType

# --- Optional Override (Interactive Only) ---
$deviceTypes = @("VM", "SV", "MD", "ET", "LT", "DT")

# Display the device types and prompt for selection
Write-Output "Select Device Type:"
$deviceTypes | ForEach-Object { Write-Output "$($_): $($_)" }

$selectedType = Read-Host "Enter Device Type (1 for VM, 2 for SV, 3 for MD, 4 for ET, 5 for LT, 6 for DT)"
$selectedType = $selectedType.Trim()

# Validate the user input
switch ($selectedType) {
    "1" { $detectedType = "VM" }
    "2" { $detectedType = "SV" }
    "3" { $detectedType = "MD" }
    "4" { $detectedType = "ET" }
    "5" { $detectedType = "LT" }
    "6" { $detectedType = "DT" }
    default {
        Write-Output "Invalid input, defaulting to DT."
        $detectedType = "DT"
    }
}

# --- Serial Handling ---
Here’s the "full-proofed" version:

# Retrieve the serial number of the system BIOS
$serial = (Get-CimInstance Win32_BIOS).SerialNumber

# Check if the serial number is null or empty
if (-not $serial) {
    Write-Error "Failed to retrieve BIOS serial number."
    return
}

# Clean the serial number by removing non-alphanumeric characters and converting to uppercase
$serialClean = ($serial -replace '[^a-zA-Z0-9]', '').ToUpper()

# Ensure the cleaned serial number isn't empty after cleaning
if (-not $serialClean) {
    Write-Error "Serial number is empty after cleaning."
    return
}

# Retrieve the last 4 characters or pad with zeroes if the string is shorter than 4 characters
$serialLast4 = if ($serialClean.Length -ge 4) {
    $serialClean.Substring($serialClean.Length - 4)
} else {
    $serialClean.PadLeft(4, '0')
}

# Output the cleaned last 4 characters of the serial number
$serialLast4

# --- Build New Name ---
$newName = "$Org$warehouse$location-$department$type-$serialLast4"

# Ensure the new name does not exceed 15 characters
if ($newName.Length -gt 15) {
    $newName = "$Org$warehouse$location-$type-$serialLast4"
}

if ($newName.Length -gt 15) {
    throw "Generated name exceeds 15 characters: $newName"
}

# --- Logging Object ---
$logObject = [PSCustomObject]@{
    Timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    User       = $env:USERNAME
    OldName    = $env:COMPUTERNAME
    NewName    = $newName
    Gateway    = $gateway
    Warehouse  = $warehouse
    Location   = $location
    Department = $department
    Type       = $type
}

# --- Logging Function ---
function Write-Log {
    param ($Path, $Data)

    try {
        if (-not (Test-Path $Path)) {
            $Data | Export-Csv -Path $Path -NoTypeInformation
        } else {
            $Data | Export-Csv -Path $Path -NoTypeInformation -Append
        }
    } catch {
        Write-Warning "Failed to write log: $Path"
    }
}

# --- Write Logs ---
Write-Log -Path $NetworkLog -Data $logObject
Write-Log -Path $LocalLog   -Data $logObject

Write-Output "New Name: $newName"

# --- Rename Confirmation ---
if ($NonInteractive) {
    Rename-Computer -NewName $newName -Force -Restart
} else {
    $confirm = Read-Host "Proceed with rename? (Y/N)"
    if ($confirm -match "^[Yy]") {
        Rename-Computer -NewName $newName -Force -Restart
    } else {
        Write-Output "Rename cancelled."
    }
}
