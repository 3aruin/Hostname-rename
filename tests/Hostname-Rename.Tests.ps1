# tests/Hostname-Rename.Tests.ps1
#
# Pester v5 unit tests for Hostname-Rename.
# Covers all pure-logic functions (no WMI / OS calls required), plus deliberate
# exceptions that run real OS seams once each: the BUG-015 block (real WMI
# collection -- mocking that seam is exactly how a fake -AsJob parameter shipped
# undetected for three releases), the BUG-018 block (real redirected-stdin child
# process), and the BUG-019 block (real route query).
#
# Run from the repo root:
#   Invoke-Pester ./tests/Hostname-Rename.Tests.ps1 -Output Detailed
#
# CI runs this automatically on every push and PR via .github/workflows/ci.yml.

BeforeAll {
    # Dot-source modules directly -- no need for launcher or network access.
    # device.ps1 now exposes the WMI-free helpers (Resolve-DeviceType,
    # ConvertTo-SerialLast4, ConvertTo-CleanUserName) that these tests exercise
    # directly, so the tests verify the real implementation rather than copies.
    . "$PSScriptRoot/../naming.ps1"
    . "$PSScriptRoot/../network.ps1"
    . "$PSScriptRoot/../device.ps1"
    . "$PSScriptRoot/../logging.ps1"
}

# -----------------------------------------------------------------------------
Describe "New-DeviceName" {

    Context "Full name fits within 15 characters" {

        It "Returns the full name when it is exactly 15 chars" {
            # AA00A-AABB-0000 = 15
            New-DeviceName -ORG "AA" -WH "00" -LOC "A" -Department "AA" -Type "BB" -Serial "0000" |
                Should -Be "AA00A-AABB-0000"
        }

        It "Returns the full name when it is under 15 chars" {
            New-DeviceName -ORG "AC" -WH "01" -LOC "R" -Department "WS" -Type "DT" -Serial "A3F9" |
                Should -Be "AC01R-WSDT-A3F9"
        }

        It "Returns the full name when serial is 3 chars" {
            New-DeviceName -ORG "AC" -WH "09" -LOC "S" -Department "HQ" -Type "SV" -Serial "XYZ" |
                Should -Be "AC09S-HQSV-XYZ"
        }
    }

    Context "Full name overflows -- department is omitted" {

        It "Drops department segment and warns when full name is 16 chars" {
            # AC01R-CSDT-A3F92 = 16 chars
            $result = New-DeviceName -ORG "AC" -WH "01" -LOC "R" -Department "CS" -Type "DT" -Serial "A3F92"
            $result | Should -Be "AC01R-DT-A3F92"
        }

        It "Shortened name is still within 15 chars" {
            $result = New-DeviceName -ORG "AC" -WH "01" -LOC "R" -Department "CS" -Type "DT" -Serial "A3F92"
            $result.Length | Should -BeLessOrEqual 15
        }
    }

    Context "Both full and shortened overflow -- throws" {

        It "Throws when even the shortened name exceeds 15 characters" {
            # Pathological: ORG=AC WH=01 LOC=R Type=DT Serial=TOOLONG9 -> AC01R-DT-TOOLONG9 = 17
            { New-DeviceName -ORG "AC" -WH "01" -LOC "R" -Department "CS" -Type "DT" -Serial "TOOLONG9" } |
                Should -Throw
        }
    }
}

