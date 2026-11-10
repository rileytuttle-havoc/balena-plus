@{
    RootModule        = 'BalenaPlus.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '8f3a1d42-6c7b-4e95-9a18-2d5e7b4c0f31'
    Author            = 'Riley Tuttle'
    Description       = 'Wrapper around the balena CLI: device-name resolution, fleet picker, login on demand, and ssh/tunnel/logs/ps/uuid/devices helpers.'

    # Windows PowerShell 5.1 is what ships with Windows 10 and 11, so that is
    # the floor. Everything here also runs on PowerShell 7.
    PowerShellVersion = '5.1'

    FunctionsToExport = @('Invoke-BalenaPlus', 'Invoke-BalenaRaw', 'Update-BalenaPlus')
    AliasesToExport   = @('balena', 'balena-plus', 'balena-raw')
    CmdletsToExport   = @()
    VariablesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('balena', 'balenaCloud', 'IoT', 'CLI', 'wrapper')
            ProjectUri = 'https://github.com/rileytuttle-havoc/balena-plus'
        }
    }
}
