BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\scripts\common.ps1')
}

Describe 'TestHelpers' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'creates the sandbox under tests/.sandbox' {
        $expectedBase = Join-Path (Get-RepoRoot) 'tests\.sandbox'
        $script:sb.Root.StartsWith($expectedBase, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        (Test-Path -LiteralPath $script:sb.Home) | Should -BeTrue
        (Test-Path -LiteralPath $script:sb.Bin) | Should -BeTrue
        (Test-Path -LiteralPath $script:sb.Out) | Should -BeTrue
    }

    It 'redirects USERPROFILE, TEMP, LOCALAPPDATA and APPDATA into the sandbox' {
        $env:USERPROFILE | Should -Be $script:sb.Home
        $env:TEMP | Should -Be $script:sb.Temp
        $env:LOCALAPPDATA | Should -Be $script:sb.Local
        $env:APPDATA | Should -Be $script:sb.Roaming
        $env:DISK_CLEANUP_FORCE_NOT_ELEVATED | Should -Be '1'
    }

    It 'restores the environment and deletes the sandbox' {
        $savedProfile = $script:sb.Saved['USERPROFILE']
        $firstRoot = $script:sb.Root
        Restore-TestSandbox -Sandbox $script:sb
        $env:USERPROFILE | Should -Be $savedProfile
        (Test-Path -LiteralPath $firstRoot) | Should -BeFalse
        $script:sb = Initialize-TestSandbox
    }

    It 'stub logs its name and arguments' {
        & (Join-Path $script:sb.Bin 'npm.cmd') cache clean --force
        $calls = Get-StubCalls -Sandbox $script:sb
        $calls | Should -Contain 'npm cache clean --force'
    }

    It 'Add-SandboxFile applies LastWriteUtc' {
        $stamp = [datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc)
        $path = Add-SandboxFile -Path (Join-Path $script:sb.Home 'aged.bin') -Bytes 4 -LastWriteUtc $stamp
        [System.IO.File]::GetLastWriteTimeUtc($path) | Should -Be $stamp
    }
    It 'S1 refuses a sandbox file outside tests/.sandbox' {
        $outside = Join-Path (Get-RepoRoot) 'outside.bin'
        { Add-SandboxFile -Path $outside -Bytes 1 } | Should -Throw "Sandbox path outside tests/.sandbox*"
        (Test-Path -LiteralPath $outside) | Should -BeFalse
    }
}

Describe 'ConvertTo-NormalizedPath' {
    It 'removes a trailing backslash' {
        ConvertTo-NormalizedPath 'C:\a\b\' | Should -Be 'C:\a\b'
    }

    It 'keeps a drive root' {
        ConvertTo-NormalizedPath 'C:\' | Should -Be 'C:\'
    }
}

Describe 'Get-DiskCleanupRules' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'loads the repo rules file' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $rules.Count | Should -Be 36
        $rules[0].id | Should -Be 'user-temp'
    }

    It 'throws Rules file invalid for a missing file' {
        $missing = Join-Path $script:sb.Root 'none.json'
        { Get-DiskCleanupRules $missing } | Should -Throw 'Rules file invalid:*'
    }

    It 'throws Rules file invalid for invalid JSON' {
        $invalidJson = Join-Path $script:sb.Root 'invalid.json'
        [System.IO.File]::WriteAllText($invalidJson, '{ not json')
        { Get-DiskCleanupRules $invalidJson } | Should -Throw 'Rules file invalid:*'
    }

    It 'throws Rules file invalid for a rule without tier' {
        $fixPath = Write-FixtureRules -Sandbox $script:sb -Transform {
            param($d)
            $d.rules[0].PSObject.Properties.Remove('tier')
        }
        { Get-DiskCleanupRules $fixPath } | Should -Throw 'Rules file invalid:*'
    }
}

Describe 'Get-CurrentPlatform' {
    It 'returns windows on Windows' {
        Get-CurrentPlatform | Should -Be 'windows'
    }

    It 'returns a single string' {
        $p = Get-CurrentPlatform
        ($p -is [string]) | Should -BeTrue
    }
}

Describe 'Get-RulesForPlatform' {
    It 'keeps only rules for the platform' {
        $dummy = @(
            [pscustomobject]@{ id = 'r1'; platforms = @('windows') },
            [pscustomobject]@{ id = 'r2'; platforms = @('linux') },
            [pscustomobject]@{ id = 'r3'; platforms = @('windows', 'macos') }
        )
        $filtered = Get-RulesForPlatform -Rules $dummy -Platform 'windows'
        $ids = @($filtered | ForEach-Object { $_.id })
        $ids | Should -Be @('r1', 'r3')
    }

    It 'keeps file order' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $filtered = Get-RulesForPlatform -Rules $rules -Platform 'windows'
        $expectedIds = @($rules | Where-Object { $_.platforms -contains 'windows' } | ForEach-Object { $_.id })
        $actualIds = @($filtered | ForEach-Object { $_.id })
        $actualIds | Should -Be $expectedIds
    }
}