# -----------------------------------------------------------------------------
Describe "New-UserDeviceName" {

    It "Returns the full name when it fits within 15 chars" {
        New-UserDeviceName -WH "01" -LOC "R" -Name "JaneDoe" |
            Should -Be "01R-JaneDoe"
    }

    It "Returns the full name when it is exactly 15 chars" {
        # "01R-JaneDoe1234" = 15
        New-UserDeviceName -WH "01" -LOC "R" -Name "JaneDoe1234" |
            Should -Be "01R-JaneDoe1234"
    }

    It "Truncates the name when result would exceed 15 chars" {
        # "01R-JaneDoe12345" = 16 -> truncate Name to 11
        New-UserDeviceName -WH "01" -LOC "R" -Name "JaneDoe12345" |
            Should -Be "01R-JaneDoe1234"
    }

    It "Result is never longer than 15 chars after truncation" {
        $result = New-UserDeviceName -WH "01" -LOC "R" -Name "AVeryLongNameThatShouldTriggerTruncation"
        $result.Length | Should -BeLessOrEqual 15
    }

    It "Works with two-digit WH and single-letter LOC" {
        New-UserDeviceName -WH "09" -LOC "S" -Name "Bob" |
            Should -Be "09S-Bob"
    }

    It "Throws a clean error, not ArgumentOutOfRange, when WH+LOC leave no room for a name (F-08.3)" {
        # Malformed GATEWAY_MAP values: prefix "0123456789TOOLONGLOC-" is 21 chars,
        # so the truncation length would be negative.
        { New-UserDeviceName -WH "0123456789" -LOC "TOOLONGLOC" -Name "Bob" } |
            Should -Throw -ExpectedMessage "*no room*"
    }
}

# -----------------------------------------------------------------------------
Describe "ConvertTo-SerialLast4" {

    Context "Serial longer than 4 chars" {
        It "Returns the last 4 chars of a cleaned serial" {
            ConvertTo-SerialLast4 "VMW-A3F9B2C1" | Should -Be "B2C1"
        }
        It "Strips hyphens and returns last 4" {
            ConvertTo-SerialLast4 "SN-##-1234" | Should -Be "1234"
        }
        It "Normalises lowercase to uppercase" {
            ConvertTo-SerialLast4 "abcd" | Should -Be "ABCD"
        }
    }

    Context "Serial shorter than 4 chars -- pad with leading zeros" {
        It "3 chars -- left-pads to 4"      { ConvertTo-SerialLast4 "ABC" | Should -Be "0ABC" }
        It "1 char -- left-pads to 4"       { ConvertTo-SerialLast4 "X"   | Should -Be "000X" }
        It "Empty string -- four zeros"     { ConvertTo-SerialLast4 ""    | Should -Be "0000" }
        It "All special chars -- four zeros" { ConvertTo-SerialLast4 "---" | Should -Be "0000" }
    }
}

# -----------------------------------------------------------------------------
Describe "ConvertTo-CleanUserName" {

    It "Strips @ suffix (standard UPN)" {
        ConvertTo-CleanUserName "jane.doe@contoso.com" | Should -Be "janedoe"
    }

    It "Strips _ suffix (Entra joined UPN style)" {
        ConvertTo-CleanUserName "JaneDoe_contoso_com" | Should -Be "JaneDoe"
    }

    It "Leaves plain names unchanged" {
        ConvertTo-CleanUserName "JohnSmith" | Should -Be "JohnSmith"
    }

    It "Removes dots in prefix (UPN style: first.last)" {
        ConvertTo-CleanUserName "john.smith" | Should -Be "johnsmith"
    }

    It "Truncates to 11 characters" {
        ConvertTo-CleanUserName "VeryLongNameHere" | Should -Be "VeryLongNam"
    }

    It "Result is never longer than 11 characters" {
        (ConvertTo-CleanUserName "AVeryVeryVeryLongFolderName").Length | Should -BeLessOrEqual 11
    }

    It "Processes @ before _ -- strips at @ first, then _ in remainder" {
        # user_name@domain.com -> strip @ -> user_name -> strip _ -> user
        ConvertTo-CleanUserName "user_name@domain.com" | Should -Be "user"
    }

    It "Throws when cleaned result is empty" {
        { ConvertTo-CleanUserName "___" } | Should -Throw
    }
}

