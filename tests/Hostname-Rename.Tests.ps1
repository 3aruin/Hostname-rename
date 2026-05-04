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
    # Dot-source modules directly -- no need for launcher or network access
    . "$PSScriptRoot/../naming.ps1"
    . "$PSScriptRoot/../network.ps1"
    . "$PSScriptRoot/../device.ps1"
}

# ─────────────────────────────────────────────────────────────────────────────
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

    Context "Full name overflows — department is omitted" {

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

    Context "Both full and shortened overflow — throws" {

        It "Throws when even the shortened name exceeds 15 characters" {
            # Pathological: ORG=AC, WH=01, LOC=R, Type=DT, Serial=TOOLONG9 → AC01R-DT-TOOLONG9 = 17
            { New-DeviceName -ORG "AC" -WH "01" -LOC "R" -Department "CS" -Type "DT" -Serial "TOOLONG9" } |
                Should -Throw
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
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
        # "01R-JaneDoe12345" = 16 → truncate Name to 11
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

# ─────────────────────────────────────────────────────────────────────────────
Describe "Get-SerialLast4" {

    Context "Serial longer than 4 chars" {
        It "Returns the last 4 chars of a cleaned 8-char serial" {
            # Cleaned: VMWA3F9B2C1 -> last 4: B2C1
            # Test cleaning + last-4 extraction via a helper wrapper.
            # TODO (v3.1): refactor Get-SerialLast4 so the cleaning logic is in a
            # standalone helper function callable without WMI -- then these
            # tests can exercise the real implementation rather than a copy.
            $fn = {
                param($s)
                $clean = ($s -replace '[^A-Za-z0-9]', '').ToUpper()
                if ($clean.Length -ge 4) { return $clean.Substring($clean.Length - 4) }
                return $clean.PadLeft(4, '0')
            }
            & $fn "VMW-A3F9B2C1" | Should -Be "B2C1"
        }

        It "Strips hyphens and returns last 4" {
            $fn = { param($s)
                $c = ($s -replace '[^A-Za-z0-9]', '').ToUpper()
                if ($c.Length -ge 4) { return $c.Substring($c.Length - 4) }
                return $c.PadLeft(4, '0') }
            & $fn "SN-##-1234" | Should -Be "1234"
        }

        It "Normalises lowercase to uppercase" {
            $fn = { param($s)
                $c = ($s -replace '[^A-Za-z0-9]', '').ToUpper()
                if ($c.Length -ge 4) { return $c.Substring($c.Length - 4) }
                return $c.PadLeft(4, '0') }
            & $fn "abcd" | Should -Be "ABCD"
        }
    }

    Context "Serial shorter than 4 chars -- pad with leading zeros" {
        # $script: scope is required because BeforeAll runs in a separate scope
        # from the It blocks below -- without it, $fn is gone by the time the
        # It blocks try to invoke it. Same pattern as the Get-UserName fix.
        BeforeAll {
            $script:fn = {
                param($s)
                $c = ($s -replace '[^A-Za-z0-9]', '').ToUpper()
                if ($c.Length -ge 4) { return $c.Substring($c.Length - 4) }
                return $c.PadLeft(4, '0')
            }
        }

        It "3 chars -- left-pads to 4" {
            & $script:fn "ABC"   | Should -Be "0ABC"
        }
        It "1 char -- left-pads to 4" {
            & $script:fn "X"     | Should -Be "000X"
        }
        It "Empty string -- four zeros" {
            & $script:fn ""      | Should -Be "0000"
        }
        It "All special chars -- four zeros" {
            & $script:fn "---"   | Should -Be "0000"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe "Get-UserName name cleaning" {

    # Expose the cleaning logic via a scriptblock to test without hitting C:\Users.
    # $script: scope is required because BeforeAll runs in a separate scope from
    # the It blocks below — without it, the analyzer also flags the variable as
    # assigned-but-never-used (PSUseDeclaredVarsMoreThanAssignments), which is a
    # false positive caused by the cross-scope reference in Pester.
    BeforeAll {
        $script:clean = {
            param($selected)
            $c = $selected
            foreach ($sep in '@', '_') {
                $idx = $c.IndexOf($sep)
                if ($idx -gt 0) { $c = $c.Substring(0, $idx) }
            }
            $c = ($c -replace '[^a-zA-Z0-9]', '')
            if ($c.Length -eq 0) { throw "Empty after cleaning" }
            $c.Substring(0, [Math]::Min(11, $c.Length))
        }
    }

    It "Strips @ suffix (standard UPN)" {
        & $script:clean "jane.doe@contoso.com" | Should -Be "janedoe"
    }

    It "Strips _ suffix (Entra joined UPN style)" {
        & $script:clean "JaneDoe_contoso_com" | Should -Be "JaneDoe"
    }

    It "Leaves plain names unchanged" {
        & $script:clean "JohnSmith" | Should -Be "JohnSmith"
    }

    It "Removes dots in prefix (UPN style: first.last)" {
        & $script:clean "john.smith" | Should -Be "johnsmith"
    }

    It "Truncates to 11 characters" {
        & $script:clean "VeryLongNameHere" | Should -Be "VeryLongNam"
    }

    It "Result is never longer than 11 characters" {
        (& $script:clean "AVeryVeryVeryLongFolderName").Length | Should -BeLessOrEqual 11
    }

    It "Processes @ before _ — strips at @ first, then _ in remainder" {
        # user_name@domain.com  → strip @  → user_name → strip _  → user
        & $script:clean "user_name@domain.com" | Should -Be "user"
    }

    It "Throws when cleaned result is empty" {
        { & $script:clean "___" } | Should -Throw
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe "Select-NamingMode switch precedence" {

    It "-Folder → User mode" {
        Select-NamingMode -Folder | Should -Be "User"
    }

    It "-Gateway → Gateway mode" {
        Select-NamingMode -Gateway | Should -Be "Gateway"
    }

    It "-NonInteractive → Gateway mode" {
        Select-NamingMode -NonInteractive | Should -Be "Gateway"
    }

    It "-Folder takes priority over -Gateway" {
        Select-NamingMode -Folder -Gateway | Should -Be "User"
    }

    It "-Folder takes priority over -NonInteractive" {
        Select-NamingMode -Folder -NonInteractive | Should -Be "User"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe "Get-NetworkContext" {

    Context "Known gateway — returns correct context" {

        It "Returns the right ORG/WH/LOC for a mapped gateway" {
            $result = Get-NetworkContext -Gateway "192.0.2.1"
            $result.ORG | Should -Be "AC"
            $result.WH  | Should -Be "01"
            $result.LOC | Should -Be "R"
        }
    }

    Context "Null or empty gateway — always throws" {

        It "Throws with a 'no gateway detected' message when gateway is empty" {
            { Get-NetworkContext -Gateway "" } |
                Should -Throw -ExpectedMessage "*No default gateway*"
        }

        It "Throws when gateway is null (passed as empty string)" {
            { Get-NetworkContext -Gateway $null } |
                Should -Throw
        }
    }

    Context "Unmapped gateway — NonInteractive throws" {

        It "Throws with actionable GATEWAY_MAP message in NonInteractive mode" {
            { Get-NetworkContext -Gateway "10.0.0.1" -NonInteractive } |
                Should -Throw -ExpectedMessage "*GATEWAY_MAP*"
        }
    }

    Context "Unmapped gateway — Interactive returns fallback" {

        It "Returns FALLBACK_CONTEXT in interactive mode" {
            $result = Get-NetworkContext -Gateway "10.0.0.1"
            $result.ORG | Should -Be "XX"
            $result.WH  | Should -Be "99"
            $result.LOC | Should -Be "X"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Describe "15-character NetBIOS limit — integration" {

    It "Gateway mode: all valid department+type combinations stay within 15 chars" {
        $depts  = @("CS","SR","OP","HQ","IT","WS")
        $types  = @("VM","SV","MD","ET","LT","DT")
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