Describe 'Get-MatchEntries' {
    It 'returns the entries for the platform' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $npm = $rules | Where-Object { $_.id -eq 'npm-cache' } | Select-Object -First 1
        $entries = Get-MatchEntries -Rule $npm -Platform 'windows'
        $entries | Should -Be @('${LOCALAPPDATA}/npm-cache')
    }

    It 'returns an empty array when the platform key is missing' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $wu = $rules | Where-Object { $_.id -eq 'windows-update-cache' } | Select-Object -First 1
        $entries = Get-MatchEntries -Rule $wu -Platform 'linux'
        $entries.Count | Should -Be 0
    }
}

Describe 'Resolve-MatchToken' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'expands a token and converts separators' {
        $res = Resolve-MatchToken '${TEMP}/x'
        $res | Should -Be "$($script:sb.Temp)\x"
    }

    It 'expands ProgramFiles(x86)' {
        $expected = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)') + '\y'
        $res = Resolve-MatchToken '${ProgramFiles(x86)}/y'
        $res | Should -Be $expected
    }

    It 'R9 drops an entry whose token is unset' {
        $res = Resolve-MatchToken '${DISK_CLEANUP_UNSET_VAR}/x'
        $null -eq $res | Should -BeTrue
    }

    It 'returns null when a token is empty' {
        [Environment]::SetEnvironmentVariable('DISK_CLEANUP_EMPTY_VAR', '', 'Process')
        $res = Resolve-MatchToken '${DISK_CLEANUP_EMPTY_VAR}/x'
        $null -eq $res | Should -BeTrue
    }
}

Describe 'Expand-MatchEntry' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'returns an existing literal path' {
        $npmDir = Join-Path $script:sb.Local 'npm-cache'
        [System.IO.Directory]::CreateDirectory($npmDir) | Out-Null
        $res = Expand-MatchEntry '${LOCALAPPDATA}/npm-cache'
        $res | Should -Be @($npmDir)
    }

    It 'returns nothing for a missing path' {
        $res = Expand-MatchEntry '${LOCALAPPDATA}/missing'
        $res.Count | Should -Be 0
    }

    It 'expands a wildcard segment' {
        $d1 = Join-Path $script:sb.Home 'OneDrive A'
        $d2 = Join-Path $script:sb.Home 'OneDrive B'
        [System.IO.Directory]::CreateDirectory($d1) | Out-Null
        [System.IO.Directory]::CreateDirectory($d2) | Out-Null
        $res = Expand-MatchEntry '${USERPROFILE}/OneDrive*'
        $res.Count | Should -Be 2
        $res | Should -Contain $d1
        $res | Should -Contain $d2
    }

    It 'returns nothing for a name pattern' {
        $res = Expand-MatchEntry '**/*.mdf'
        $res.Count | Should -Be 0
    }

    It 'R9 returns nothing when a token is unset' {
        $res = Expand-MatchEntry '${DISK_CLEANUP_UNSET_VAR}/x'
        $res.Count | Should -Be 0
    }
}

Describe 'Get-RulePaths' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'returns existing paths of a rule' {
        $npmDir = Join-Path $script:sb.Local 'npm-cache'
        [System.IO.Directory]::CreateDirectory($npmDir) | Out-Null
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $npm = $rules | Where-Object { $_.id -eq 'npm-cache' } | Select-Object -First 1
        $res = Get-RulePaths -Rule $npm -Platform 'windows'
        $res | Should -Be @($npmDir)
    }

    It 'filters by target' {
        $npmDir = Join-Path $script:sb.Local 'npm-cache'
        [System.IO.Directory]::CreateDirectory($npmDir) | Out-Null
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $npm = $rules | Where-Object { $_.id -eq 'npm-cache' } | Select-Object -First 1
        $res = Get-RulePaths -Rule $npm -Platform 'windows' -Target $script:sb.Out
        $res.Count | Should -Be 0
    }
}

