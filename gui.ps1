# gui.ps1
# Optional WPF presentation layer -- collects the same inputs the console
# prompts collect (mode, department, type override, profile selection) and
# returns them to the orchestrator. This module NEVER calls Rename-Computer;
# rename.ps1 owns the ShouldProcess gate and the rename itself.
# Depends on: device.ps1 ($script:VALID_DEPARTMENTS, $script:DEVICE_TYPES,
#             ConvertTo-CleanUserName) and naming.ps1 (New-DeviceName,
#             New-UserDeviceName) -- both are dot-sourced before this file
#             per the $MODULES order in launcher.ps1.
# WPF only (PresentationFramework) -- no WinForms, no third-party modules
# (ADR-005). Runs on Windows PowerShell 5.1 and PowerShell 7 on Windows.

# Sentinel returned when the GUI cannot run (non-interactive session, MTA
# thread, PresentationFramework missing, or an unexpected WPF failure).
# Distinct from $null, which means "the operator cancelled". The caller
# falls back to the console prompts on this value -- a GUI failure must
# never block a rename.
$script:GUI_UNAVAILABLE = "GUI_UNAVAILABLE"

function Update-RenameGuiPreview {
    # Recomputes the live preview from the current control state. Called on
    # every mode/selection change. Uses the same builders as the console path
    # (New-DeviceName / New-UserDeviceName) so the preview can never drift
    # from the name that will actually be applied.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Refreshes in-window WPF controls only; no system state changes. The ShouldProcess gate lives in Rename-DeviceSmart.')]
    param ()

    $c  = $script:GuiCtl
    $in = $script:GuiIn
    if (-not $c -or -not $in) { return }

    # The name builders warn on truncation/department-drop; on every click
    # that is console noise, so suppress for the duration of this recompute
    # (the builders are simple functions and inherit this preference -- they
    # take no -WarningAction). The window surfaces the dropped state itself,
    # and the final builder call in rename.ps1 still warns normally.
    $WarningPreference = 'SilentlyContinue'

    $c.DeptWarningText.Visibility = [System.Windows.Visibility]::Collapsed
    $errorBrush  = [System.Windows.Media.Brushes]::Firebrick
    $normalBrush = [System.Windows.Media.Brushes]::Black

    $name = $null
    $ok   = $false

    if ($c.UserModeRadio.IsChecked) {
        $sel = $c.ProfileList.SelectedItem
        if ($sel -and $sel.IsEnabled) {
            $name = New-UserDeviceName -WH $in.Context.WH -LOC $in.Context.LOC -Name $sel.Tag.Clean
            $ok = $true
        } else {
            $c.PreviewText.Text       = "(select a user profile)"
            $c.PreviewText.Foreground = $normalBrush
            $c.CharCountText.Text     = "- / 15"
        }
    } else {
        # Gateway mode. SelectedItem is $null until the operator picks a
        # department -- no silent "WS" default to rubber-stamp; the window
        # is the confirmation, so every segment must be an explicit choice.
        $dept     = $c.DepartmentCombo.SelectedItem
        $typeItem = $c.TypeCombo.SelectedItem
        $type     = if ($typeItem) { $typeItem.Tag } else { $null }

        if ($dept -and $type) {
            # Reconstruct the untruncated name so a department drop is
            # detectable: New-DeviceName returns the shortened form when the
            # full form exceeds 15 chars, so result-differs-from-full is
            # exactly the "department dropped" condition.
            $full = "{0}{1}{2}-{3}{4}-{5}" -f `
                $in.Context.ORG, $in.Context.WH, $in.Context.LOC, $dept, $type, $in.SerialLast4

            try {
                $name = New-DeviceName `
                    -ORG        $in.Context.ORG `
                    -WH         $in.Context.WH `
                    -LOC        $in.Context.LOC `
                    -Department $dept `
                    -Type       $type `
                    -Serial     $in.SerialLast4
                $ok = $true

                if ($name -ne $full) {
                    $c.DeptWarningText.Visibility = [System.Windows.Visibility]::Visible
                }
            } catch {
                # Even the department-dropped form exceeds 15 chars -- only
                # possible with malformed ORG/WH/LOC values in GATEWAY_MAP.
                # Show the error in the window instead of letting the
                # exception escape a WPF event handler.
                $c.PreviewText.Text       = "(name exceeds 15 characters -- check GATEWAY_MAP values)"
                $c.PreviewText.Foreground = $errorBrush
                $c.CharCountText.Text     = "{0} / 15" -f $full.Length
            }
        } else {
            $c.PreviewText.Text       = "(select a department)"
            $c.PreviewText.Foreground = $normalBrush
            $c.CharCountText.Text     = "- / 15"
        }
    }

    if ($ok) {
        $c.PreviewText.Text       = $name
        $c.PreviewText.Foreground = $normalBrush
        $c.CharCountText.Text     = "{0} / 15" -f $name.Length
    }

    # The action buttons follow validity: nothing to apply, nothing to click.
    $c.RenameButton.IsEnabled = $ok
    $c.DryRunButton.IsEnabled = $ok
}

function Show-RenameGui {
    # Shows the WPF input window and returns:
    #   $null                     -- operator cancelled (Cancel button or titlebar X)
    #   $script:GUI_UNAVAILABLE   -- GUI cannot run here; caller falls back to console
    #   hashtable                 -- @{ Mode; Department; Type; ProfileName; WhatIf }
    # This function only collects inputs -- it never renames anything.
    param (
        [Parameter(Mandatory)]
        [hashtable]$Context,            # resolved ORG/WH/LOC from Get-NetworkContext

        [Parameter(Mandatory)]
        [string]$DetectedType,          # from Get-DeviceType -NonInteractive

        [Parameter(Mandatory)]
        [string]$SerialLast4,           # from Get-SerialLast4

        [Parameter(Mandatory)]
        [string]$CurrentName,           # current hostname

        [AllowEmptyCollection()]
        [string[]]$ProfileCandidates = @(),   # raw profile folder names, pre-filtered/sorted by the caller

        [switch]$IsFallbackContext,     # true when Get-NetworkContext returned $FALLBACK_CONTEXT

        [ValidateSet("Gateway", "User")]
        [string]$InitialMode = "Gateway"
    )

    # -- Preconditions -- any failure warns and returns the sentinel so the
    #    caller can fall back to the existing console prompts.

    # No interactive desktop (service, scheduled task, some MDM contexts):
    # WPF has nowhere to render.
    if (-not [Environment]::UserInteractive) {
        Write-Warning "GUI unavailable: session is not user-interactive. Falling back to console prompts."
        return $script:GUI_UNAVAILABLE
    }

    # WPF windows can only be created on an STA thread. Console hosts default
    # to STA on Windows, but background jobs, custom runspaces, and some
    # embedded hosts run MTA -- creating a Window there throws, so check
    # up front rather than crash mid-run.
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne
        [System.Threading.ApartmentState]::STA) {
        Write-Warning "GUI unavailable: current thread is not STA (WPF requires STA). Falling back to console prompts."
        return $script:GUI_UNAVAILABLE
    }

    # PresentationFramework is absent on Server Core / stripped images.
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    } catch {
        Write-Warning "GUI unavailable: PresentationFramework could not be loaded ($($_.Exception.Message)). Falling back to console prompts."
        return $script:GUI_UNAVAILABLE
    }

    # -- XAML --
    # SECURITY: this here-string is STATIC and single-quoted. Runtime data
    # (profile folder names, hostnames, serials, WMI model strings) is NEVER
    # interpolated into it -- XAML is executable markup (ObjectDataProvider
    # and friends can invoke arbitrary code), so any attacker-influenced
    # string spliced into it would be an injection vector. All values are
    # populated via properties (.Text, Items.Add, Tag) AFTER parsing, where
    # they are inert data. Keep it that way.
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Hostname Rename"
        Width="480" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize">
    <StackPanel Margin="12">

        <Border x:Name="FallbackBanner" Visibility="Collapsed"
                Background="#FFF4CE" BorderBrush="#E0A800" BorderThickness="1"
                CornerRadius="3" Padding="8" Margin="0,0,0,10">
            <TextBlock x:Name="FallbackBannerText" TextWrapping="Wrap" FontWeight="Bold"/>
        </Border>

        <GroupBox Header="Detected context" Padding="6">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="110"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Grid.Column="0" Text="Gateway context:"/>
                <TextBlock Grid.Row="0" Grid.Column="1" x:Name="ContextText" FontWeight="Bold"/>
                <TextBlock Grid.Row="1" Grid.Column="0" Text="Current name:"/>
                <TextBlock Grid.Row="1" Grid.Column="1" x:Name="CurrentNameText"/>
                <TextBlock Grid.Row="2" Grid.Column="0" Text="Serial (last 4):"/>
                <TextBlock Grid.Row="2" Grid.Column="1" x:Name="ContextSerialText"/>
                <TextBlock Grid.Row="3" Grid.Column="0" Text="Device type:"/>
                <TextBlock Grid.Row="3" Grid.Column="1" x:Name="DetectedTypeText"/>
            </Grid>
        </GroupBox>

        <StackPanel Orientation="Horizontal" Margin="0,10,0,6">
            <TextBlock Text="Naming mode:" VerticalAlignment="Center" Width="110"/>
            <RadioButton x:Name="GatewayModeRadio" GroupName="NamingMode"
                         Content="Gateway" VerticalAlignment="Center" Margin="0,0,16,0"/>
            <RadioButton x:Name="UserModeRadio" GroupName="NamingMode"
                         Content="User" VerticalAlignment="Center"/>
        </StackPanel>

        <GroupBox x:Name="GatewayPanel" Header="Gateway mode" Padding="6">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="110"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition/><RowDefinition/><RowDefinition/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Grid.Column="0" Text="Department:" VerticalAlignment="Center"/>
                <ComboBox  Grid.Row="0" Grid.Column="1" x:Name="DepartmentCombo" Margin="0,2"/>
                <TextBlock Grid.Row="1" Grid.Column="0" Text="Device type:" VerticalAlignment="Center"/>
                <ComboBox  Grid.Row="1" Grid.Column="1" x:Name="TypeCombo" Margin="0,2"/>
                <TextBlock Grid.Row="2" Grid.Column="0" Text="Serial:" VerticalAlignment="Center"/>
                <TextBox   Grid.Row="2" Grid.Column="1" x:Name="SerialBox" IsReadOnly="True"
                           Background="#F0F0F0" Margin="0,2"/>
            </Grid>
        </GroupBox>

        <GroupBox x:Name="UserPanel" Header="User mode" Padding="6" Visibility="Collapsed">
            <StackPanel>
                <TextBlock Text="Profile folder (folder name -> cleaned name):" Margin="0,0,0,4"/>
                <ListBox x:Name="ProfileList" Height="140"/>
            </StackPanel>
        </GroupBox>

        <GroupBox Header="Preview" Padding="6" Margin="0,10,0,0">
            <StackPanel>
                <DockPanel>
                    <TextBlock x:Name="CharCountText" DockPanel.Dock="Right"
                               VerticalAlignment="Center" Foreground="Gray"/>
                    <TextBlock x:Name="PreviewText" FontFamily="Consolas" FontSize="16"
                               FontWeight="Bold" VerticalAlignment="Center"/>
                </DockPanel>
                <TextBlock x:Name="DeptWarningText" Visibility="Collapsed"
                           Foreground="#B45D00" TextWrapping="Wrap" Margin="0,4,0,0"
                           Text="Full name exceeds 15 characters -- department segment dropped."/>
            </StackPanel>
        </GroupBox>

        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="DryRunButton" Content="Dry run" Width="80" Margin="0,0,8,0" Padding="4"/>
            <Button x:Name="CancelButton" Content="Cancel" Width="80" Margin="0,0,8,0" Padding="4" IsCancel="True"/>
            <Button x:Name="RenameButton" Content="Rename device" Width="110" Padding="4" IsDefault="True"/>
        </StackPanel>

    </StackPanel>
</Window>
'@

    $result = $null

    try {
        $window = [System.Windows.Markup.XamlReader]::Parse($xaml)

        # Controls looked up once; kept in script scope because WPF event
        # handler scriptblocks do not reliably see function-local variables
        # under PS 5.1 -- $script: scope works identically on 5.1 and 7.
        $names = @(
            "FallbackBanner", "FallbackBannerText", "ContextText", "CurrentNameText",
            "ContextSerialText", "DetectedTypeText", "GatewayModeRadio", "UserModeRadio",
            "GatewayPanel", "UserPanel", "DepartmentCombo", "TypeCombo", "SerialBox",
            "ProfileList", "PreviewText", "CharCountText", "DeptWarningText",
            "DryRunButton", "CancelButton", "RenameButton"
        )
        $script:GuiCtl = @{}
        foreach ($n in $names) { $script:GuiCtl[$n] = $window.FindName($n) }

        $script:GuiIn = @{
            Context     = $Context
            SerialLast4 = $SerialLast4
        }
        $script:GuiOut = $null

        # -- Populate (code-only; see the SECURITY note above the XAML) --
        $c = $script:GuiCtl
        $c.ContextText.Text       = "ORG={0}  WH={1}  LOC={2}" -f $Context.ORG, $Context.WH, $Context.LOC
        $c.CurrentNameText.Text   = $CurrentName
        $c.ContextSerialText.Text = $SerialLast4
        $c.SerialBox.Text         = $SerialLast4
        $c.DetectedTypeText.Text  = "{0}  (auto-detected)" -f $DetectedType

        if ($IsFallbackContext) {
            $c.FallbackBanner.Visibility = [System.Windows.Visibility]::Visible
            $c.FallbackBannerText.Text   = (
                "Gateway is not in GATEWAY_MAP -- fallback context {0}/{1}/{2} is in use. " +
                "The renamed device will carry these sentinel values. " +
                "Add this gateway to network.ps1 to resolve."
            ) -f $Context.ORG, $Context.WH, $Context.LOC
        }

        foreach ($d in $script:VALID_DEPARTMENTS) {
            [void]$c.DepartmentCombo.Items.Add($d)
        }
        # No department preselected on purpose: the console forces an explicit
        # entry, and the window is the confirmation -- a pre-filled default
        # would invite a wrong department being rubber-stamped.

        foreach ($t in $script:DEVICE_TYPES) {
            $item     = New-Object System.Windows.Controls.ComboBoxItem
            $item.Tag = $t
            # ET stays selectable but is labelled manual-only: thin clients
            # have no WMI signal, so Resolve-DeviceType never returns ET --
            # this dropdown (like the console override) is the only way to
            # set it.
            $item.Content = if ($t -eq "ET") { "ET  (manual only -- never auto-detected)" } else { $t }
            [void]$c.TypeCombo.Items.Add($item)
            if ($t -eq $DetectedType) { $c.TypeCombo.SelectedItem = $item }
        }

        foreach ($folder in $ProfileCandidates) {
            $item     = New-Object System.Windows.Controls.ListBoxItem
            $clean    = $null
            try {
                $clean = ConvertTo-CleanUserName -Name $folder
            } catch {
                # Folder name cleans to an empty string (e.g. all symbols):
                # shown greyed-out rather than hidden, so the operator can
                # see why it is not offered.
                Write-Verbose "Profile folder '$folder' is not usable: $($_.Exception.Message)"
            }
            if ($clean) {
                $item.Content = "{0}  ->  {1}" -f $folder, $clean
                $item.Tag     = @{ Folder = $folder; Clean = $clean }
            } else {
                $item.Content   = "{0}  ->  (cleans to empty -- not selectable)" -f $folder
                $item.IsEnabled = $false
            }
            [void]$c.ProfileList.Items.Add($item)
        }

        if ($ProfileCandidates.Count -eq 0) {
            # Gateway-only box (no non-system profiles): keep the window
            # usable instead of throwing like the console User path would.
            $c.UserModeRadio.IsEnabled = $false
            $c.UserModeRadio.ToolTip   = "No user profile folders were found."
        }

        # Initial mode BEFORE wiring events, then one manual sync + preview
        # call -- avoids handlers firing on half-populated controls.
        if ($InitialMode -eq "User" -and $c.UserModeRadio.IsEnabled) {
            $c.UserModeRadio.IsChecked = $true
            $c.GatewayPanel.Visibility = [System.Windows.Visibility]::Collapsed
            $c.UserPanel.Visibility    = [System.Windows.Visibility]::Visible
        } else {
            $c.GatewayModeRadio.IsChecked = $true
        }

        # -- Events --
        $c.GatewayModeRadio.Add_Checked({
            $script:GuiCtl.GatewayPanel.Visibility = [System.Windows.Visibility]::Visible
            $script:GuiCtl.UserPanel.Visibility    = [System.Windows.Visibility]::Collapsed
            Update-RenameGuiPreview
        })
        $c.UserModeRadio.Add_Checked({
            $script:GuiCtl.GatewayPanel.Visibility = [System.Windows.Visibility]::Collapsed
            $script:GuiCtl.UserPanel.Visibility    = [System.Windows.Visibility]::Visible
            Update-RenameGuiPreview
        })
        $c.DepartmentCombo.Add_SelectionChanged({ Update-RenameGuiPreview })
        $c.TypeCombo.Add_SelectionChanged({ Update-RenameGuiPreview })
        $c.ProfileList.Add_SelectionChanged({ Update-RenameGuiPreview })

        # The window IS the confirmation: Rename / Dry run close it and hand
        # the collected inputs back -- no second Y/N prompt afterwards.
        # Cancel (and the titlebar X) leave $script:GuiOut as $null.
        $collect = {
            param($whatIf)
            $c    = $script:GuiCtl
            $mode = if ($c.UserModeRadio.IsChecked) { "User" } else { "Gateway" }
            $sel  = $c.ProfileList.SelectedItem
            $typeItem = $c.TypeCombo.SelectedItem
            $script:GuiOut = @{
                Mode        = $mode
                Department  = $c.DepartmentCombo.SelectedItem
                Type        = if ($typeItem) { $typeItem.Tag } else { $null }
                ProfileName = if ($sel -and $sel.IsEnabled) { $sel.Tag.Folder } else { $null }
                WhatIf      = $whatIf
            }
        }
        $script:GuiCollect = $collect
        $script:GuiWindow  = $window

        $c.RenameButton.Add_Click({
            & $script:GuiCollect $false
            $script:GuiWindow.Close()
        })
        $c.DryRunButton.Add_Click({
            & $script:GuiCollect $true
            $script:GuiWindow.Close()
        })

        Update-RenameGuiPreview

        [void]$window.ShowDialog()
        $result = $script:GuiOut
    } catch {
        # Belt and braces on the "a GUI failure must never block a rename"
        # rule: any unexpected WPF failure degrades to the console path.
        Write-Warning "GUI failed unexpectedly ($($_.Exception.Message)). Falling back to console prompts."
        return $script:GUI_UNAVAILABLE
    } finally {
        $script:GuiCtl     = $null
        $script:GuiIn      = $null
        $script:GuiOut     = $null
        $script:GuiWindow  = $null
        $script:GuiCollect = $null
    }

    return $result
}
