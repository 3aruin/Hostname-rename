# network.ps1
# Handles: gateway detection and network context resolution

# -- Gateway Map --------------------------------------------------------------
# Add an entry here for every site gateway this tool will be deployed to.
# Key   = default gateway IP (string)
# ORG   = two-character organisation code   — must be exactly 2 chars to stay within
#         the 15-character Windows NetBIOS hostname limit
# WH    = two-digit site/warehouse number   (e.g. "01", "09")
# LOC   = single location letter            (e.g. "R", "W")
#
# IPs below use RFC 5737 documentation ranges (192.0.2.x, 198.51.100.x, 203.0.113.x).
# Replace with your real gateway IPs before deployment.

$script:GATEWAY_MAP = @{
    # -- CONFIGURE YOUR SITES HERE --
    "192.0.2.1"    = @{ ORG = "AC"; WH = "01"; LOC = "R" }
    "192.0.2.2"    = @{ ORG = "AC"; WH = "02"; LOC = "W" }
    "198.51.100.1" = @{ ORG = "AC"; WH = "03"; LOC = "F" }
    "198.51.100.2" = @{ ORG = "AC"; WH = "04"; LOC = "C" }
    "203.0.113.1"  = @{ ORG = "AC"; WH = "09"; LOC = "S" }
}

# -- Fallback Context ---------------------------------------------------------
# Used when a gateway is not found in GATEWAY_MAP during an interactive run.
# Set ORG to a code that is visually distinct from your real ORG codes so that
# devices renamed on an unknown network are immediately identifiable in AD/Intune.
# Example: if your real code is "AC", use "AX" as your fallback signal.
# WH = "99" and LOC = "X" are recommended sentinel values.
#
# In NonInteractive / MDM mode an unmapped gateway throws instead of using this
# fallback -- a silently wrong name in an automated deployment is worse than a
# failed deployment.

$script:FALLBACK_CONTEXT = @{ ORG = "XX"; WH = "99"; LOC = "X" }
# -----------------------------------------------------------------------------

function Get-DefaultGateway {
    <#
    .SYNOPSIS
        Returns the first enabled adapter's default gateway IP, or $null if
        no gateway is available.
    #>
    (Get-CimInstance Win32_NetworkAdapterConfiguration |
        Where-Object { $_.IPEnabled -and $_.DefaultIPGateway } |
        Select-Object -ExpandProperty DefaultIPGateway -First 1)
}

function Get-NetworkContext {
    <#
    .SYNOPSIS
        Resolves ORG/WH/LOC context from a gateway IP.

    .NOTES
        If the gateway is null/empty (no network adapter has a default gateway):
          - Always throws with a clear "no gateway detected" message — this
            condition is equally wrong in interactive and non-interactive modes.

        If the gateway is not in GATEWAY_MAP:
          - NonInteractive mode  : throws immediately. A silently wrong device name
                                   in an automated deployment is worse than a hard stop.
                                   Add the gateway to $GATEWAY_MAP and redeploy.
          - Interactive mode     : warns prominently and returns $FALLBACK_CONTEXT so
                                   the technician can still complete the rename. The
                                   resulting name will contain the fallback ORG/WH/LOC
                                   codes, making the device easy to find and correct later.
    #>
    param (
        [string]$Gateway,
        [switch]$NonInteractive
    )

    # Guard: no network adapter reported a default gateway at all
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