Describe 'Get-CriticalSet' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'collects name patterns without the prefix' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $cs = Get-CriticalSet -Rules $rules -Platform 'windows'
        $cs.NamePatterns | Should -Contain '*.mdf'
        $cs.NamePatterns | Should -Contain '.git'
        $cs.NamePatterns | Should -Contain '*.bak'
    }

    It 'includes missing literal paths' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $cs = Get-CriticalSet -Rules $rules -Platform 'windows'
        $expectedDoc = "$($script:sb.Home)\Documents"
        $cs.Paths | Should -Contain $expectedDoc
    }

    It 'leaves out database-backups when the caller filters allowDuplicateRemoval' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $filtered = @($rules | Where-Object { -not $_.allowDuplicateRemoval })
        $cs = Get-CriticalSet -Rules $filtered -Platform 'windows'
        $cs.NamePatterns | Should -Not -Contain '*.bak'
    }

    It 'R5 m1 keeps a critical path with an 8.3 segment that cannot be expanded as unresolved' {
        $short = Join-Path $script:sb.Root 'HOME~1'
        [Environment]::SetEnvironmentVariable('USERPROFILE', $short, 'Process')
        $rule = [pscustomobject]@{
            id = 'credentials'
            tier = 'critical'
            platforms = @('windows')
            match = [pscustomobject]@{ windows = @('${USERPROFILE}/.aws') }
        }
        $cs = Get-CriticalSet -Rules @($rule) -Platform 'windows'
        $cs.Unresolved | Should -Contain (Join-Path $short '.aws')
        $cs.Paths | Should -Contain (Join-Path $short '.aws')
    }

    It 'R5 m1 expands a critical path with an existing 8.3 segment to the long name' {
        $short = Join-Path $script:sb.Root 'HOME~1'
        $long = Join-Path $script:sb.Root 'home'
        [Environment]::SetEnvironmentVariable('USERPROFILE', $short, 'Process')
        $script:shortCritical = Join-Path $short '.aws'
        $script:longCritical = Join-Path $long '.aws'
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq $script:shortCritical }
        Mock Get-Item { [pscustomobject]@{ FullName = $script:longCritical } } -ParameterFilter { $LiteralPath -eq $script:shortCritical }
        $rule = [pscustomobject]@{
            id = 'credentials'
            tier = 'critical'
            platforms = @('windows')
            match = [pscustomobject]@{ windows = @('${USERPROFILE}/.aws') }
        }
        $cs = Get-CriticalSet -Rules @($rule) -Platform 'windows'
        $cs.Paths | Should -Contain $script:longCritical
        @($cs.Unresolved).Count | Should -Be 0
    }

    It 'R5 m1 leaves a critical set without 8.3 segments with nothing unresolved' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $cs = Get-CriticalSet -Rules $rules -Platform 'windows'
        @($cs.Unresolved).Count | Should -Be 0
    }
}

Describe 'Test-PathUnder' {
    It 'is true for the same path in another case' {
        Test-PathUnder 'C:\A\B' 'c:\a\b' | Should -BeTrue
    }

    It 'is true for a child' {
        Test-PathUnder 'C:\a\b\c' 'C:\a\b' | Should -BeTrue
    }

    It 'is false for a sibling with a common prefix' {
        Test-PathUnder 'C:\ab' 'C:\a' | Should -BeFalse
    }

    It 'is true for anything under a drive root' {
        Test-PathUnder 'C:\x' 'C:\' | Should -BeTrue
    }
}

Describe 'Test-NameMatch' {
    It 'matches a segment case-insensitively' {
        Test-NameMatch 'C:\x\DB.MDF' @('*.mdf') | Should -BeTrue
    }

    It 'does not match a partial segment' {
        Test-NameMatch 'C:\x\.github\y' @('.git') | Should -BeFalse
    }
}

Describe 'Test-CriticalPath' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'is true under a critical path' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $cs = Get-CriticalSet -Rules $rules -Platform 'windows'
        Test-CriticalPath "$($script:sb.Home)\Documents\a.txt" $cs | Should -BeTrue
    }

    It 'is true for a critical name pattern' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $cs = Get-CriticalSet -Rules $rules -Platform 'windows'
        Test-CriticalPath "$($script:sb.Home)\.gradle\caches\x\.git\config" $cs | Should -BeTrue
    }

    It 'is false for a cache folder' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $cs = Get-CriticalSet -Rules $rules -Platform 'windows'
        Test-CriticalPath "$($script:sb.Local)\npm-cache" $cs | Should -BeFalse
    }
}

Describe 'Test-ProtectedTarget' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'R7 refuses a volume root' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $cs = Get-CriticalSet -Rules $rules -Platform 'windows'
        Test-ProtectedTarget 'C:\' $cs | Should -BeTrue
    }

    It 'R7 refuses the home folder' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $cs = Get-CriticalSet -Rules $rules -Platform 'windows'
        Test-ProtectedTarget $script:sb.Home $cs | Should -BeTrue
    }

    It 'R7 refuses a path under a critical path' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $cs = Get-CriticalSet -Rules $rules -Platform 'windows'
        Test-ProtectedTarget "$($script:sb.Home)\Documents\tmp" $cs | Should -BeTrue
    }

    It 'allows a cache folder' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $cs = Get-CriticalSet -Rules $rules -Platform 'windows'
        Test-ProtectedTarget "$($script:sb.Home)\.gradle\caches" $cs | Should -BeFalse
    }

    It 'R6 m2 refuses a path that contains the home folder' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules $rulesPath
        $cs = Get-CriticalSet -Rules $rules -Platform 'windows'
        Test-ProtectedTarget $script:sb.Root $cs | Should -BeTrue
        Test-ProtectedTarget (Join-Path $script:sb.Root 'other') $cs | Should -BeFalse
    }
}