# -----------------------------------------------------------------------------
Describe "Resolve-DeviceType" {

    It "VM when model contains Virtual" {
        Resolve-DeviceType -Model "VMware Virtual Platform" -ProductType 1 | Should -Be "VM"
    }
    It "SV when ProductType is not 1" {
        Resolve-DeviceType -Model "PowerEdge R740" -ProductType 3 | Should -Be "SV"
    }
    It "TB when chassis is Tablet (30)" {
        Resolve-DeviceType -Model "Surface Pro" -ChassisTypes @(30) | Should -Be "TB"
    }
    It "TB when chassis is Convertible (31)" {
        Resolve-DeviceType -Model "ThinkPad Yoga" -ChassisTypes @(31) | Should -Be "TB"
    }
    It "MD when architecture is ARM (5)" {
        Resolve-DeviceType -Model "Generic" -Architecture 5 | Should -Be "MD"
    }
    It "LT when model contains Laptop" {
        Resolve-DeviceType -Model "Some Laptop 5000" | Should -Be "LT"
    }
    It "LT when chassis is Laptop (9)" {
        Resolve-DeviceType -Model "Latitude 5440" -ChassisTypes @(9) | Should -Be "LT"
    }
    It "LT when chassis is Notebook (10)" {
        Resolve-DeviceType -Model "EliteBook 840" -ChassisTypes @(10) | Should -Be "LT"
    }
    It "ARM beats laptop chassis (priority) -- an ARM notebook stays MD" {
        Resolve-DeviceType -Model "x" -Architecture 5 -ChassisTypes @(10) | Should -Be "MD"
    }
    It "PB when chassis is Pizza Box (5)" {
        Resolve-DeviceType -Model "RackNode 1U" -ChassisTypes @(5) | Should -Be "PB"
    }
    It "DT as the default fallback" {
        Resolve-DeviceType -Model "OptiPlex 7090" -ProductType 1 -Architecture 0 -ChassisTypes @(3) | Should -Be "DT"
    }
    It "Server beats tablet chassis (priority)" {
        Resolve-DeviceType -Model "x" -ProductType 2 -ChassisTypes @(30) | Should -Be "SV"
    }
    It "Tablet beats ARM (priority)" {
        Resolve-DeviceType -Model "x" -Architecture 5 -ChassisTypes @(31) | Should -Be "TB"
    }
    It "Always returns a 2-char code (default branch)" {
        (Resolve-DeviceType -Model "x").Length | Should -Be 2
    }
}

