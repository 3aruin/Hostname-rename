function Write-Log { 
    param(
        [string]$Path,
        [string]$Message
    )
    try {
        Add-Content -Path $Path -Value $Message
    } catch {
        # Updated error message for proper variable interpolation
        Write-Error "Failed to write log to $($Path): $($_.Exception.Message)"
    }
}