Describe 'Test-IsTempPath' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'is true under TEMP' {
        Test-IsTempPath "$($script:sb.Temp)\x" | Should -BeTrue
    }

    It 'is false for the sandbox out folder' {
        Test-IsTempPath $script:sb.Out | Should -BeFalse
    }
}

Describe 'Test-IsElevated' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'is false when DISK_CLEANUP_FORCE_NOT_ELEVATED is 1' {
        Test-IsElevated | Should -BeFalse
    }

    It 'returns a boolean without the variable' {
        [Environment]::SetEnvironmentVariable('DISK_CLEANUP_FORCE_NOT_ELEVATED', $null, 'Process')
        $res = Test-IsElevated
        ($res -is [bool]) | Should -BeTrue
    }
}

Describe 'ConvertFrom-RoboFileLines' {
    BeforeAll {
        $script:fileLines = @(
            "`t`t           2097152`tC:\sb\home\big.bin"
            "`t`t                10`tC:\sb\home\a b\small.txt"
            "`t                   `tNew Dir`t2`tC:\sb\home\"
        )
        $script:summaryEn = @(
            '               Total    Copied   Skipped  Mismatch    FAILED    Extras'
            '    Dirs :         3         3         0         0         0         0'
            '   Files :         5         5         0         0         0         0'
            '   Bytes :   4194304   4194304         0         0         0         0'
            '   Times :   0:00:00   0:00:00                       0:00:00   0:00:00'
        )
        $script:summaryFr = @(
            '               Total    Copied   Skipped  Mismatch    FAILED    Extras'
            'Dossiers :         3         3         0         0         0         0'
            'Fichiers :         5         5         0         0         0         0'
            '  Octets :   7340032   7340032         0         0         0         0'
            '   Times :   0:00:00   0:00:00                       0:00:00   0:00:00'
        )
        $script:errorLines = @(
            '2026/11/15 20:51:00 ERROR 5 (0x00000005) Scanning Source Directory C:\sb\home\locked\'
            '2026/11/15 20:51:00 FEHLER 5 (0x00000005) Quellverzeichnis wird gescannt C:\sb\home\other\'
        )
    }

    It 'parses size and path of file lines' {
        $res = ConvertFrom-RoboFileLines -Lines $script:fileLines
        $res.Count | Should -Be 2
        $res[0].Bytes | Should -Be 2097152
        $res[0].Path | Should -Be 'C:\sb\home\big.bin'
        $res[1].Bytes | Should -Be 10
        $res[1].Path | Should -Be 'C:\sb\home\a b\small.txt'
    }

    It 'ignores lines without a size and drive path' {
        $res = ConvertFrom-RoboFileLines -Lines @($script:fileLines[2])
        $res.Count | Should -Be 0
        $resSum = ConvertFrom-RoboFileLines -Lines $script:summaryEn
        $resSum.Count | Should -Be 0
    }
}

Describe 'Get-RoboSummaryBytes' {
    BeforeAll {
        $script:fileLines = @(
            "`t`t           2097152`tC:\sb\home\big.bin"
            "`t`t                10`tC:\sb\home\a b\small.txt"
            "`t                   `tNew Dir`t2`tC:\sb\home\"
        )
        $script:summaryEn = @(
            '               Total    Copied   Skipped  Mismatch    FAILED    Extras'
            '    Dirs :         3         3         0         0         0         0'
            '   Files :         5         5         0         0         0         0'
            '   Bytes :   4194304   4194304         0         0         0         0'
            '   Times :   0:00:00   0:00:00                       0:00:00   0:00:00'
        )
        $script:summaryFr = @(
            '               Total    Copied   Skipped  Mismatch    FAILED    Extras'
            'Dossiers :         3         3         0         0         0         0'
            'Fichiers :         5         5         0         0         0         0'
            '  Octets :   7340032   7340032         0         0         0         0'
            '   Times :   0:00:00   0:00:00                       0:00:00   0:00:00'
        )
    }

    It 'reads the bytes row of an English summary' {
        Get-RoboSummaryBytes -Lines $script:summaryEn | Should -Be 4194304
    }

    It 'E2 reads the bytes row of a localized summary' {
        Get-RoboSummaryBytes -Lines $script:summaryFr | Should -Be 7340032
    }

    It 'returns 0 without a summary' {
        Get-RoboSummaryBytes -Lines $script:fileLines | Should -Be 0
    }
}

