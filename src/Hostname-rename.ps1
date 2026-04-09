<#
.SYNOPSIS
    Device Renaming Script
 
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
    Version: 1.2.0-Sonnet
#>
 
# --- Script-level Constants ---
$VALID_DEPARTMENTS = @("CS", "SR", "OP", "HQ", "IT", "WS")
$DEVICE_TYPES      = @("VM", "SV", "MD", "ET", "LT", "DT")
$GATEWAY_MAP = @{
    "10.72.0.1" = @{ WH = "00"; LOC = "A" }
    "10.72.1.1" = @{ WH = "01"; LOC = "R" }
    "10.72.2.1" = @{ WH = "02"; LOC = "W" }
    "10.72.3.1" = @{ WH = "03"; LOC = "F" }
    "10.72.4.1" = @{ WH = "04"; LOC = "C" }
    "10.72.9.1" = @{ WH = "09"; LOC = "S" }
}
 
# --- Function Definitions ---
function Invoke-SelfElevation {
    <#
    .SYNOPSIS
        Relaunches the script as administrator, if necessary.
    .PARAMETER FallbackUrl
        URL to fetch the script content from if not running from a file.
    #>
    [CmdletBinding()]
    param(
        [string]$FallbackUrl
    )
 
    # Check for admin rights
    $isAdmin = ([Security.Principal.WindowsPrincipal] (
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
 
    if ($isAdmin) {
        return $false  # Already elevated
    }
 
    Write-Verbose "Elevation required. Relaunching as Administrator..."
 
    $argList = @()
    foreach ($param in $PSBoundParameters.GetEnumerator()) {
        if ($param.Key -eq "FallbackUrl") { continue }
        if ($param.Value -is [switch]) {
            if ($param.Value) {
                $argList += "-$($param.Key)"
            }
        }
        elseif ($param.Value -is [array]) {
            foreach ($val in $param.Value) {
                $argList += "-$($param.Key)"
                $argList += "$val"
            }
        }
        else {
            $argList += "-$($param.Key)"
            $argList += "$($param.Value)"
        }
    }
 
    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $processCmd    = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { $powershellCmd }
 
    if ($PSCommandPath) {
        $baseArgs = @(
            "-ExecutionPolicy", "Bypass",
            "-NoProfile",
            "-File", "`"$PSCommandPath`""
        ) + $argList
 
        $finalArgs = if ($processCmd -eq "wt.exe") {
            "$powershellCmd " + ($baseArgs -join ' ')
        } else {
            $baseArgs
        }
    }
    elseif ($FallbackUrl) {
        $escapedUrl = $FallbackUrl -replace "'", "''"
        $command = "&([ScriptBlock]::Create((irm '$escapedUrl'))) $($argList -join ' ')"
        $finalArgs = if ($processCmd -eq "wt.exe") {
            "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$command`""
        } else {
            "-ExecutionPolicy Bypass -NoProfile -Command `"$command`""
        }
    }
    else {
        throw "Cannot self-elevate: no script path or fallback URL provided."
    }
 
    Start-Process $processCmd -ArgumentList $finalArgs -Verb RunAs
    return $true
}
 
function Write-Log {
    <#
    .SYNOPSIS
        Writes log data to a CSV file.
    .PARAMETER Path
        Path to the log file.
    .PARAMETER Data
        Data to write (PSCustomObject).
    #>
    param ($Path, $Data)
 
    try {
        if (-not (Test-Path $Path)) {
            $Data | Export-Csv -Path $Path -NoTypeInformation
        } else {
            $Data | Export-Csv -Path $Path -NoTypeInformation -Append
        }
    } catch {
        Write-Warning "Failed to write log to $($Path): $($_.Exception.Message)"
    }
}
 
# --- Parameters ---
param (
    [ValidateNotNullOrEmpty()]
    [string]$Org = "RB",
 
    [ValidateNotNullOrEmpty()]
    [string]$NetworkLog = "\\YourServer\Logs\RenameLog.csv",
 
    [ValidateNotNullOrEmpty()]
    [string]$LocalLog = "C:\Temp\RenameLog.csv",
 
    [switch]$NonInteractive
)
 
# --- Entry Point ---
if (Invoke-SelfElevation -FallbackUrl "https://raw.githubusercontent.com/3aruin/Hostname-rename/main/src/Hostname-rename.ps1") {
    return
}
 
# --- Ensure Local Log Directory Exists ---
$localDir = Split-Path $LocalLog
if (-not (Test-Path $localDir)) {
    try {
        New-Item -Path $localDir -ItemType Directory -Force | Out-Null
        Write-Verbose "Created log directory: $localDir"
    } catch {
        Write-Warning "Failed to create log directory: $localDir - $($_.Exception.Message)"
        return
    }
}
 
# --- Get Default Gateway ---
$gateway = (Get-CimInstance Win32_NetworkAdapterConfiguration |
    Where-Object { $_.IPEnabled -and $_.DefaultIPGateway } |
    Select-Object -ExpandProperty DefaultIPGateway -First 1)
 
if (-not $gateway) {
    Write-Error "Unable to determine default gateway."
    return
}
 
# --- Map Gateway ---
$gatewayMapping = $GATEWAY_MAP[$gateway]
if ($gatewayMapping) {
    $warehouse = $gatewayMapping.WH
    $location  = $gatewayMapping.LOC
} else {
    $warehouse = "XX"
    $location  = "X"
}
 
# --- Department Selection ---
if ($NonInteractive) {
    $department = "WS"
} else {
    do {
        $inputDept = Read-Host "Enter Department ($($VALID_DEPARTMENTS -join ', '))"
        $department = $inputDept.ToUpper().Trim()
        if ($VALID_DEPARTMENTS -contains $department) {
            break
        } else {
            Write-Host "Invalid department. Please choose from $($VALID_DEPARTMENTS -join ', ')."
        }
    } until ($VALID_DEPARTMENTS -contains $department)
}
 
# --- Device Type Detection ---
$detectedType = "DT"  # Default to DT
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $processor = Get-CimInstance Win32_Processor
 
    if ($cs.Model -match "Virtual|VMware|VirtualBox|Hyper-V") {
        $detectedType = "VM"
    }
    elseif ($os.ProductType -ne 1) {
        $detectedType = "SV"
    }
    elseif ($processor.Architecture -eq 5 -or $os.Caption -match "Windows.*ARM") {
        $detectedType = "MD"
    }
    elseif ($cs.Model -match "Embedded|IoT|ThinClient") {
        $detectedType = "ET"
    }
    elseif ($cs.Model -match "Laptop|Portable") {
        $detectedType = "LT"
    }
    else {
        $chassis = Get-CimInstance Win32_SystemEnclosure
        if ($null -ne $chassis -and $chassis.ChassisTypes -match "9|10|14") {
            $detectedType = "LT"
        } else {
            $detectedType = "DT"
        }
    }
}
catch {
    Write-Warning "Error detecting device type: $($_.Exception.Message)"
}
 
# --- Interactive Device Type Override ---
if (-not $NonInteractive) {
    Write-Output "Detected Device Type: $detectedType"
    Write-Output "Available Device Types: $($DEVICE_TYPES -join ', ')"
    $typeInput = Read-Host "Enter Device Type to override or press [Enter] to accept detected"
    $typeInput = $typeInput.ToUpper().Trim()
    if ($DEVICE_TYPES -contains $typeInput) {
        $detectedType = $typeInput
    } elseif ($typeInput) {
        Write-Warning "Invalid device type entered, keeping detected ($detectedType)."
    }
}
$type = $detectedType
 
# --- Serial Handling ---
try {
    $serial = (Get-CimInstance Win32_BIOS).SerialNumber
} catch {
    $serial = ""
}
if (-not $serial) {
    Write-Error "Failed to retrieve BIOS serial number."
    return
}
$serialClean = ($serial -replace '[^a-zA-Z0-9]', '').ToUpper()
if (-not $serialClean) {
    Write-Error "Serial number is empty after cleaning."
    return
}
$serialLast4 = if ($serialClean.Length -ge 4) {
    $serialClean.Substring($serialClean.Length - 4)
} else {
    $serialClean.PadLeft(4, '0')
}
 
# --- Build New Name ---
$newName = "$Org$warehouse$location-$department$type-$serialLast4"
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
 
# --- Write Logs ---
Write-Log -Path $NetworkLog -Data $logObject
Write-Log -Path $LocalLog   -Data $logObject
 
Write-Output "New computer name will be: $newName"
 
# --- Rename Confirmation ---
if ($NonInteractive) {
    try {
        Rename-Computer -NewName $newName -Force -Restart
    }
    catch {
        Write-Error "Failed to rename computer: $($_.Exception.Message)"
    }
} else {
    $confirm = Read-Host "Proceed with rename? (Y/N)"
    if ($confirm -match "^[Yy]") {
        try {
            Rename-Computer -NewName $newName -Force -Restart
        }
        catch {
            Write-Error "Failed to rename computer: $($_.Exception.Message)"
        }
    } else {
        Write-Output "Rename cancelled."
    }
}
