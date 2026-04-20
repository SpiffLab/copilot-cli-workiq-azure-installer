@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                      # Intentional for colored user-facing output
        'PSAvoidUsingEmptyCatchBlock',                # Intentional probes (best-effort detection)
        'PSUseShouldProcessForStateChangingFunctions',# Not a public cmdlet; internal helper
        'PSUseSingularNouns',                         # Test-CommandExists reads well plural
        'PSReviewUnusedParameter'                     # False positives for script-scope param access
    )
}

