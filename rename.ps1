# rename.ps1
# Orchestrator -- calls functions from network.ps1, device.ps1, and naming.ps1
# in the correct order to produce and apply a device name.

function Rename-DeviceSmart {
    <#
    .SYNOPSIS
        Renames this computer according to the standard naming convention.

    .PARAMETER Folder
        Use User naming mode: derives location from gateway and name from a
        chosen C:\Users profile folder. Produces {WH}{LOC}-{Name}.

    .PARAMETER Gateway
        Use Gateway naming mode: derives location, dept, type, and serial from
        the network gateway. Produces {ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL}.

    .PARAMETER NonInteractive
        Suppresses all prompts. Defaults to Gateway mode. In User mode, picks
        the most recently active profile automatically.

    .EXAMPLE
        # Interactive -- prompts for mode, then guides through the rest
        Rename-DeviceSmart

    .EXAMPLE
        # Force User naming mode interactively
        Rename-DeviceSmart -Folder

    .EXAMPLE
        # Headless / MDM deployment (Gateway mode)
        Rename-DeviceSmart -NonInteractive -Gateway
    #>
    [CmdletBinding()]
    param (
        [switch]$Folder,
        [switch]$Gateway,
        [switch]$NonInteractive
    )

    # Always resolve gateway first -- provides location for both modes
    # NonInteractive is forwarded so Get-NetworkContext can throw on an unmapped gateway
    # rather than silently producing a fallback name in an automated deployment.
    $gatewayIP = Get-DefaultGateway
    $ctx       = Get-NetworkContext -Gateway $gatewayIP -NonInteractive:$NonInteractive

    $mode = Select-NamingMode -Folder:$Folder -Gateway:$Gateway -NonInteractive:$NonInteractive

    if ($mode -eq "User") {
        # ── User mode: {WH}{LOC}-{Name} ──────────────────────────────────────
        $userName = Get-UserName -NonInteractive:$NonInteractive
        $newName  = New-UserDeviceName -WH $ctx.WH -LOC $ctx.LOC -Name $userName

    } else {
        # ── Gateway mode: {ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL} ───────────────
        $dept   = Get-Department -NonInteractive:$NonInteractive
        $type   = Get-DeviceType -NonInteractive:$NonInteractive
        $serial = Get-SerialLast4

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

    if ($NonInteractive) {
        Write-Host "NonInteractive mode -- renaming and restarting."
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
