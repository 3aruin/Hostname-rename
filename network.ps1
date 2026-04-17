# network.ps1
# Handles: gateway detection, network context resolution, folder context, user profile path

# -- Gateway Map --------------------------------------------------------------
# Add new sites here. Each key is a default gateway IP.
# ORG = organisation code, WH = two-digit warehouse/site number, LOC = location letter

$script:GATEWAY_MAP = @{
    "10.72.0.1" = @{ ORG = "RB"; WH = "00"; LOC = "A" }
    "10.72.1.1" = @{ ORG = "RB"; WH = "01"; LOC = "R" }
    "10.72.2.1" = @{ ORG = "RB"; WH = "02"; LOC = "W" }
    "10.72.3.1" = @{ ORG = "RB"; WH = "03"; LOC = "F" }
    "10.72.4.1" = @{ ORG = "RB"; WH = "04"; LOC = "C" }
    "10.72.9.1" = @{ ORG = "RB"; WH = "09"; LOC = "S" }
}
# -----------------------------------------------------------------------------

function Get-DefaultGateway {
    <#
    .SYNOPSIS
        Returns the first enabled adapter's default gateway IP.
    #>
    (Get-CimInstance Win32_NetworkAdapterConfiguration |
        Where-Object { $_.IPEnabled -and $_.DefaultIPGateway } |
        Select-Object -ExpandProperty DefaultIPGateway -First 1)
}

function Get-NetworkContext {
    <#
    .SYNOPSIS
        Resolves ORG/WH/LOC context from a gateway IP.
        Returns fallback values if the gateway is not in the map.
    #>
    param (
        [string]$Gateway
    )

    $mapping = $script:GATEWAY_MAP[$Gateway]
    if ($mapping) { return $mapping }

    Write-Warning "Gateway '$Gateway' not found in GATEWAY_MAP -- using fallback context (RS/99/X)."
    return @{ ORG = "RS"; WH = "99"; LOC = "X" }
}

function Get-UserProfilePath {
    <#
    .SYNOPSIS
        Returns the C:\Users\<name> path for a matched local user.
        If Username is omitted, picks the first enabled non-system local user.
    #>
    param (
        [string]$Username = ""
    )

    # Exclude common built-in accounts when no specific username is requested
    $systemAccounts = @("Administrator", "DefaultAccount", "Guest", "WDAGUtilityAccount")

    if ($Username) {
        $user = Get-LocalUser |
            Where-Object { $_.Name -like "*$Username*" } |
            Select-Object -First 1
    } else {
        $user = Get-LocalUser |
            Where-Object { $_.Enabled -and $_.Name -notin $systemAccounts } |
            Select-Object -First 1
    }

    if (-not $user) { throw "No matching local user found." }

    $path = "C:\Users\$($user.Name)"

    if (-not (Test-Path $path)) {
        throw "User profile path does not exist: $path"
    }

    return $path
}

function Get-FolderContext {
    <#
    .SYNOPSIS
        Derives ORG/WH/LOC context from a folder name chosen under BasePath.
        In NonInteractive mode the first folder is used automatically.

    .NOTES
        ORG is currently hardcoded to "RB" for single-organisation deployments.
        TODO: If multi-org support is needed, derive ORG from GATEWAY_MAP or a parameter.
    #>
    param (
        [string]$BasePath,
        [switch]$NonInteractive
    )

    if (-not (Test-Path $BasePath)) {
        throw "Base path does not exist: $BasePath"
    }

    $folders = Get-ChildItem -Path $BasePath -Directory

    if (-not $folders) {
        throw "No subdirectories found under: $BasePath"
    }

    if ($NonInteractive) {
        $selected = $folders[0].Name
    } else {
        for ($i = 0; $i -lt $folders.Count; $i++) {
            "{0}. {1}" -f ($i + 1), $folders[$i].Name
        }

        do {
            $choice = Read-Host "Select folder number"
        } until ($choice -as [int] -and [int]$choice -ge 1 -and [int]$choice -le $folders.Count)

        $selected = $folders[[int]$choice - 1].Name
    }

    # Strip non-alphanumeric characters, uppercase, cap at 15 chars
    $clean = ($selected -replace '[^a-zA-Z0-9]', '').ToUpper()
    $clean = $clean.Substring(0, [Math]::Min(15, $clean.Length))

    if ($clean.Length -lt 3) {
        throw "Folder name '$selected' resolves to fewer than 3 usable characters."
    }

    return @{
        ORG = "RB"
        WH  = $clean.Substring(0, 2)
        LOC = $clean.Substring(2, 1)
        RAW = $clean
    }
}
