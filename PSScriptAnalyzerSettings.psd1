@{
    # PSScriptAnalyzer settings for Hostname-Rename
    #
    # Excluded rules:
    #
    #   PSAvoidUsingWriteHost
    #     This is an interactive console tool. Write-Host is used intentionally
    #     for menus, prompts, and operator-visible status messages.
    #       - Write-Output would corrupt function return values (the success
    #         stream is how PowerShell returns data).
    #       - Write-Information is invisible unless the caller explicitly sets
    #         $InformationPreference = 'Continue', which defeats the purpose
    #         of an end-user-facing rename tool.
    #     Write-Verbose is still used elsewhere in the codebase for debug
    #     detail; that distinction is preserved.

    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
    )
}