# -----------------------------------------------------------------------------
Describe "Get-DeviceType WMI collection (BUG-015 regression)" {

    It "Uses only parameters that exist on Get-CimInstance" {
        # Static guard: the shipped bug was 'Get-CimInstance -AsJob' -- a parameter
        # that does not exist on any PowerShell edition, so every call threw into
        # the catch fallback and every device detected as DT. Parse device.ps1 and
        # verify each named parameter on each Get-CimInstance call is real.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot/../device.ps1", [ref]$null, [ref]$null)
        $calls = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Get-CimInstance'
        }, $true)
        $calls.Count | Should -BeGreaterThan 0

        $cmd   = Get-Command Get-CimInstance
        $valid = @($cmd.Parameters.Keys) + @($cmd.Parameters.Values.Aliases)
        foreach ($call in $calls) {
            foreach ($element in $call.CommandElements) {
                if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                    $valid | Should -Contain $element.ParameterName `
                        -Because "device.ps1 passes -$($element.ParameterName) to Get-CimInstance, which must be a real parameter"
                }
            }
        }
    }

    It "Runs the real collection without hitting the catch fallback (no mocks)" {
        # Redirect the warning stream instead of -WarningVariable: Get-DeviceType
        # is not an advanced function, so it takes no common parameters.
        $output   = Get-DeviceType -NonInteractive 3>&1
        $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $type     = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[-1]

        $warnings | Should -BeNullOrEmpty -Because "a warning means the WMI collection threw and the DT fallback masked it"
        $script:DEVICE_TYPES | Should -Contain $type
    }

    It "Skips the WMI queries entirely when -Detected supplies a prior result (F-08.6)" {
        Mock Get-CimInstance { throw "WMI must not be queried when -Detected is supplied" }
        Get-DeviceType -NonInteractive -Detected "LT" | Should -Be "LT"
        Should -Invoke Get-CimInstance -Times 0
    }

    It "Ignores an invalid -Detected value instead of trusting it" {
        # Falls back to the real WMI collection, so the result must still be a
        # valid type code -- never the bogus input.
        $output = Get-DeviceType -NonInteractive -Detected "ZZ" 3>&1
        $type   = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[-1]
        $script:DEVICE_TYPES | Should -Contain $type
    }
}

# -----------------------------------------------------------------------------
Describe "Interactive prompts bail out on exhausted input (F-08.4 regression)" {

    It "Get-Department throws after bounded attempts when Read-Host returns only empty strings" {
        # Exhausted/redirected stdin: Read-Host returns "" forever; the loop used
        # to spin for eternity.
        Mock Read-Host { "" }
        { Get-Department } | Should -Throw -ExpectedMessage "*attempts*"
    }

    It "Get-UserName throws after bounded attempts when Read-Host returns only empty strings" {
        Mock Read-Host { "" }
        New-Item -ItemType Directory -Path (Join-Path $TestDrive "Profiles\JaneDoe") -Force | Out-Null
        { Get-UserName -FolderPath (Join-Path $TestDrive "Profiles") } |
            Should -Throw -ExpectedMessage "*attempts*"
    }
}

# -----------------------------------------------------------------------------
Describe "Select-NamingMode with redirected console input (BUG-018 regression)" {

    It "Defaults to Gateway instead of crashing when stdin is not a real console" {
        # [Console]::KeyAvailable throws InvalidOperationException when console
        # input is redirected; piping into a child PowerShell reproduces exactly
        # that state (as do RMM agents and some remoting hosts). The child also
        # inherits the launcher's ErrorActionPreference=Stop so an unhandled
        # throw fails the test via a non-zero exit code.
        $psExe   = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
        $naming  = Join-Path $PSScriptRoot '..\naming.ps1'
        $output  = '' | & $psExe -NoProfile -Command ". '$naming'; `$ErrorActionPreference = 'Stop'; Select-NamingMode -PromptTimeoutSeconds 1"
        $LASTEXITCODE | Should -Be 0
        @($output)[-1] | Should -Be 'Gateway'
    }
}

# -----------------------------------------------------------------------------
Describe "Get-DefaultGateway (BUG-019 regression)" {

    It "Returns `$null or an IPv4 literal -- never an IPv6 address (real route query, no mocks)" {
        # GATEWAY_MAP is IPv4-keyed; an IPv6 next-hop could never match a site.
        $gw = Get-DefaultGateway
        if ($null -ne $gw) {
            $gw | Should -Match '^\d{1,3}(\.\d{1,3}){3}$'
        }
    }
}

# -----------------------------------------------------------------------------
Describe "Elevation relaunch command, iex path (BUG-016 regression)" {

    BeforeAll {
        $script:LauncherContent = Get-Content -LiteralPath "$PSScriptRoot/../launcher.ps1" -Raw
    }

    It "Builds the scriptblock-invocation form, not an argument splice after iex" {
        # Invoke-Expression takes a single -Command argument; any token appended
        # after 'iex (irm ...)' is a binding error in the elevated window, never
        # an argument to the downloaded script.
        $script:LauncherContent | Should -Match ([regex]::Escape('& ([scriptblock]::Create((irm '))
        $script:LauncherContent | Should -Not -Match ([regex]::Escape("iex (irm '`$escapedUrl')"))
    }

    It "The constructed shape binds a spaced value, a switch, and an int through a real -Command round-trip" {
        $stub = Join-Path $TestDrive "relaunch-stub.ps1"
        Set-Content -LiteralPath $stub -Value @'
param([string]$Username, [switch]$NonInteractive, [int]$PromptTimeoutSeconds = 8)
"U=$Username|NI=$NonInteractive|T=$PromptTimeoutSeconds"
'@
        # Mirror Invoke-SelfElevation exactly: same $iexArgs quoting (single quotes,
        # embedded ' doubled) and the same command template, with the irm download
        # swapped for a local read -- the shape under test is the scriptblock
        # invocation and token binding, not the transport.
        $escapedPath = $stub -replace "'", "''"
        $iexArgs     = @("-Username", "'my user''s'", "-NonInteractive", "-PromptTimeoutSeconds", "'12'")
        $command     = "& ([scriptblock]::Create((Get-Content -Raw '$escapedPath'))) $($iexArgs -join ' ')"

        $psExe  = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
        $result = & $psExe -NoProfile -Command $command
        $LASTEXITCODE | Should -Be 0
        $result | Should -Be "U=my user's|NI=True|T=12"
    }
}