Describe 'Get-RoboErrorPaths' {
    BeforeAll {
        $script:errorLines = @(
            '2026/11/15 20:51:00 ERROR 5 (0x00000005) Scanning Source Directory C:\sb\home\locked\'
            '2026/11/15 20:51:00 FEHLER 5 (0x00000005) Quellverzeichnis wird gescannt C:\sb\home\other\'
        )
    }

    It 'extracts the path of an error line without the trailing backslash' {
        $res = Get-RoboErrorPaths -Lines @($script:errorLines[0])
        $res | Should -Be @('C:\sb\home\locked')
    }

    It 'extracts the path of a localized error line' {
        $res = Get-RoboErrorPaths -Lines @($script:errorLines[1])
        $res | Should -Be @('C:\sb\home\other')
    }
}

Describe 'Get-RoboExclusionArgs' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
        $script:nullDir = Join-Path $script:sb.Out '.robocopy-null'
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'returns nothing without a critical set' {
        $res = Get-RoboExclusionArgs -Root 'C:\sb\home' -CriticalSet $null
        $res.Count | Should -Be 0
    }

    It 'lists critical paths under the root and name patterns for XD and XF' {
        $h = $script:sb.Home
        $cs = [pscustomobject]@{
            Paths = @("$h\Documents", 'C:\Other')
            NamePatterns = @('.git')
        }
        $res = Get-RoboExclusionArgs -Root $h -CriticalSet $cs
        $res | Should -Be @('/XD', "$h\Documents", '.git', '/XF', "$h\Documents", '.git')
    }
}

Describe 'Invoke-RoboList' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
        $script:nullDir = Join-Path $script:sb.Out '.robocopy-null'
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'E1 returns output lines and never creates NullDir' {
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'file.txt') -Bytes 10 | Out-Null
        $lines = Invoke-RoboList -Source $script:sb.Home -NullDir $script:nullDir -Arguments @('/L', '/NJH', '/NJS')
        $lines.Count | Should -BeGreaterThan 0
        (Test-Path -LiteralPath $script:nullDir) | Should -BeFalse
    }
}

