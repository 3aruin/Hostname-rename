# tests/Hostname-Rename.Gui.Tests.ps1
#
# Pester v5 unit tests for the -Gui feature (gui.ps1 + its wiring in rename.ps1).
# Same conventions as tests/Hostname-Rename.Tests.ps1: no WMI / OS / GUI dependency.
#
# Three groups:
#   1. Resolve-GatewayPreview -- pure preview logic extracted from Update-RenameGuiPreview,
#      tested exactly like Resolve-DeviceType / ConvertTo-SerialLast4.
#   2. Get-RenameGuiXaml -- XAML smoke test via XamlReader, guarded by a
#      PresentationFramework availability check so the suite still runs where WPF
#      is absent (e.g. Server Core CI images).
#   3. Rename-DeviceSmart -Gui parameter contract -- Mock-based, no real WMI/GUI/
#      Rename-Computer call is ever made.
#
# Run from the repo root:
#   Invoke-Pester ./tests -Output Detailed

BeforeAll {
    # Dot-source in the same order launcher.ps1 loads them, so the functions under
    # test see exactly the dependencies they see in a real run.
    . "$PSScriptRoot/../logging.ps1"
    . "$PSScriptRoot/../network.ps1"
    . "$PSScriptRoot/../device.ps1"
    . "$PSScriptRoot/../naming.ps1"
    . "$PSScriptRoot/../gui.ps1"
    . "$PSScriptRoot/../rename.ps1"
}

# -----------------------------------------------------------------------------
Describe "Resolve-GatewayPreview" {

    It "Returns NoSelection when Department is not chosen" {
        (Resolve-GatewayPreview -Context @{ ORG = "AC"; WH = "01"; LOC = "R" } -Department $null -Type "DT" -Serial "A3F9").Status |
            Should -Be "NoSelection"
    }

    It "Returns NoSelection when Type is not chosen" {
        (Resolve-GatewayPreview -Context @{ ORG = "AC"; WH = "01"; LOC = "R" } -Department "WS" -Type $null -Serial "A3F9").Status |
            Should -Be "NoSelection"
    }

    It "Returns Ok with the full name and DeptDropped false when it fits in 15 chars" {
        $result = Resolve-GatewayPreview -Context @{ ORG = "AC"; WH = "01"; LOC = "R" } -Department "WS" -Type "DT" -Serial "A3F9"
        $result.Status      | Should -Be "Ok"
        $result.Name         | Should -Be "AC01R-WSDT-A3F9"
        $result.DeptDropped | Should -Be $false
    }

    It "Returns Ok with DeptDropped true when the full name overflows 15 chars" {
        # AC01R-CSDT-A3F92 = 16 chars -> department dropped -> AC01R-DT-A3F92
        $result = Resolve-GatewayPreview -Context @{ ORG = "AC"; WH = "01"; LOC = "R" } -Department "CS" -Type "DT" -Serial "A3F92"
        $result.Status      | Should -Be "Ok"
        $result.Name         | Should -Be "AC01R-DT-A3F92"
        $result.DeptDropped | Should -Be $true
    }

    It "Returns Overflow when even the department-dropped form exceeds 15 chars" {
        $result = Resolve-GatewayPreview -Context @{ ORG = "AC"; WH = "01"; LOC = "R" } -Department "CS" -Type "DT" -Serial "TOOLONG9"
        $result.Status | Should -Be "Overflow"
        $result.Name    | Should -BeNullOrEmpty
    }

    It "Overflow FullLength reflects the untruncated full-form length" {
        # "AC01R-CSDT-TOOLONG9" = 19 chars
        $result = Resolve-GatewayPreview -Context @{ ORG = "AC"; WH = "01"; LOC = "R" } -Department "CS" -Type "DT" -Serial "TOOLONG9"
        $result.FullLength | Should -Be 19
    }

    It "Never throws -- overflow is reported as a status, not an exception" {
        { Resolve-GatewayPreview -Context @{ ORG = "AC"; WH = "01"; LOC = "R" } -Department "CS" -Type "DT" -Serial "TOOLONG9" } |
            Should -Not -Throw
    }
}

# -----------------------------------------------------------------------------
$script:WpfAvailable = $false
try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    $script:WpfAvailable = $true
} catch {
    Write-Verbose "PresentationFramework not available in this session -- XAML smoke tests will be skipped."
}

Describe "Get-RenameGuiXaml" -Skip:(-not $script:WpfAvailable) {

    It "Returns a non-empty string" {
        Get-RenameGuiXaml | Should -Not -BeNullOrEmpty
    }

    It "Parses as well-formed XAML via XamlReader" {
        { [System.Windows.Markup.XamlReader]::Parse((Get-RenameGuiXaml)) } | Should -Not -Throw
    }

    It "Exposes every control name Show-RenameGui binds by FindName" {
        $window = [System.Windows.Markup.XamlReader]::Parse((Get-RenameGuiXaml))
        $expectedNames = @(
            "FallbackBanner", "FallbackBannerText", "ContextText", "CurrentNameText",
            "ContextSerialText", "DetectedTypeText", "GatewayModeRadio", "UserModeRadio",
            "GatewayPanel", "UserPanel", "DepartmentCombo", "TypeCombo", "SerialBox",
            "ProfileList", "PreviewText", "CharCountText", "DeptWarningText",
            "DryRunButton", "CancelButton", "RenameButton"
        )
        foreach ($n in $expectedNames) {
            $window.FindName($n) | Should -Not -BeNullOrEmpty -Because "Show-RenameGui does `$c.$n"
        }
    }

    It "Contains no runtime data interpolation (no `$` characters at all -- static markup only)" {
        Get-RenameGuiXaml | Should -Not -Match '\$'
    }
}

