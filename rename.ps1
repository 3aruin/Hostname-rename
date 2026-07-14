# rename.ps1
# Orchestrator -- calls functions from logging.ps1, network.ps1, device.ps1,
# naming.ps1, and (optionally) gui.ps1 in the correct order to produce and
# apply a device name.

function Rename-DeviceSmart {
    # Renames this computer per the standard naming convention -- Gateway or User mode.
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive prompt and status output must reach the host stream directly.')]
    param (
        [switch]$Folder,
        [switch]$Gateway,
        [switch]$NonInteractive,
        [switch]$Gui,
        [string]$FolderPath,
        [string]$Username,
        [string]$LogPath,
        [ValidateRange(1, 300)]
        [int]$PromptTimeoutSeconds = 8
    )

    # Hard stop BEFORE any work (same philosophy as BUG-002 -- never guess in
    # automation): a GUI cannot exist in an unattended run, and silently
    # honouring one of the two contradictory switches would hide a deployment
    # mistake until devices came back wrongly named.
    if ($Gui -and $NonInteractive) {
        throw (
            "-Gui and -NonInteractive are mutually exclusive: a GUI cannot be shown " +
            "in an unattended session. Drop one of the two switches and re-run. " +
            "Halting -- never guess in automation."
        )
    }

    Initialize-Log -LogPath $LogPath
    Write-Log -Level INFO -Message ("Run started. NonInteractive={0} Folder={1} Gateway={2} Gui={3}" -f `
        [bool]$NonInteractive, [bool]$Folder, [bool]$Gateway, [bool]$Gui)

    # A UNC -FolderPath makes the profile enumeration below authenticate this (elevated)
    # machine to a remote SMB host (NTLM) -- same coercion/leak concern as a UNC -LogPath.
    # Warn once, up front, covering both the GUI and console profile-enumeration paths.
    if (-not [string]::IsNullOrWhiteSpace($FolderPath) -and $FolderPath -match '^\\\\') {
        Write-Warning "FolderPath '$FolderPath' is a UNC path -- enumerating it authenticates this machine to that host over SMB (NTLM). Use it only against a trusted share."
        Write-Log -Level WARN -Message "FolderPath is a UNC path ('$FolderPath') -- SMB (NTLM) authentication to a remote host will occur during profile enumeration."
    }

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

    # -- Optional GUI presentation layer --
    # Collects the same inputs as the console prompts below (mode, department,
    # type override, profile selection); everything downstream -- name
    # construction, the ShouldProcess gate, logging, restart -- is shared with
    # the console path. If Show-RenameGui cannot run (non-interactive desktop,
    # MTA thread, missing PresentationFramework) it returns the
    # GUI_UNAVAILABLE sentinel and we fall through to the console prompts:
    # a GUI failure must never block a rename.
    $guiInputs       = $null
    $guiSerial       = $null
    $guiDetectedType = $null
    if ($Gui) {
        # Fallback detection: Get-NetworkContext returns $script:FALLBACK_CONTEXT
        # (network.ps1) for an unmapped gateway in interactive mode. Compared by
        # value, not reference, so forks that reconfigure the sentinel values
        # still light the warning banner.
        $isFallback = ($ctx.ORG -eq $script:FALLBACK_CONTEXT.ORG -and
                       $ctx.WH  -eq $script:FALLBACK_CONTEXT.WH  -and
                       $ctx.LOC -eq $script:FALLBACK_CONTEXT.LOC)

        # The window shows both panels' data up front, so type detection,
        # serial, and profile enumeration all run before it opens.
        # -NonInteractive on Get-DeviceType skips its console override prompt
        # only -- the type ComboBox in the window is the override.
        $guiDetectedType = Get-DeviceType -NonInteractive
        $guiSerial       = Get-SerialLast4

        # Profile candidates for the User panel. Mirrors Get-UserName's
        # enumeration rules (device.ps1: system-folder exclusions, most
        # recently active first, -FolderPath root, -Username filter) -- keep
        # the two in sync. Not extracted into a shared helper because
        # device.ps1 is untouched by this change.
        $profileRoot       = if ([string]::IsNullOrWhiteSpace($FolderPath)) { "C:\Users" } else { $FolderPath }
        $profileCandidates = @()
        if (Test-Path -LiteralPath $profileRoot) {
            $systemFolders = @(
                "Public", "Default", "DefaultAppPool", "defaultuser0",
                "Administrator", "Guest", "WDAGUtilityAccount"
            )
            $profileCandidates = @(
                Get-ChildItem -LiteralPath $profileRoot -Directory |
                    Where-Object { $_.Name -notin $systemFolders } |
                    Sort-Object  LastWriteTime -Descending |
                    Select-Object -ExpandProperty Name
            )
        } elseif (-not [string]::IsNullOrWhiteSpace($FolderPath)) {
            # Explicit -FolderPath that does not exist is fatal, exactly like
            # the console path (Get-UserName). A missing default C:\Users is
            # not: it just leaves the User panel empty so Gateway mode stays usable.
            throw "Profile search path '$profileRoot' does not exist. Check -FolderPath or use Gateway mode."
        }
        if (-not [string]::IsNullOrWhiteSpace($Username)) {
            # Escape wildcard metacharacters -- match -Username as a literal substring,
            # mirroring Get-UserName so the GUI and console candidate lists stay identical.
            $userPattern       = "*" + [System.Management.Automation.WildcardPattern]::Escape($Username) + "*"
            $profileCandidates = @($profileCandidates | Where-Object { $_ -like $userPattern })
            if ($profileCandidates.Count -eq 0) {
                throw "No profile folder under '$profileRoot' matches -Username '$Username'."
            }
        }

        # Preselect the mode the console switches would have implied; the
        # toggle in the window remains free either way.
        $initialMode = if ($Folder -or
                           -not [string]::IsNullOrWhiteSpace($FolderPath) -or
                           -not [string]::IsNullOrWhiteSpace($Username)) { "User" } else { "Gateway" }

        Write-Log -Level INFO -Message "GUI requested -- opening Show-RenameGui."
        $guiResult = Show-RenameGui `
            -Context           $ctx `
            -DetectedType      $guiDetectedType `
            -SerialLast4       $guiSerial `
            -CurrentName       $env:COMPUTERNAME `
            -ProfileCandidates $profileCandidates `
            -IsFallbackContext:$isFallback `
            -InitialMode       $initialMode

        if ($guiResult -is [string] -and $guiResult -eq $script:GUI_UNAVAILABLE) {
            # Show-RenameGui already warned with the specific reason.
            Write-Log -Level INFO -Message "GUI unavailable -- falling back to console prompts."
        } elseif ($null -eq $guiResult) {
            # The window IS the confirmation, so closing it without applying
            # is the same outcome as answering N at the console prompt.
            Write-Host "Rename cancelled."
            Write-Log -Level INFO -Message "Rename cancelled by user in GUI."
            return
        } else {
            $guiInputs = $guiResult
            Write-Log -Level INFO -Message ("GUI inputs collected: Mode={0} WhatIf={1}" -f `
                $guiInputs.Mode, [bool]$guiInputs.WhatIf)
        }
    }

    $mode = if ($guiInputs) {
        $guiInputs.Mode
    } else {
        Select-NamingMode -Folder:$Folder -Gateway:$Gateway -NonInteractive:$NonInteractive `
                          -FolderPath $FolderPath -Username $Username `
                          -PromptTimeoutSeconds $PromptTimeoutSeconds
    }
    Write-Log -Level INFO -Message "Naming mode: $mode"

    if ($mode -eq "User") {
        # User mode: {WH}{LOC}-{Name}
        $userName = if ($guiInputs) {
            # The GUI returns the raw profile folder name; clean it with the
            # same helper Get-UserName delegates to, so both paths converge
            # on identical tokens.
            ConvertTo-CleanUserName -Name $guiInputs.ProfileName
        } else {
            Get-UserName -NonInteractive:$NonInteractive -FolderPath $FolderPath -Username $Username
        }
        Write-Log -Level INFO -Message "Selected user token: $userName"
        $newName  = New-UserDeviceName -WH $ctx.WH -LOC $ctx.LOC -Name $userName

    } else {
        # Gateway mode: {ORG}{WH}{LOC}-{DEPT}{TYPE}-{SERIAL}
        if ($guiInputs) {
            $dept   = $guiInputs.Department
            $type   = $guiInputs.Type
            $serial = $guiSerial   # fetched before the window opened
        } else {
            $dept   = Get-Department -NonInteractive:$NonInteractive
            # GUI-fallback reuse (F-08.6): when the pre-GUI probe already detected
            # the type and fetched the serial, don't pay the WMI cost twice -- a
            # real cost now that detection works (BUG-015). -Detected still leaves
            # the console override prompt available.
            $type   = Get-DeviceType -NonInteractive:$NonInteractive -Detected $guiDetectedType
            $serial = if ($guiSerial) { $guiSerial } else { Get-SerialLast4 }
        }
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

    # GUI "Dry run" rides the existing -WhatIf rails: raising the local
    # preference makes the ShouldProcess gate below print the What-If line
    # and skip the rename, identical to launching with -WhatIf.
    if ($guiInputs -and $guiInputs.WhatIf) { $WhatIfPreference = $true }

    # Skip the Y/N prompt under -WhatIf (ShouldProcess prints the What-If line),
    # -NonInteractive, and the GUI path -- the window IS the confirmation, so a
    # second prompt would be a double-ask.
    $proceed = $NonInteractive -or $WhatIfPreference -or ($null -ne $guiInputs)
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
