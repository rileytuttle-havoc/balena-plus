# Lint settings for the Windows port. The point of the compatibility rules is
# to catch PowerShell 7-only syntax and cmdlets that would break on the
# Windows PowerShell 5.1 that ships with Windows 10/11.
#
#   Import-Module PSScriptAnalyzer
#   Invoke-ScriptAnalyzer -Path windows -Recurse -Settings windows/PSScriptAnalyzerSettings.psd1
@{
    IncludeDefaultRules = $true
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
        PSUseCompatibleCmdlets = @{
            Enable        = $true
            Compatibility = @(
                'desktop-5.1.14393.206-windows',
                'core-6.1.0-windows'
            )
        }
    }
    ExcludeRules = @(
        # This is a console tool. Operator-facing output goes to the host on
        # purpose, so that pipeline output stays clean -- 'balena uuid foo'
        # has to be pipeable, and the "+ balena ..." teaching lines must not
        # end up in the pipe alongside the UUID.
        'PSAvoidUsingWriteHost',

        # Deliberate. Every empty catch in the module wraps a best-effort
        # operation -- warming a completion cache, restoring console encoding,
        # the once-a-day update check -- where failing the user's actual
        # command would be the wrong trade. They are individually commented.
        'PSAvoidUsingEmptyCatchBlock',

        # Register-ArgumentCompleter dictates the completer's five-parameter
        # signature; we genuinely do not need three of them.
        'PSReviewUnusedParameter',

        # Private helpers are named after the balena subcommand they
        # implement: 'logs', 'ps', 'devices'. Invoke-PlusLog would be a
        # worse name than Invoke-PlusLogs, not a better one.
        'PSUseSingularNouns',

        # The test file's assertion helper, T, is deliberately terse and
        # called positionally -- 'T name want got' reads as a table of
        # cases, which is the point.
        'PSAvoidUsingPositionalParameters'
    )
}
