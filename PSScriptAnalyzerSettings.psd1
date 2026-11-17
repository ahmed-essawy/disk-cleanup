@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @('PSUseSingularNouns')
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