Describe 'Get-FileListing' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
        $script:nullDir = Join-Path $script:sb.Out '.robocopy-null'
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'lists files recursively with sizes' {
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'a\1.bin') -Bytes 10 | Out-Null
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'a\b\2.bin') -Bytes 20 | Out-Null
        $res = Get-FileListing -Root (Join-Path $script:sb.Home 'a') -NullDir $script:nullDir -Recurse
        $res.Files.Count | Should -Be 2
        ($res.Files | Where-Object { $_.Path.EndsWith('1.bin') }).Bytes | Should -Be 10
        ($res.Files | Where-Object { $_.Path.EndsWith('2.bin') }).Bytes | Should -Be 20
    }

    It 'lists only top-level files without Recurse' {
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'a\1.bin') -Bytes 10 | Out-Null
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'a\b\2.bin') -Bytes 20 | Out-Null
        $res = Get-FileListing -Root (Join-Path $script:sb.Home 'a') -NullDir $script:nullDir
        $res.Files.Count | Should -Be 1
        $res.Files[0].Path.EndsWith('1.bin') | Should -BeTrue
    }

    It 'I2 returns exact non-ASCII names and sizes next to a best-fit sibling' {
        $wide = [string][char]0x141
        Add-SandboxFile -Path (Join-Path $script:sb.Home ($wide + 'og.log')) -Bytes 10 | Out-Null
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'Log.log') -Bytes 20 | Out-Null
        $res = Get-FileListing -Root $script:sb.Home -NullDir $script:nullDir -Include @('*.log')
        $res.Files.Count | Should -Be 2
        ($res.Files | Where-Object { $_.Path.EndsWith($wide + 'og.log') }).Bytes | Should -Be 10
        ($res.Files | Where-Object { $_.Path.EndsWith('Log.log') }).Bytes | Should -Be 20
    }

    It 'm5 leaves the Temp folders out when ExcludeTempFolders is set' {
        Add-SandboxFile -Path (Join-Path $script:sb.Local 'app\a.log') -Bytes 10 | Out-Null
        Add-SandboxFile -Path (Join-Path $script:sb.Temp 't.log') -Bytes 10 | Out-Null
        $plain = Get-FileListing -Root $script:sb.Local -NullDir $script:nullDir -Include @('*.log') -Recurse
        $plain.Files.Count | Should -Be 2
        $res = Get-FileListing -Root $script:sb.Local -NullDir $script:nullDir -Include @('*.log') -Recurse -ExcludeTempFolders
        $res.Files.Count | Should -Be 1
        $res.Files[0].Path.EndsWith('a.log') | Should -BeTrue
    }

    It 'applies MinBytes' {
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'big.bin') -Bytes 2097152 | Out-Null
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'small.bin') -Bytes 10 | Out-Null
        $res = Get-FileListing -Root $script:sb.Home -NullDir $script:nullDir -MinBytes 1048576
        $res.Files.Count | Should -Be 1
        $res.Files[0].Bytes | Should -Be 2097152
    }

    It 'applies MinAgeDays' {
        $oldDate = [datetime]::UtcNow.AddDays(-10)
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home 'old.bin') -Bytes 10 -LastWriteUtc $oldDate
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'new.bin') -Bytes 10 | Out-Null
        $res = Get-FileListing -Root $script:sb.Home -NullDir $script:nullDir -MinAgeDays 5
        $res.Files.Count | Should -Be 1
        $res.Files[0].Path.EndsWith('old.bin') | Should -BeTrue
    }

    It 'applies Include patterns' {
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'x.log') -Bytes 10 | Out-Null
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'x.txt') -Bytes 10 | Out-Null
        $res = Get-FileListing -Root $script:sb.Home -NullDir $script:nullDir -Include @('*.log')
        $res.Files.Count | Should -Be 1
        $res.Files[0].Path.EndsWith('x.log') | Should -BeTrue
    }

    It 'R8 does not follow a junction' {
        $h = $script:sb.Home
        Add-SandboxFile -Path "$h\Documents\secret.txt" -Bytes 10 | Out-Null
        $cachesDir = "$h\caches"
        [System.IO.Directory]::CreateDirectory($cachesDir) | Out-Null
        New-Item -ItemType Junction -Path "$h\caches\link" -Target "$h\Documents" | Out-Null
        $res = Get-FileListing -Root "$h\caches" -NullDir $script:nullDir -Recurse
        ($res.Files | Where-Object { $_.Path.EndsWith('secret.txt') }).Count | Should -Be 0
    }

    It 'excludes a .git folder and a db.mdf with a critical set' {
        $h = $script:sb.Home
        Add-SandboxFile -Path "$h\caches\x\.git\config" -Bytes 10 | Out-Null
        Add-SandboxFile -Path "$h\caches\db.mdf" -Bytes 10 | Out-Null
        Add-SandboxFile -Path "$h\caches\keep.bin" -Bytes 10 | Out-Null
        $rules = Get-DiskCleanupRules (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json')
        $cs = Get-CriticalSet -Rules $rules -Platform 'windows'
        $res = Get-FileListing -Root "$h\caches" -NullDir $script:nullDir -Recurse -CriticalSet $cs
        $res.Files.Count | Should -Be 1
        $res.Files[0].Path.EndsWith('keep.bin') | Should -BeTrue
    }
}

Describe 'Get-FolderBytes' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
        $script:nullDir = Join-Path $script:sb.Out '.robocopy-null'
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'sums all files' {
        $h = $script:sb.Home
        Add-SandboxFile -Path "$h\a\1.bin" -Bytes 10 | Out-Null
        Add-SandboxFile -Path "$h\a\2.bin" -Bytes 20 | Out-Null
        $res = Get-FolderBytes -Path "$h\a" -NullDir $script:nullDir
        $res.Bytes | Should -Be 30
    }

    It 'excludes critical subtrees when a critical set is given' {
        $h = $script:sb.Home
        Add-SandboxFile -Path "$h\a\1.bin" -Bytes 10 | Out-Null
        Add-SandboxFile -Path "$h\a\2.bin" -Bytes 20 | Out-Null
        Add-SandboxFile -Path "$h\a\.git\config" -Bytes 100 | Out-Null
        $rules = Get-DiskCleanupRules (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json')
        $cs = Get-CriticalSet -Rules $rules -Platform 'windows'
        $resNoCs = Get-FolderBytes -Path "$h\a" -NullDir $script:nullDir
        $resNoCs.Bytes | Should -Be 130
        $resWithCs = Get-FolderBytes -Path "$h\a" -NullDir $script:nullDir -CriticalSet $cs
        $resWithCs.Bytes | Should -Be 30
    }
}

