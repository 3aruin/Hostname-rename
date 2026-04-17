# naming.ps1
# Handles: naming mode selection, context resolution, device name construction
# Depends on: network.ps1 (Get-FolderContext, Get-NetworkContext)

function Select-NamingMode {
    <#
    .SYNOPSIS
        Determines whether to derive context from the network gateway or a folder name.
        Explicit switches take priority. Interactive mode presents a 15-second timed prompt.
    #>
    param (
        [switch]$Folder,
        [switch]$Gateway,
        [switch]$NonInteractive
    )

    if ($Folder)         { return "Folder" }
    if ($Gateway)        { return "Gateway" }
    if ($NonInteractive) { return "Gateway" }

    Write-Host ""
    Write-Host "Select naming source:"
    Write-Host "  1. Gateway  (default)"
    Write-Host "  2. Folder   (reads from Desktop subfolder)"
    Write-Host ""

    $job = Start-Job -ScriptBlock { Read-Host "Choice (15s timeout)" }

    if (Wait-Job $job -Timeout 15) {
        $choice = Receive-Job $job
    } else {
        Stop-Job $job
        Write-Host "No input received — defaulting to Gateway."
        return "Gateway"
    }

    Remove-Job $job -Force

    if ($choice -eq "2") { return "Folder" }
    return "Gateway"
}

function Get-NamingContext {
    <#
    .SYNOPSIS
        Returns the ORG/WH/LOC context hashtable for the selected mode.
        Falls back to Gateway if Folder mode fails.
    .NOTES
        Requires Get-FolderContext (network.ps1) and Get-NetworkContext (network.ps1).
    #>
    param (
        [string]$Mode,
        [string]$Gateway,
        [string]$FolderPath,
        [switch]$NonInteractive
    )

    if ($Mode -eq "Folder") {
        try {
            return Get-FolderContext -BasePath $FolderPath -NonInteractive:$NonInteractive
        } catch {
            Write-Warning "Folder mode failed ($_) — falling back to Gateway."
        }
    }

    return Get-NetworkContext -Gateway $Gateway
}

function New-DeviceName {
    <#
    .SYNOPSIS
        Assembles the final device name from its components.
        Format: {ORG}{WH}{LOC}-{Dept}{Type}-{Serial}  (max 15 chars)
        If the full name exceeds 15 characters, department is dropped.
        Throws if even the shortened form exceeds 15 characters.
    #>
    param (
        [string]$ORG,
        [string]$WH,
        [string]$LOC,
        [string]$Department,
        [string]$Type,
        [string]$Serial
    )

    $full      = "$ORG$WH$LOC-$Department$Type-$Serial"
    $shortened = "$ORG$WH$LOC-$Type-$Serial"

    if ($full.Length -le 15)      { return $full }
    if ($shortened.Length -le 15) {
        Write-Warning "Full name '$full' exceeded 15 chars — department omitted."
        return $shortened
    }

    throw "Device name '$shortened' still exceeds 15 characters. Review ORG/WH/LOC/Serial values."
}