# -----------------------------------------------------------------------------
Describe "Select-NamingMode switch precedence" {

    It "-Folder -> User mode" {
        Select-NamingMode -Folder | Should -Be "User"
    }

    It "-Gateway -> Gateway mode" {
        Select-NamingMode -Gateway | Should -Be "Gateway"
    }

    It "-NonInteractive -> Gateway mode" {
        Select-NamingMode -NonInteractive | Should -Be "Gateway"
    }

    It "-Folder takes priority over -Gateway" {
        Select-NamingMode -Folder -Gateway | Should -Be "User"
    }

    It "-Folder takes priority over -NonInteractive" {
        Select-NamingMode -Folder -NonInteractive | Should -Be "User"
    }

    It "-FolderPath implies User mode" {
        Select-NamingMode -FolderPath "D:\Profiles" | Should -Be "User"
    }

    It "-Username implies User mode" {
        Select-NamingMode -Username "jdoe" | Should -Be "User"
    }

    It "explicit -Gateway beats an implied -FolderPath" {
        Select-NamingMode -Gateway -FolderPath "D:\Profiles" | Should -Be "Gateway"
    }

    It "implied User mode still applies in NonInteractive" {
        Select-NamingMode -NonInteractive -Username "jdoe" | Should -Be "User"
    }

    Context "-PromptTimeoutSeconds (OQ-004)" {

        It "Is accepted alongside an explicit mode switch (prompt never reached)" {
            Select-NamingMode -Gateway -PromptTimeoutSeconds 30 | Should -Be "Gateway"
        }

        It "Rejects 0 (ValidateRange 1-300)" {
            { Select-NamingMode -Gateway -PromptTimeoutSeconds 0 } | Should -Throw
        }

        It "Rejects values above 300 (ValidateRange 1-300)" {
            { Select-NamingMode -Gateway -PromptTimeoutSeconds 301 } | Should -Throw
        }

        It "Defaults to 8" {
            $ast = (Get-Command Select-NamingMode).ScriptBlock.Ast.Body.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'PromptTimeoutSeconds' }
            $ast.DefaultValue.Value | Should -Be 8
        }
    }
}

