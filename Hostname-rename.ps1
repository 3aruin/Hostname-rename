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
    Author: Your Name
    Org: RB | IEX
    Version: 1.0.0
#>

param (
    [string]$Org = "RB",
    [string]$NetworkLog = "\\YourServer\Logs\RenameLog.csv",
    [string]$LocalLog = "C:\Temp\RenameLog.csv",
    [switch]$NonInteractive
)

# --- Ensure local log directory exists ---
$localDir = Split-Path $LocalLog
if (!(Test-Path $localDir)) {
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
$gateway = Get-CimInstance Win32_NetworkAdapterConfiguration |
    Where-Object { $_.IPEnabled -and $_.DefaultIPGateway } |
    Select-Object -ExpandProperty DefaultIPGateway -First 1

# --- Map Gateway ---
if ($GatewayMap.ContainsKey($gateway)) {
    $warehouse = $GatewayMap[$gateway].WH
    $location  = $GatewayMap[$gateway].LOC
} else {
    $warehouse = "XX"
    $location  = "X"
}

# --- Department चयन (Prompt if interactive) ---
$validDepartments = @("CS","SR","OP","HQ","IT")

if ($NonInteractive) {
    $department = "IT"
} else {
    do {
        $department = (Read-Host "Enter Department (CS, SR, OP, HQ, IT)").ToUpper()
    } until ($validDepartments -contains $department)
}

# --- Detect Device Type ---
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem

if ($cs.Model -match "Virtual|VMware|VirtualBox|Hyper-V") {
    $detectedType = "VM"
}
elseif ($os.ProductType -ne 1) {
    $detectedType = "SV"
}
else {
    $chassis = (Get-CimInstance Win32_SystemEnclosure).ChassisTypes
    if ($chassis -match "9|10|14") { $detectedType = "LT" } else { $detectedType = "DT" }
}

$type = $detectedType

# --- Optional Override (Interactive only) ---
if (-not $NonInteractive) {
    Write-Output "Detected Type: $detectedType"
    Write-Output "Override? Y=Accept | 1=SV 2=LT 3=DT 4=VM"

    for ($i = 5; $i -gt 0; $i--) {
        Write-Host "Auto-accept in $i..." -NoNewline "`r"
        Start-Sleep 1

        if ([console]::KeyAvailable) {
            $key = [console]::ReadKey($true).KeyChar
            switch ($key.ToString().ToUpper()) {
                "1" { $type = "SV" }
                "2" { $type = "LT" }
                "3" { $type = "DT" }
                "4" { $type = "VM" }
                default { $type = $detectedType }
            }
            break
        }
    }
}

# --- Serial Handling ---
$serial = (Get-CimInstance Win32_BIOS).SerialNumber
$serialClean = ($serial -replace '[^a-zA-Z0-9]', '').ToUpper()

$serialLast4 = if ($serialClean.Length -ge 4) {
    $serialClean.Substring($serialClean.Length - 4)
} else {
    $serialClean.PadLeft(4,"0")
}

# --- Build Name ---
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

# --- Logging Function ---
function Write-Log {
    param ($Path, $Data)

    try {
        if (!(Test-Path $Path)) {
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

# --- Rename पुष्टि ---
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
