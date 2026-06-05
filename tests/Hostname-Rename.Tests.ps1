# tests/Hostname-Rename.Tests.ps1
#
# Pester v5 unit tests for Hostname-Rename.
# Covers all pure-logic functions (no WMI / OS calls required).
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