Describe 'Get-OldVersionFolders' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
        $script:nullDir = Join-Path $script:sb.Out '.robocopy-null'
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'returns every version but the highest per extension' {
        $extDir = Join-Path $script:sb.Home 'extensions'
        [System.IO.Directory]::CreateDirectory("$extDir\pub.ext-1.2.0") | Out-Null
        [System.IO.Directory]::CreateDirectory("$extDir\pub.ext-1.10.0") | Out-Null
        [System.IO.Directory]::CreateDirectory("$extDir\pub.other-0.1.0") | Out-Null
        $res = Get-OldVersionFolders -Path $extDir
        $res | Should -Be @((Join-Path $extDir 'pub.ext-1.2.0'))
    }

    It 'keeps names without a version' {
        $extDir = Join-Path $script:sb.Home 'extensions'
        [System.IO.Directory]::CreateDirectory("$extDir\notes") | Out-Null
        [System.IO.Directory]::CreateDirectory("$extDir\pub.ext-1.0.0") | Out-Null
        $res = Get-OldVersionFolders -Path $extDir
        $res.Count | Should -Be 0
    }

    It 'keeps the platform suffix in the key' {
        $extDir = Join-Path $script:sb.Home 'extensions'
        [System.IO.Directory]::CreateDirectory("$extDir\pub.x-1.0.0-win32-x64") | Out-Null
        [System.IO.Directory]::CreateDirectory("$extDir\pub.x-2.0.0-win32-x64") | Out-Null
        [System.IO.Directory]::CreateDirectory("$extDir\pub.x-1.0.0") | Out-Null
        $res = Get-OldVersionFolders -Path $extDir
        $res | Should -Be @((Join-Path $extDir 'pub.x-1.0.0-win32-x64'))
    }

    It 'R8 skips a junction' {
        $h = $script:sb.Home
        $extDir = Join-Path $h 'extensions'
        [System.IO.Directory]::CreateDirectory($extDir) | Out-Null
        [System.IO.Directory]::CreateDirectory("$h\Documents") | Out-Null
        New-Item -ItemType Junction -Path "$extDir\pub.ext-0.1.0" -Target "$h\Documents" | Out-Null
        [System.IO.Directory]::CreateDirectory("$extDir\pub.ext-1.0.0") | Out-Null
        $res = Get-OldVersionFolders -Path $extDir
        $res.Count | Should -Be 0
    }
}

Describe 'Get-DedupeDeletions' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
        $script:nullDir = Join-Path $script:sb.Out '.robocopy-null'
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'R11 keeps the oldest copy' {
        $h = $script:sb.Home
        $t1 = [datetime]::Parse('2020-01-01T00:00:00Z')
        $t2 = [datetime]::Parse('2021-01-01T00:00:00Z')
        $t3 = [datetime]::Parse('2022-01-01T00:00:00Z')
        $p1 = Add-SandboxFile -Path "$h\Downloads\a.bin" -Bytes 10 -LastWriteUtc $t1
        [System.IO.File]::SetLastWriteTimeUtc($p1, $t1)
        $p2 = Add-SandboxFile -Path "$h\Videos2\a.bin" -Bytes 10 -LastWriteUtc $t2
        [System.IO.File]::SetLastWriteTimeUtc($p2, $t2)
        $p3 = Add-SandboxFile -Path "$h\Music2\a.bin" -Bytes 10 -LastWriteUtc $t3
        [System.IO.File]::SetLastWriteTimeUtc($p3, $t3)
        $res = Get-DedupeDeletions -Paths @($p1, $p2, $p3) -ProtectedSet $null
        $res | Should -Be @($p2, $p3)
    }

    It 'm2 treats two hard linked paths as one file' {
        $h = $script:sb.Home
        $t1 = [datetime]::Parse('2020-01-01T00:00:00Z')
        $t2 = [datetime]::Parse('2022-01-01T00:00:00Z')
        $p1 = Add-SandboxFile -Path "$h\Downloads\a.bin" -Bytes 10 -LastWriteUtc $t1
        $null = New-Item -ItemType Directory -Path "$h\Videos2" -Force
        $p2 = "$h\Videos2\a.bin"
        $null = New-Item -ItemType HardLink -Path $p2 -Target $p1
        $p3 = Add-SandboxFile -Path "$h\Music2\a.bin" -Bytes 10 -LastWriteUtc $t2
        (Get-DedupeDeletions -Paths @($p1, $p2) -ProtectedSet $null).Count | Should -Be 0
        $res = Get-DedupeDeletions -Paths @($p1, $p2, $p3) -ProtectedSet $null
        $res | Should -Be @($p3)
    }

    It 'm2 Get-FileIdentity returns the same value for hard links only' {
        $h = $script:sb.Home
        $p1 = Add-SandboxFile -Path "$h\a.bin" -Bytes 10
        $p2 = "$h\b.bin"
        $null = New-Item -ItemType HardLink -Path $p2 -Target $p1
        $p3 = Add-SandboxFile -Path "$h\c.bin" -Bytes 10
        Get-FileIdentity -Path $p1 | Should -Not -BeNullOrEmpty
        Get-FileIdentity -Path $p1 | Should -Be (Get-FileIdentity -Path $p2)
        Get-FileIdentity -Path $p1 | Should -Not -Be (Get-FileIdentity -Path $p3)
        Get-FileIdentity -Path "$h\missing.bin" | Should -BeNullOrEmpty
    }

    It 'R11 never returns a protected copy' {
        $h = $script:sb.Home
        $t1 = [datetime]::Parse('2020-01-01T00:00:00Z')
        $t2 = [datetime]::Parse('2021-01-01T00:00:00Z')
        $t3 = [datetime]::Parse('2022-01-01T00:00:00Z')
        $p1 = Add-SandboxFile -Path "$h\Downloads\a.bin" -Bytes 10 -LastWriteUtc $t1
        [System.IO.File]::SetLastWriteTimeUtc($p1, $t1)
        $p2 = Add-SandboxFile -Path "$h\Desktop\a.bin" -Bytes 10 -LastWriteUtc $t2
        [System.IO.File]::SetLastWriteTimeUtc($p2, $t2)
        $p3 = Add-SandboxFile -Path "$h\Videos2\a.bin" -Bytes 10 -LastWriteUtc $t3
        [System.IO.File]::SetLastWriteTimeUtc($p3, $t3)
        $rules = Get-DiskCleanupRules (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json')
        $protectedRules = @($rules | Where-Object { -not $_.allowDuplicateRemoval })
        $protectedSet = Get-CriticalSet -Rules $protectedRules -Platform 'windows'
        $res = Get-DedupeDeletions -Paths @($p1, $p2, $p3) -ProtectedSet $protectedSet
        $res | Should -Be @($p3)
    }

    It 'R11 breaks a time tie by ordinal path' {
        $h = $script:sb.Home
        $time = [datetime]::Parse('2020-01-01T00:00:00Z')
        $pB = Add-SandboxFile -Path "$h\B\a.bin" -Bytes 10 -LastWriteUtc $time
        [System.IO.File]::SetLastWriteTimeUtc($pB, $time)
        $pA = Add-SandboxFile -Path "$h\A\a.bin" -Bytes 10 -LastWriteUtc $time
        [System.IO.File]::SetLastWriteTimeUtc($pA, $time)
        $res = Get-DedupeDeletions -Paths @($pB, $pA) -ProtectedSet $null
        $res | Should -Be @($pB)
    }
}

