# network.ps1
# Handles: gateway detection and network context resolution

# Gateway map -- one entry per site gateway. ORG must be exactly 2 chars (15-char
# NetBIOS limit). Example IPs use RFC 5737 ranges; replace with real gateways before deploying.
$script:GATEWAY_MAP = @{
    # -- CONFIGURE YOUR SITES HERE --
    "192.0.2.1"    = @{ ORG = "AC"; WH = "01"; LOC = "R" }
    "192.0.2.2"    = @{ ORG = "AC"; WH = "02"; LOC = "W" }
    "198.51.100.1" = @{ ORG = "AC"; WH = "03"; LOC = "F" }
    "198.51.100.2" = @{ ORG = "AC"; WH = "04"; LOC = "C" }
    "203.0.113.1"  = @{ ORG = "AC"; WH = "09"; LOC = "S" }
}

# Fallback context for an unmapped gateway in interactive mode (NonInteractive throws
# instead). Use sentinel ORG/WH/LOC values visually distinct from real site codes so
# these devices are easy to spot in AD/Intune.
$script:FALLBACK_CONTEXT = @{ ORG = "XX"; WH = "99"; LOC = "X" }

function Get-DefaultGateway {
    # IPv4 next-hop of the lowest-effective-metric default route, or $null if none.
    # Get-NetRoute is metric-aware, so an active VPN or a second NIC no longer wins
    # by adapter-enumeration luck (BUG-019); effective metric = RouteMetric +
    # InterfaceMetric, the same sum Windows uses for route selection. (The property
    # is InterfaceMetric -- 'ifMetric' is only a display column, and Sort-Object on
    # a nonexistent property silently does not sort.)
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.NextHop -ne '0.0.0.0' } |
            Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric } |
            Select-Object -First 1
        if ($route) { return $route.NextHop }
    } catch {
        # No IPv4 default route, or Get-NetRoute unavailable -- fall through to the
        # legacy adapter query below.
        Write-Verbose "Get-NetRoute lookup failed ($($_.Exception.Message)) -- using the legacy adapter query."
    }

    # Legacy fallback, filtered to IPv4: GATEWAY_MAP is IPv4-keyed and
    # DefaultIPGateway may also list IPv6 literals that could never match it.
    (Get-CimInstance Win32_NetworkAdapterConfiguration |
        Where-Object { $_.IPEnabled -and $_.DefaultIPGateway } |
        Select-Object -ExpandProperty DefaultIPGateway |
        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } |
        Select-Object -First 1)
}

function Get-NetworkContext {
    # Resolve ORG/WH/LOC from a gateway IP. Null/empty always throws; an unmapped gateway
    # throws in NonInteractive but warns and returns the fallback interactively.
    param (
        [string]$Gateway,
        [switch]$NonInteractive
    )

    # No network adapter reported a default gateway at all
    if ([string]::IsNullOrEmpty($Gateway)) {
        throw (
            "No default gateway was detected on this machine. " +
            "Ensure the device has a network connection before running this tool."
        )
    }

    $mapping = $script:GATEWAY_MAP[$Gateway]
    if ($mapping) { return $mapping }

    if ($NonInteractive) {
        throw (
            "Gateway '$Gateway' was not found in GATEWAY_MAP. " +
            "Add it to network.ps1 and redeploy. " +
            "Halting -- a silently incorrect device name is worse than a failed rename."
        )
    }

    Write-Warning ""
    Write-Warning "  !! Gateway '$Gateway' is not in GATEWAY_MAP."
    Write-Warning "  !! Fallback context will be used: ORG=$($script:FALLBACK_CONTEXT.ORG)  WH=$($script:FALLBACK_CONTEXT.WH)  LOC=$($script:FALLBACK_CONTEXT.LOC)"
    Write-Warning "  !! The renamed device will be identifiable by these sentinel values."
    Write-Warning "  !! Add this gateway to `$GATEWAY_MAP in network.ps1 to resolve this."
    Write-Warning ""
    return $script:FALLBACK_CONTEXT
}