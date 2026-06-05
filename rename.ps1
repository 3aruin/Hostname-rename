# rename.ps1
# Orchestrator -- calls functions from logging.ps1, network.ps1, device.ps1,
# and naming.ps1 in the correct order to produce and apply a device name.

function Rename-DeviceSmart {
    <#
    .SYNOPSIS
        Renames this computer according to the standard naming convention.

    .PARAMETER Folder
        Use User naming mode: derives location from the gateway and the name from
        a chosen profile folder. Produces {WH}{LOC}-{Name}.

    .PARAMETER Gateway
        Use Gateway naming mode: derives location, dept, type, and serial from
        the network gateway. Produces {ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL}.

    .PARAMETER NonInteractive
        Suppresses all prompts. Defaults to Gateway mode. In User mode, picks
        the most recently active profile automatically.

    .PARAMETER FolderPath
        User mode only. Directory to search for profile folders instead of
        C:\Users (e.g. a redirected-profiles path). Defaults to C:\Users.
        Supplying it implies User mode.

    .PARAMETER Username
        User mode only. Partial name to match against profile folders. Interactive
        mode shows the matches as a filtered list; NonInteractive mode chooses the
        most recently active match. Supplying it implies User mode.

    .PARAMETER LogPath
        Directory for the run log. Defaults to %TEMP%\Hostname-Rename. Logging
        never blocks a rename -- if the path cannot be written, the rename still
        proceeds.

    .EXAMPLE
        # Interactive -- prompts for mode, then guides through the rest
        Rename-DeviceSmart

    .EXAMPLE
        # Force User naming mode interactively
        Rename-DeviceSmart -Folder

    .EXAMPLE
        # Headless / MDM deployment (Gateway mode)
        Rename-DeviceSmart -NonInteractive -Gateway

    .EXAMPLE
        # Dry run -- show the name that would be applied, without renaming
        Rename-DeviceSmart -NonInteractive -Gateway -WhatIf

    .EXAMPLE
        # User mode against a custom profile path, matching a partial name
        Rename-DeviceSmart -Folder -FolderPath "D:\Profiles" -Username "jdoe"
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive confirmation prompt -- proposed name and status messages must reach the user terminal directly')]
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

    # Always resolve gateway first -- provides location for both modes.
    # NonInteractive is forwarded so Get-NetworkContext can throw on an unmapped
    # gateway rather than silently producing a fallback name in an automated deployment.
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
        # -- User mode: {WH}{LOC}-{Name} --
        $userName = Get-UserName -NonInteractive:$NonInteractive -FolderPath $FolderPath -Username $Username
        Write-Log -Level INFO -Message "Selected user token: $userName"
        $newName  = New-UserDeviceName -WH $ctx.WH -LOC $ctx.LOC -Name $userName

    } else {
        # -- Gateway mode: {ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL} --
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

    # Interactive confirmation is skipped under -WhatIf (ShouldProcess emits the
    # What-If line) and under -NonInteractive. Otherwise prompt before proceeding.
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
        # Reached under -WhatIf: ShouldProcess returned $false and printed the
        # "What if:" line. No state change.
        Write-Log -Level INFO -Message "WhatIf: would rename '$env:COMPUTERNAME' -> '$newName'."
    }
}