# -----------------------------------------------------------------------------
Describe "Rename-DeviceSmart -Gui parameter contract" {

    BeforeEach {
        # Stub every WMI/OS/GUI/state-changing dependency. Never let a test reach
        # a real Get-CimInstance, Read-Host, WPF window, or Rename-Computer call.
        Mock Get-DefaultGateway { "192.0.2.1" }   # mapped in network.ps1's example GATEWAY_MAP
        Mock Get-Department     { "WS" }
        Mock Get-DeviceType     { "DT" }
        Mock Get-SerialLast4    { "A3F9" }
        Mock Get-UserName       { "TestUser" }
        Mock Rename-Computer    { }
        Mock Initialize-Log     { }
        Mock Write-Log          { }
        Mock Select-NamingMode  { "Gateway" }
        Mock Show-RenameGui     { "GUI_UNAVAILABLE" }   # mirrors $script:GUI_UNAVAILABLE in gui.ps1
    }

    It "-Gui with -NonInteractive throws immediately, before any WMI/GUI call" {
        { Rename-DeviceSmart -Gui -NonInteractive } |
            Should -Throw -ExpectedMessage "*mutually exclusive*"

        Should -Invoke Get-DefaultGateway -Times 0
        Should -Invoke Show-RenameGui     -Times 0
    }

    It "-Gui with a precondition failure falls back to the console flow instead of throwing" {
        # Show-RenameGui is mocked to return the GUI_UNAVAILABLE sentinel, simulating
        # any precondition failure (non-interactive session, MTA thread, missing WPF).
        # -WhatIf skips the confirmation prompt and the real rename, matching how a
        # dry run rides the existing ShouldProcess rails.
        { Rename-DeviceSmart -Gui -Gateway -WhatIf } | Should -Not -Throw

        Should -Invoke Show-RenameGui -Times 1 -Exactly
        Should -Invoke Get-Department -Times 1 -Exactly

        # GUI-fallback reuse (F-08.6): the console fallback reuses the pre-GUI
        # probe's results instead of paying the WMI cost twice. Get-SerialLast4
        # runs exactly once; Get-DeviceType runs a second time (it still owns the
        # console override prompt) but receives the cached result via -Detected,
        # which skips its WMI queries.
        Should -Invoke Get-DeviceType -Times 2 -Exactly
        Should -Invoke Get-DeviceType -Times 1 -Exactly -ParameterFilter { $Detected -eq "DT" }
        Should -Invoke Get-SerialLast4 -Times 1 -Exactly
        Should -Invoke Rename-Computer -Times 0
    }

    It "-Gui absent -- Show-RenameGui is never invoked" {
        Rename-DeviceSmart -NonInteractive -Gateway -WhatIf

        Should -Invoke Show-RenameGui -Times 0
    }

    It "-Gui absent -- Gateway-mode console path receives the same NonInteractive/mode forwarding as before" {
        Rename-DeviceSmart -NonInteractive -Gateway -WhatIf

        Should -Invoke Select-NamingMode -Times 1 -Exactly -ParameterFilter {
            $Folder -eq $false -and $Gateway -eq $true -and $NonInteractive -eq $true -and
            [string]::IsNullOrEmpty($FolderPath) -and [string]::IsNullOrEmpty($Username)
        }
        Should -Invoke Get-Department -Times 1 -Exactly -ParameterFilter { $NonInteractive -eq $true }
        Should -Invoke Get-DeviceType -Times 1 -Exactly -ParameterFilter { $NonInteractive -eq $true }
    }

    It "-Gui absent -- -PromptTimeoutSeconds is forwarded to Select-NamingMode (OQ-004)" {
        Rename-DeviceSmart -NonInteractive -Gateway -WhatIf -PromptTimeoutSeconds 42

        Should -Invoke Select-NamingMode -Times 1 -Exactly -ParameterFilter {
            $PromptTimeoutSeconds -eq 42
        }
    }

    It "-Gui absent -- User-mode console path forwards -FolderPath and -Username unchanged" {
        Mock Select-NamingMode { "User" }

        Rename-DeviceSmart -NonInteractive -FolderPath "D:\Profiles" -Username "jdoe" -WhatIf

        Should -Invoke Get-UserName -Times 1 -Exactly -ParameterFilter {
            $NonInteractive -eq $true -and $FolderPath -eq "D:\Profiles" -and $Username -eq "jdoe"
        }
        Should -Invoke Show-RenameGui -Times 0
    }

    It "-Gui absent -- Rename-Computer is never called under -WhatIf" {
        Rename-DeviceSmart -NonInteractive -Gateway -WhatIf

        Should -Invoke Rename-Computer -Times 0
    }
}
