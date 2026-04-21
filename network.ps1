# network.ps1
# Handles: gateway detection and network context resolution

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

    Write-Warning "Gateway '$Gateway' not found in GATEWAY_MAP -- using fallback context (RS/XX/X)."
    return @{ ORG = "RS"; WH = "XX"; LOC = "X" }
}