# -----------------------------------------------------------------------------
Describe "Remove-OldLogFile (log retention)" {

    BeforeEach {
        $script:LogDir = Join-Path $TestDrive "Hostname-Rename"
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null

        # An expired run log, a fresh run log, and an expired NON-matching file.
        $old   = Join-Path $script:LogDir "Hostname-Rename_OLDPC_20200101-000000.log"
        $new   = Join-Path $script:LogDir "Hostname-Rename_NEWPC_20990101-000000.log"
        $other = Join-Path $script:LogDir "unrelated.txt"
        Set-Content -LiteralPath $old   -Value "old"
        Set-Content -LiteralPath $new   -Value "new"
        Set-Content -LiteralPath $other -Value "keep me"
        (Get-Item -LiteralPath $old).LastWriteTime   = (Get-Date).AddDays(-40)
        (Get-Item -LiteralPath $other).LastWriteTime = (Get-Date).AddDays(-40)
    }

    AfterEach {
        Remove-Item -LiteralPath $script:LogDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Removes matching run logs older than the retention window" {
        Remove-OldLogFile -Directory $script:LogDir -RetentionDays 30
        Test-Path (Join-Path $script:LogDir "Hostname-Rename_OLDPC_20200101-000000.log") | Should -BeFalse
    }

    It "Keeps run logs inside the retention window" {
        Remove-OldLogFile -Directory $script:LogDir -RetentionDays 30
        Test-Path (Join-Path $script:LogDir "Hostname-Rename_NEWPC_20990101-000000.log") | Should -BeTrue
    }

    It "Never touches files that are not this tool's run logs" {
        Remove-OldLogFile -Directory $script:LogDir -RetentionDays 30
        Test-Path (Join-Path $script:LogDir "unrelated.txt") | Should -BeTrue
    }

    It "Removes nothing under -WhatIf (a dry run makes no changes)" {
        Remove-OldLogFile -Directory $script:LogDir -RetentionDays 30 -WhatIf
        Test-Path (Join-Path $script:LogDir "Hostname-Rename_OLDPC_20200101-000000.log") | Should -BeTrue
    }

    It "Does not throw when the directory does not exist" {
        { Remove-OldLogFile -Directory (Join-Path $TestDrive "no-such-dir") -RetentionDays 30 } |
            Should -Not -Throw
    }

    It "Respects a custom retention window" {
        Remove-OldLogFile -Directory $script:LogDir -RetentionDays 60
        Test-Path (Join-Path $script:LogDir "Hostname-Rename_OLDPC_20200101-000000.log") | Should -BeTrue
    }
}

# -----------------------------------------------------------------------------
Describe "Get-NetworkContext" {

    Context "Known gateway -- returns correct context" {

        It "Returns the right ORG/WH/LOC for a mapped gateway" {
            $result = Get-NetworkContext -Gateway "192.0.2.1"
            $result.ORG | Should -Be "AC"
            $result.WH  | Should -Be "01"
            $result.LOC | Should -Be "R"
        }
    }

    Context "Null or empty gateway -- always throws" {

        It "Throws with a 'no gateway detected' message when gateway is empty" {
            { Get-NetworkContext -Gateway "" } |
                Should -Throw -ExpectedMessage "*No default gateway*"
        }

        It "Throws when gateway is null (passed as empty string)" {
            { Get-NetworkContext -Gateway $null } |
                Should -Throw
        }
    }

    Context "Unmapped gateway -- NonInteractive throws" {

        It "Throws with actionable GATEWAY_MAP message in NonInteractive mode" {
            { Get-NetworkContext -Gateway "10.0.0.1" -NonInteractive } |
                Should -Throw -ExpectedMessage "*GATEWAY_MAP*"
        }
    }

    Context "Unmapped gateway -- Interactive returns fallback" {

        It "Returns FALLBACK_CONTEXT in interactive mode" {
            $result = Get-NetworkContext -Gateway "10.0.0.1"
            $result.ORG | Should -Be "XX"
            $result.WH  | Should -Be "99"
            $result.LOC | Should -Be "X"
        }
    }
}

# -----------------------------------------------------------------------------
Describe "15-character NetBIOS limit -- integration" {

    It "Gateway mode: all valid department+type combinations stay within 15 chars" {
        $depts  = @("CS","SR","OP","HQ","IT","WS")
        $types  = @("VM","SV","MD","ET","LT","DT","PB","TB")
        $serial = "A3F9"   # representative 4-char serial

        foreach ($dept in $depts) {
            foreach ($type in $types) {
                $name = New-DeviceName -ORG "AC" -WH "01" -LOC "R" `
                                       -Department $dept -Type $type -Serial $serial
                $name.Length | Should -BeLessOrEqual 15 `
                    -Because "'$name' ($($name.Length) chars) exceeds the 15-char NetBIOS limit"
            }
        }
    }

    It "User mode: 11-char truncated name + 4-char prefix = exactly 15" {
        $name = New-UserDeviceName -WH "01" -LOC "R" -Name "12345678901"
        $name | Should -Be "01R-12345678901"
        $name.Length | Should -Be 15
    }
}
