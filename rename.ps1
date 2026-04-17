# rename.ps1
# Orchestrator — calls functions from network.ps1, device.ps1, and naming.ps1
# in the correct order to produce and apply a device name.

function Rename-DeviceSmart {
    <#
    .SYNOPSIS
        Renames this computer according to the standard naming convention.

    .PARAMETER Folder
        Force Folder naming mode (reads from Desktop subdirectories).

    .PARAMETER Gateway
        Force Gateway naming mode (resolves from default gateway IP).

    .PARAMETER FolderPath
        Custom path to use in Folder mode. Defaults to the current user's Desktop.

    .PARAMETER Username
        Partial username to match when resolving the profile path in Folder mode.

    .PARAMETER NonInteractive
        Suppresses all prompts. Uses: Gateway mode, WS department, auto-detected
        device type, and renames without confirmation.

    .EXAMPLE
        # Interactive (prompts for department, device type, naming mode)
        Rename-DeviceSmart

    .EXAMPLE
        # Headless / MDM deployment
        Rename-DeviceSmart -NonInteractive -Gateway
    #>
    [CmdletBinding()]
    param (
        [switch]$Folder,
        [switch]$Gateway,
        [string]$FolderPath  = "",
        [string]$Username    = "",
        [switch]$NonInteractive
    )

    # Resolve network context early — needed regardless of naming mode
    $gatewayIP = Get-DefaultGateway

    # Resolve folder path if Folder mode is requested but no path was supplied
    if ($Folder -and -not $FolderPath) {
        $userPath   = Get-UserProfilePath -Username $Username
        $FolderPath = Join-Path $userPath "Desktop"
    }

    $mode   = Select-NamingMode    -Folder:$Folder -Gateway:$Gateway -NonInteractive:$NonInteractive
    $ctx    = Get-NamingContext    -Mode $mode -Gateway $gatewayIP -FolderPath $FolderPath -NonInteractive:$NonInteractive
    $dept   = Get-Department       -NonInteractive:$NonInteractive
    $type   = Get-DeviceType       -NonInteractive:$NonInteractive
    $serial = Get-SerialLast4

    $newName = New-DeviceName `
        -ORG        $ctx.ORG `
        -WH         $ctx.WH `
        -LOC        $ctx.LOC `
        -Department $dept `
        -Type       $type `
        -Serial     $serial

    Write-Host ""
    Write-Host "Proposed name : $newName"
    Write-Host ""

    if ($NonInteractive) {
        Write-Host "NonInteractive mode — renaming and restarting."
        Rename-Computer -NewName $newName -Force -Restart
        return
    }

    $confirm = Read-Host "Rename to '$newName' and restart? (Y/N)"

    if ($confirm -match "^[Yy]") {
        Rename-Computer -NewName $newName -Force -Restart
    } else {
        Write-Host "Rename cancelled."
    }
}
