# rename.ps1
# Orchestrator -- calls functions from logging.ps1, network.ps1, device.ps1,
# and naming.ps1 in the correct order to produce and apply a device name.

function Rename-DeviceSmart {
    # Renames this computer per the standard naming convention -- Gateway or User mode.
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive prompt and status output must reach the host stream directly.')]
    param (
        [switch]$Folder,
        [switch]$Gateway,
        [switch]$NonInteractive,
        [string]$FolderPath,
        [string]$Username,
        [string]$LogPath
    )

    Initialize-Log -LogPath $LogPath
    Write-Log -Level INFO -Message ("Run started. NonInteractive={0} Folder={1} Gateway={2}" -f `
        [bool]$NonInteractive, [bool]$Folder, [bool]$Gateway)

    # Resolve gateway first (both modes need location); NonInteractive forwarded so an unmapped gateway throws instead of falling back.
    $gatewayIP = Get-DefaultGateway
    Write-Log -Level INFO -Message "Default gateway: '$gatewayIP'"

    try {
        $ctx = Get-NetworkContext -Gateway $gatewayIP -NonInteractive:$NonInteractive
    } catch {
        Write-Log -Level ERROR -Message "Network context resolution failed: $($_.Exception.Message)"
        throw
    }
    Write-Log -Level INFO -Message ("Context: ORG={0} WH={1} LOC={2}" -f $ctx.ORG, $ctx.WH, $ctx.LOC)

    $mode = Select-NamingMode -Folder:$Folder -Gateway:$Gateway -NonInteractive:$NonInteractive `
                              -FolderPath $FolderPath -Username $Username
    Write-Log -Level INFO -Message "Naming mode: $mode"

    if ($mode -eq "User") {
        # User mode: {WH}{LOC}-{Name}
        $userName = Get-UserName -NonInteractive:$NonInteractive -FolderPath $FolderPath -Username $Username
        Write-Log -Level INFO -Message "Selected user token: $userName"
        $newName  = New-UserDeviceName -WH $ctx.WH -LOC $ctx.LOC -Name $userName

    } else {
        # Gateway mode: {ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL}
        $dept   = Get-Department -NonInteractive:$NonInteractive
        $type   = Get-DeviceType -NonInteractive:$NonInteractive
        $serial = Get-SerialLast4
        Write-Log -Level INFO -Message ("Gateway-mode parts: DEPT={0} TYPE={1} SERIAL={2}" -f $dept, $type, $serial)

        $newName = New-DeviceName `
            -ORG        $ctx.ORG `
            -WH         $ctx.WH `
            -LOC        $ctx.LOC `
            -Department $dept `
            -Type       $type `
            -Serial     $serial
    }

    Write-Host ""
    Write-Host "Proposed name : $newName"
    Write-Host ""
    Write-Log -Level INFO -Message "Proposed name: $newName"

    # Skip the Y/N prompt under -WhatIf (ShouldProcess prints the What-If line) and -NonInteractive.
    $proceed = $NonInteractive -or $WhatIfPreference
    if (-not $proceed) {
        $answer  = Read-Host "Rename to '$newName' and restart? (Y/N)"
        $proceed = $answer -match "^[Yy]"
        if (-not $proceed) {
            Write-Host "Rename cancelled."
            Write-Log -Level INFO -Message "Rename cancelled by user at confirmation prompt."
            return
        }
    }

    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Rename to '$newName' and restart")) {
        Write-Host "Renaming and restarting..."
        Write-Log -Level INFO -Message "Renaming '$env:COMPUTERNAME' -> '$newName'; restarting."
        Rename-Computer -NewName $newName -Force -Restart
    } else {
        # -WhatIf path: ShouldProcess returned $false and printed the What-If line; no state change.
        Write-Log -Level INFO -Message "WhatIf: would rename '$env:COMPUTERNAME' -> '$newName'."
    }
}