Describe 'Format-Gigabytes' {
    It 'formats one gigabyte' {
        Format-Gigabytes -Bytes 1073741824 | Should -Be '1.0'
    }

    It 'formats with one decimal and a dot' {
        $prev = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            Format-Gigabytes -Bytes 1610612736 | Should -Be '1.5'
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $prev
        }
    }
}

Describe 'Format-UtcTimestamp' {
    It 'formats a UTC time' {
        Format-UtcTimestamp -Value ([datetime]::new(2026, 1, 2, 3, 4, 5, [System.DateTimeKind]::Utc)) | Should -Be '2026-01-02T03:04:05Z'
    }
}

Describe 'Get-FileSha256' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
        $script:nullDir = Join-Path $script:sb.Out '.robocopy-null'
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'hashes an empty file' {
        $p = Add-SandboxFile -Path (Join-Path $script:sb.Home 'empty.bin') -Bytes 0
        Get-FileSha256 -Path $p | Should -Be 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    }
}

Describe 'ConvertTo-JsonFile' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
        $script:nullDir = Join-Path $script:sb.Out '.robocopy-null'
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'keeps a one-element array as an array' {
        $p = Join-Path $script:sb.Out 'test.json'
        ConvertTo-JsonFile -InputObject ([ordered]@{ a = @('x') }) -Path $p
        $parsed = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $parsed.a.Count | Should -Be 1
        $raw = [System.IO.File]::ReadAllText($p)
        ($raw -match '"a":\s*\[') | Should -BeTrue
    }

    It 'writes UTF-8 without BOM' {
        $p = Join-Path $script:sb.Out 'nobom.json'
        ConvertTo-JsonFile -InputObject ([ordered]@{ a = 'x' }) -Path $p
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $bytes[0] | Should -Not -Be 0xEF
    }
}

Describe 'Get-FreeBytes' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
        $script:nullDir = Join-Path $script:sb.Out '.robocopy-null'
    }
    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'returns a positive Int64 for the sandbox' {
        $res = Get-FreeBytes -Path $script:sb.Root
        ($res -is [int64]) | Should -BeTrue
        $res | Should -BeGreaterThan 0
    }
}

Describe 'Test-ShortNamePath' {
    It 'flags a path with an 8.3 short name segment' {
        Test-ShortNamePath -Path 'D:\Data\SHORT~1\Downloads' | Should -BeTrue
        Test-ShortNamePath -Path 'D:/Data/AWS~2/credentials' | Should -BeTrue
    }

    It 'passes a path without a short name segment' {
        Test-ShortNamePath -Path 'D:\Data\files\Downloads' | Should -BeFalse
        Test-ShortNamePath -Path 'D:\Data\file.txt' | Should -BeFalse
    }
}
