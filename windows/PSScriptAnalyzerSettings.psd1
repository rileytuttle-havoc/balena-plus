# Lint settings for the Windows port. The point of the compatibility rules is
# to catch PowerShell 7-only syntax, cmdlets, parameters and .NET types that
# would break on the Windows PowerShell 5.1 that ships with Windows 10/11.
#
# They matter more than usual here, because development happens on Linux,
# where only pwsh 7 exists. These rules check the source against a captured
# profile of a real 5.1 install, which is the nearest thing to running it.
# See windows/README.md for how to get a real 5.1 in front of it.
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
        # Windows PowerShell 5.1 on Windows 10 1809, and PowerShell 7.0 on the
        # same -- the two runtimes this has to work on. PSScriptAnalyzer ships
        # these profiles; 'Get-ChildItem $PSScriptAnalyzerModule/compatibility_profiles'
        # lists the rest.
        PSUseCompatibleCommands = @{
            Enable = $true
            TargetProfiles = @(
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework',
                'win-8_x64_10.0.17763.0_7.0.0_x64_3.1.2_core'
            )
        }
        # Types and their static members only -- it does not see instance
        # method overloads, so .NET Core-only ones like Process.Kill($true)
        # and ProcessStartInfo.ArgumentList still have to be caught by hand.
        # Both are commented at their call sites in the module for that reason.
        PSUseCompatibleTypes = @{
            Enable = $true
            TargetProfiles = @(
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework',
                'win-8_x64_10.0.17763.0_7.0.0_x64_3.1.2_core'
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
