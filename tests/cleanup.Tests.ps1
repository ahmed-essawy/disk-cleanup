BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\scripts\common.ps1')

    function Invoke-Cleanup {
        param([string[]]$Arguments)
        $scan = Join-Path $script:sb.Out 'scan.json'
        $log = Join-Path $script:sb.Out 'cleanup.log'
        return (Invoke-DiskCleanupScript -Name 'cleanup.ps1' -Arguments (@('-ScanPath', $scan, '-LogPath', $log) + $Arguments))
    }

    function Get-LogRows {
        $log = Join-Path $script:sb.Out 'cleanup.log'
        if (-not (Test-Path -LiteralPath $log)) {
            return @()
        }
        $lines = [System.IO.File]::ReadAllLines($log)
        $res = [System.Collections.Generic.List[object]]::new()
        foreach ($l in $lines) {
            if ([string]::IsNullOrWhiteSpace($l)) {
                continue
            }
            $res.Add(@($l -split "`t"))
        }
        return @($res.ToArray())
    }

    function Get-CleanSnapshot {
        param([object]$Sandbox)
        Remove-Item -LiteralPath (Join-Path $Sandbox.Local 'Microsoft') -Recurse -Force -ErrorAction SilentlyContinue
        $fixedDate = [datetime]::new(2026, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        Get-ChildItem -LiteralPath $Sandbox.Root -Recurse -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            [System.IO.Directory]::SetLastWriteTimeUtc($_.FullName, $fixedDate)
        }
        [System.IO.Directory]::SetLastWriteTimeUtc($Sandbox.Root, $fixedDate)
        return (Get-TreeSnapshot -Sandbox $Sandbox)
    }
}

Describe 'cleanup.ps1 core' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }

    AfterEach {
        if ($null -ne $script:sb) {
            Restore-TestSandbox $script:sb
        }
    }

    It 'R1 refuses every critical id passed explicitly (contract test 1)' {
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home 'Documents\a.txt') -Bytes 1024
        $rules = Get-DiskCleanupRules -Path (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json') -Platform 'windows'
        $critIds = @($rules | Where-Object { $_.tier -eq 'critical' } | ForEach-Object { $_.id })
        $idsArg = $critIds -join ','
        $before = Get-CleanSnapshot -Sandbox $script:sb
        $res = Invoke-Cleanup -Arguments @('-Ids', $idsArg)
        $res.ExitCode | Should -Be 0
        $rows = Get-LogRows
        $stepRows = @($rows | Where-Object { $_[2] -ne 'run' })
        foreach ($r in $stepRows) {
            $r[3] | Should -Be 'refused'
            $r[6] | Should -Be 'critical'
        }
        $after = Get-CleanSnapshot -Sandbox $script:sb
        ($after -join "`n") | Should -Be ($before -join "`n")
        (Get-StubCalls -Sandbox $script:sb).Count | Should -Be 0
        $res.StdOut | Should -Match 'Refused: .*database-files \(critical\)'
    }

    It 'R1 refuses a critical rule that a fixture rules file gives an action (contract test 2)' {
        $fix = Write-FixtureRules -Sandbox $script:sb -Transform {
            param($doc)
            foreach ($r in $doc.rules) {
                if ($r.id -eq 'database-files') {
                    $r.action = [ordered]@{ type = 'clear-dir' }
                    $r.match.windows = @('${USERPROFILE}/dbdata')
                }
            }
        }
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home 'dbdata\a.bin') -Bytes 1024
        $res = Invoke-Cleanup -Arguments @('-RulesPath', $fix, '-Ids', 'database-files')
        $res.ExitCode | Should -Be 0
        $rows = Get-LogRows
        $targetRow = @($rows | Where-Object { $_[1] -eq 'database-files' -and $_[2] -ne 'run' })[0]
        $targetRow[3] | Should -Be 'refused'
        $targetRow[6] | Should -Be 'critical'
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'dbdata\a.bin') | Should -Be $true
    }

    It 'R2 refuses an unknown id (contract test 3)' {
        $res = Invoke-Cleanup -Arguments @('-Ids', 'no-such-rule')
        $res.ExitCode | Should -Be 0
        $rows = Get-LogRows
        $targetRow = @($rows | Where-Object { $_[1] -eq 'no-such-rule' })[0]
        $targetRow[2] | Should -Be '-'
        $targetRow[3] | Should -Be 'refused'
        $targetRow[6] | Should -Be 'unknown id'
        $res.StdOut | Should -Match 'Refused: .*no-such-rule \(unknown id\)'
    }

    It 'R3 refuses a non-critical rule without action' {
        $fix = Write-FixtureRules -Sandbox $script:sb -Transform {
            param($doc)
            $newRule = [ordered]@{
                id = 'test-no-action'
                tier = 'safe'
                platforms = @('windows')
                match = [ordered]@{ windows = @('${USERPROFILE}/noaction') }
                action = $null
                needsAdmin = $false
                description = 'Test rule'
                reason = 'Test rule'
            }
            $doc.rules = @($doc.rules) + $newRule
        }
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home 'noaction\a.bin') -Bytes 1024
        $res = Invoke-Cleanup -Arguments @('-RulesPath', $fix, '-Ids', 'test-no-action')
        $res.ExitCode | Should -Be 0
        $rows = Get-LogRows
        $targetRow = @($rows | Where-Object { $_[1] -eq 'test-no-action' })[0]
        $targetRow[3] | Should -Be 'refused'
        $targetRow[6] | Should -Be 'no action'
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'noaction\a.bin') | Should -Be $true
    }

    It 'R4 runs a dry run over safe ids when no ids are given (contract test 4)' {
        $oldDate = (Get-Date).ToUniversalTime().AddDays(-3)
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Local 'Temp\old.tmp') -Bytes 1024 -LastWriteUtc $oldDate
        $before = Get-CleanSnapshot -Sandbox $script:sb
        $res = Invoke-Cleanup -Arguments @()
        $res.ExitCode | Should -Be 0
        $rows = Get-LogRows
        $startRow = $rows[0]
        $startRow[1] | Should -Be '-'
        $startRow[2] | Should -Be 'run'
        $startRow[3] | Should -Be 'start'
        $startRow[6] | Should -Match '^dryRun=true ids=user-temp,'
        $stepRows = @($rows | Where-Object { $_[2] -ne 'run' })
        foreach ($r in $stepRows) {
            $r[3] | Should -BeIn @('dry-run', 'skipped', 'not-applicable')
        }
        $after = Get-CleanSnapshot -Sandbox $script:sb
        ($after -join "`n") | Should -Be ($before -join "`n")
        (Get-StubCalls -Sandbox $script:sb).Count | Should -Be 0
    }

    It 'R5 dry run with ids deletes nothing and runs no tool (contract test 5)' {
        $oldDate = (Get-Date).ToUniversalTime().AddDays(-3)
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Local 'Temp\old.tmp') -Bytes 1024 -LastWriteUtc $oldDate
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Local 'npm-cache\x.bin') -Bytes 1024
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home '.gradle\caches\a\b.bin') -Bytes 1024
        $before = Get-CleanSnapshot -Sandbox $script:sb
        $res = Invoke-Cleanup -Arguments @('-DryRun', '-Ids', 'user-temp,npm-cache,gradle-cache')
        $res.ExitCode | Should -Be 0
        $after = Get-CleanSnapshot -Sandbox $script:sb
        ($after -join "`n") | Should -Be ($before -join "`n")
        (Get-StubCalls -Sandbox $script:sb).Count | Should -Be 0
        $lines = @($res.StdOut -split "`r?`n" | Where-Object { $_ -match '\S' })
        $summaryLines = @($lines | Where-Object { $_ -match '^(Dry run|Free space):' })
        $summaryLines[0] | Should -Match '^Dry run: nothing deleted\.'
        $res.StdOut | Should -Match '(?m)^Dry run: nothing deleted\. Would free about \d+\.\d GB\.\r?$'
        $rows = Get-LogRows
        $tempRow = @($rows | Where-Object { $_[1] -eq 'user-temp' })[0]
        $tempRow[3] | Should -Be 'dry-run'
        $tempRow[6] | Should -Be 'would free 1024 bytes'
    }

    It 'C6 clear-dir empties only the gradle caches folder (contract test 6)' {
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home '.gradle\caches\a\b.bin') -Bytes 1024
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home '.gradle\gradle.properties') -Bytes 1024
        $res = Invoke-Cleanup -Arguments @('-Ids', 'gradle-cache')
        $res.ExitCode | Should -Be 0
        $res.StdOut | Should -Match '(?m)^Free space: \d+\.\d GB -> \d+\.\d GB \(freed \d+\.\d GB\)\r?$'
        Test-Path -LiteralPath (Join-Path $script:sb.Home '.gradle\caches') | Should -Be $true
        @(Get-ChildItem -LiteralPath (Join-Path $script:sb.Home '.gradle\caches') -Recurse).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home '.gradle\gradle.properties') | Should -Be $true
        (Get-StubCalls -Sandbox $script:sb) -contains 'gradle --stop' | Should -Be $true
        $rows = Get-LogRows
        $targetRow = @($rows | Where-Object { $_[1] -eq 'gradle-cache' -and $_[2] -ne 'run' })[0]
        $targetRow[3] | Should -Be 'done'
        $targetRow[6] | Should -Be 'deleted 1 files, 1024 bytes, skipped 0'
    }

    It 'C7 tool rule runs its command (contract test 7)' {
        $res = Invoke-Cleanup -Arguments @('-Ids', 'npm-cache')
        $res.ExitCode | Should -Be 0
        (Get-StubCalls -Sandbox $script:sb) -contains 'npm cache clean --force' | Should -Be $true
        $rows = Get-LogRows
        $targetRow = @($rows | Where-Object { $_[1] -eq 'npm-cache' -and $_[2] -ne 'run' })[0]
        $targetRow[3] | Should -Be 'done'
        $targetRow[6] | Should -Be 'exit 0'
    }

    It 'R7 refuses a match inside a critical folder (contract test 8)' {
        $oldTemp = $env:TEMP
        try {
            $docTemp = Join-Path $script:sb.Home 'Documents\tmp'
            $env:TEMP = $docTemp
            $oldDate = (Get-Date).ToUniversalTime().AddDays(-3)
            $null = Add-SandboxFile -Path (Join-Path $docTemp 'old.tmp') -Bytes 1024 -LastWriteUtc $oldDate
            $res = Invoke-Cleanup -Arguments @('-Ids', 'user-temp')
            $res.ExitCode | Should -Be 0
            $rows = Get-LogRows
            $targetRow = @($rows | Where-Object { $_[1] -eq 'user-temp' -and $_[3] -eq 'refused' })[0]
            $targetRow[6] | Should -Match '^protected path '
            Test-Path -LiteralPath (Join-Path $docTemp 'old.tmp') | Should -Be $true
        } finally {
            $env:TEMP = $oldTemp
        }
    }

    It 'R8 keeps critical subtrees and name patterns inside a target (contract test 9)' {
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home '.gradle\caches\x\repo\.git\config') -Bytes 1024
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home '.gradle\caches\db.mdf') -Bytes 1024
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home '.gradle\caches\keep\other.bin') -Bytes 1024
        $res = Invoke-Cleanup -Arguments @('-Ids', 'gradle-cache')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home '.gradle\caches\x\repo\.git\config') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Home '.gradle\caches\db.mdf') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Home '.gradle\caches\keep\other.bin') | Should -Be $false
    }

    It 'R8 does not follow a junction inside a target (contract test 10)' {
        $docFile = Join-Path $script:sb.Home 'Documents\important.txt'
        $null = Add-SandboxFile -Path $docFile -Bytes 1024
        $junctionDir = Join-Path $script:sb.Home '.gradle\caches\link'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $junctionDir) -Force
        $null = New-Item -ItemType Junction -Path $junctionDir -Target (Join-Path $script:sb.Home 'Documents')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'gradle-cache')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath $docFile | Should -Be $true
    }

    It 'R6 skips admin steps when not elevated (contract test 11)' {
        $res = Invoke-Cleanup -Arguments @('-Ids', 'windows-update-cache,dism-component-cleanup')
        $res.ExitCode | Should -Be 0
        $rows = Get-LogRows
        $wRow = @($rows | Where-Object { $_[1] -eq 'windows-update-cache' })[0]
        $dRow = @($rows | Where-Object { $_[1] -eq 'dism-component-cleanup' })[0]
        $wRow[3] | Should -Be 'skipped'
        $wRow[6] | Should -Be 'needs admin: rerun from a terminal started with "Run as administrator"'
        $dRow[3] | Should -Be 'skipped'
        $dRow[6] | Should -Be 'needs admin: rerun from a terminal started with "Run as administrator"'
        $stubs = Get-StubCalls -Sandbox $script:sb
        ($stubs -match 'sudo|runas|dism').Count | Should -Be 0
        $res.StdOut | Should -Match 'Skipped \(needs admin\): windows-update-cache, dism-component-cleanup\.'
    }

    It 'R9 drops an entry with an unset variable' {
        Remove-Item Env:DISK_CLEANUP_UNSET_VAR -ErrorAction SilentlyContinue
        $fix = Write-FixtureRules -Sandbox $script:sb -Transform {
            param($doc)
            $newRule = [ordered]@{
                id = 'test-unset-var'
                tier = 'safe'
                platforms = @('windows')
                match = [ordered]@{ windows = @('${DISK_CLEANUP_UNSET_VAR}/x') }
                action = [ordered]@{ type = 'clear-dir' }
                needsAdmin = $false
                description = 'Test rule'
                reason = 'Test rule'
            }
            $doc.rules = @($doc.rules) + $newRule
        }
        $before = Get-CleanSnapshot -Sandbox $script:sb
        $res = Invoke-Cleanup -Arguments @('-RulesPath', $fix, '-Ids', 'test-unset-var')
        $res.ExitCode | Should -Be 0
        $rows = Get-LogRows
        $targetRow = @($rows | Where-Object { $_[1] -eq 'test-unset-var' })[0]
        $targetRow[3] | Should -Be 'not-applicable'
        $targetRow[6] | Should -Be 'nothing matched'
        $after = Get-CleanSnapshot -Sandbox $script:sb
        ($after -join "`n") | Should -Be ($before -join "`n")
    }

    It 'C12 writes 7 tab-separated columns with integer free space (contract test 12)' {
        $res = Invoke-Cleanup -Arguments @('-Ids', 'npm-cache')
        $res.ExitCode | Should -Be 0
        $rawLines = @([System.IO.File]::ReadAllLines((Join-Path $script:sb.Out 'cleanup.log')) | Where-Object { $_ -match '\S' })
        $rawLines.Count | Should -BeGreaterThan 1
        foreach ($l in $rawLines) {
            $parts = $l -split "`t"
            $parts.Count | Should -Be 7
            $parts[4] | Should -Match '^\d+$'
            $parts[5] | Should -Match '^\d+$'
        }
        $rows = Get-LogRows
        $rows[0][3] | Should -Be 'start'
        $lastRow = $rows[-1]
        $lastRow[1] | Should -Be '-'
        $lastRow[2] | Should -Be 'run'
        $lastRow[3] | Should -Be 'end'
        $lastRow[6] | Should -Be 'failed=0'
    }

    It 'R10 falls back to the default log path when LogPath is inside Temp (contract test 13)' {
        $tempLog = Join-Path $script:sb.Temp 'x.log'
        $scanJson = Join-Path $script:sb.Out 'scan.json'
        $defaultLog = Join-Path $script:sb.Out 'cleanup.log'
        $res = Invoke-DiskCleanupScript -Name 'cleanup.ps1' -Arguments @('-LogPath', $tempLog, '-ScanPath', $scanJson, '-Ids', 'npm-cache')
        $res.ExitCode | Should -Be 0
        $res.StdErr | Should -Match ('Log path refused \(inside Temp\), using ' + [regex]::Escape($defaultLog))
        Test-Path -LiteralPath $defaultLog | Should -Be $true
        Test-Path -LiteralPath $tempLog | Should -Be $false
    }

    It 'C16 exit code is 1 when a tool fails and 0 otherwise (contract test 16)' {
        $res0 = Invoke-Cleanup -Arguments @('-Ids', 'npm-cache')
        $res0.ExitCode | Should -Be 0
        Add-FailingStub -Sandbox $script:sb -Name 'npm'
        $res1 = Invoke-Cleanup -Arguments @('-Ids', 'npm-cache')
        $res1.ExitCode | Should -Be 1
        $rows = Get-LogRows
        $targetRow = @($rows | Where-Object { $_[1] -eq 'npm-cache' -and $_[2] -ne 'run' })[-1]
        $targetRow[3] | Should -Be 'failed'
        $targetRow[6] | Should -Be 'exit 1'
    }

    It 'R8 refuses a matched path that is itself a junction' {
        $docFile = Join-Path $script:sb.Home 'Documents\important.txt'
        $null = Add-SandboxFile -Path $docFile -Bytes 1024
        $cachesDir = Join-Path $script:sb.Home '.gradle\caches'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $cachesDir) -Force
        $null = New-Item -ItemType Junction -Path $cachesDir -Target (Join-Path $script:sb.Home 'Documents')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'gradle-cache')
        $res.ExitCode | Should -Be 0
        $rows = Get-LogRows
        $targetRow = @($rows | Where-Object { $_[1] -eq 'gradle-cache' -and $_[2] -ne 'file' -and $_[2] -ne 'run' })[0]
        $targetRow[3] | Should -Be 'refused'
        $targetRow[6] | Should -Match '^protected path '
        Test-Path -LiteralPath $docFile | Should -Be $true
    }

    It 'R8 refuses an old-versions root that is itself a junction' {
        $realDir = Join-Path $script:sb.Root 'realext'
        $null = Add-SandboxFile -Path (Join-Path $realDir 'pub.ext-1.2.0\package.json') -Bytes 512
        $null = Add-SandboxFile -Path (Join-Path $realDir 'pub.ext-1.10.0\package.json') -Bytes 512
        $extDir = Join-Path $script:sb.Home '.vscode\extensions'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $extDir) -Force
        $null = New-Item -ItemType Junction -Path $extDir -Target $realDir
        $res = Invoke-Cleanup -Arguments @('-Ids', 'ide-old-extensions')
        $res.ExitCode | Should -Be 0
        $rows = Get-LogRows
        $targetRow = @($rows | Where-Object { $_[1] -eq 'ide-old-extensions' -and $_[2] -ne 'file' -and $_[2] -ne 'run' })[0]
        $targetRow[3] | Should -Be 'refused'
        $targetRow[6] | Should -Match '^protected path '
        Test-Path -LiteralPath (Join-Path $realDir 'pub.ext-1.2.0') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $realDir 'pub.ext-1.10.0') | Should -Be $true
    }

    It 'F3 exits 3 for an unusable log path before it reads the rules file' {
        $tempLog = Join-Path $script:sb.Temp 'x.log'
        $tempScan = Join-Path $script:sb.Temp 'scan.json'
        $missingRules = Join-Path $script:sb.Out 'missing-rules.json'
        $res = Invoke-DiskCleanupScript -Name 'cleanup.ps1' -Arguments @('-LogPath', $tempLog, '-ScanPath', $tempScan, '-RulesPath', $missingRules, '-Ids', 'npm-cache')
        $res.ExitCode | Should -Be 3
    }

    It 'F5 keeps a file newer than one day when user-temp runs for real' {
        $oldDate = (Get-Date).ToUniversalTime().AddDays(-3)
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Local 'Temp\old.tmp') -Bytes 1024 -LastWriteUtc $oldDate
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Local 'Temp\new.tmp') -Bytes 1024
        $res = Invoke-Cleanup -Arguments @('-Ids', 'user-temp')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Local 'Temp\new.tmp') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Local 'Temp\old.tmp') | Should -Be $false
    }

    It 'F5 deletes the valid paths when one matched path is refused' {
        $fix = Write-FixtureRules -Sandbox $script:sb -Transform {
            param($doc)
            $newRule = [ordered]@{
                id = 'test-multi-path'
                tier = 'safe'
                platforms = @('windows')
                match = [ordered]@{ windows = @('${USERPROFILE}/Documents/multi', '${USERPROFILE}/multi-ok') }
                action = [ordered]@{ type = 'clear-dir' }
                needsAdmin = $false
                description = 'Test rule'
                reason = 'Test rule'
            }
            $doc.rules = @($doc.rules) + $newRule
        }
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home 'Documents\multi\a.bin') -Bytes 1024
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home 'multi-ok\b.bin') -Bytes 1024
        $res = Invoke-Cleanup -Arguments @('-RulesPath', $fix, '-Ids', 'test-multi-path')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Documents\multi\a.bin') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'multi-ok\b.bin') | Should -Be $false
        $rows = Get-LogRows
        $refusedRow = @($rows | Where-Object { $_[1] -eq 'test-multi-path' -and $_[3] -eq 'refused' })[0]
        $refusedRow[6] | Should -Match '^protected path .*Documents'
        $stepRow = @($rows | Where-Object { $_[1] -eq 'test-multi-path' -and $_[3] -eq 'done' })[0]
        $stepRow[6] | Should -Be 'deleted 1 files, 1024 bytes, skipped 0'
    }
}

Describe 'cleanup.ps1 delete guard' {
    BeforeAll {
        $scriptPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\scripts\cleanup.ps1'
        $parsed = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $definitions = $parsed.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
        . ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"))
    }

    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }

    AfterEach {
        if ($null -ne $script:sb) {
            Restore-TestSandbox $script:sb
        }
    }

    It 'F2 never deletes a listed file that sits under a critical path' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $rules = Get-DiskCleanupRules -Path $rulesPath
        $criticalFile = Add-SandboxFile -Path (Join-Path $script:sb.Home 'Documents\keep.txt') -Bytes 1024
        $okFile = Add-SandboxFile -Path (Join-Path $script:sb.Home '.gradle\caches\ok.bin') -Bytes 1024
        $script:listed = @(
            [pscustomobject]@{ Path = $criticalFile; Bytes = [int64]1024 },
            [pscustomobject]@{ Path = $okFile; Bytes = [int64]1024 }
        )
        Mock Get-FileListing { [pscustomobject]@{ Files = $script:listed; Unreadable = @() } }
        $rule = @($rules | Where-Object { $_.id -eq 'gradle-cache' })[0]
        $context = [pscustomobject]@{
            DryRun = $false
            Platform = 'windows'
            Target = $null
            NullDir = Join-Path $script:sb.Out '.robocopy-null'
            CriticalSet = Get-CriticalSet -Rules $rules -Platform 'windows'
        }
        $res = Invoke-FileDeletion -Rule $rule -Context $context -Include @('*.*') -Recurse
        Test-Path -LiteralPath $criticalFile | Should -Be $true
        Test-Path -LiteralPath $okFile | Should -Be $false
        $res.Result | Should -Be 'partial'
        $res.Detail | Should -Be 'deleted 1 files, 1024 bytes, skipped 1'
    }

    It 'F2 fails a compaction disk whose path is not ASCII without running diskpart' {
        $disk = 'C:\Docker\d' + [string][char]0x00E9 + '.vhdx'
        $script:disks = @($disk)
        Mock Get-RulePaths { $script:disks }
        Mock Invoke-DockerShutdown { $true }
        Mock Invoke-DiskpartCompact { 0 }
        $context = [pscustomobject]@{
            DryRun = $false
            Platform = 'windows'
            Target = $null
            ScanFolder = $script:sb.Out
        }
        $res = Invoke-CompactVhdxAction -Rule ([pscustomobject]@{}) -Context $context
        $res.Result | Should -Be 'failed'
        $res.Detail | Should -Be "non-ASCII path not supported by diskpart: $disk"
        Should -Invoke Invoke-DiskpartCompact -Times 0 -Exactly
    }
}

Describe 'cleanup.ps1 actions' {
    BeforeAll {
        function Write-FixtureScan {
            param([object[]]$Groups)
            $doc = [ordered]@{
                schemaVersion = 1
                target = $script:sb.Home
                home = $script:sb.Home
                duplicates = @($Groups)
            }
            ConvertTo-JsonFile -InputObject $doc -Path (Join-Path $script:sb.Out 'scan.json')
        }

        function Get-FixtureDate {
            param([int]$Year)
            return [datetime]::new($Year, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        }

        function Add-FixtureCopy {
            param(
                [string]$RelativePath,
                [int64]$Bytes,
                [int]$Year
            )
            $null = Add-SandboxFile -Path (Join-Path $script:sb.Home $RelativePath) -Bytes $Bytes -LastWriteUtc (Get-FixtureDate -Year $Year)
        }

        function Get-DuplicateGroup {
            param(
                [int64]$Bytes,
                [string[]]$RelativePaths
            )
            $paths = @($RelativePaths | ForEach-Object { Join-Path $script:sb.Home $_ })
            return [ordered]@{
                bytes = $Bytes
                sha256 = (Get-FileSha256 $paths[0])
                paths = $paths
            }
        }

        function Initialize-DuplicateFixture {
            Add-FixtureCopy -RelativePath 'Downloads\a.bin' -Bytes 1024 -Year 2020
            Add-FixtureCopy -RelativePath 'Desktop\a.bin' -Bytes 1024 -Year 2021
            Add-FixtureCopy -RelativePath 'Videos2\a.bin' -Bytes 1024 -Year 2022
            Add-FixtureCopy -RelativePath 'Documents\b.bin' -Bytes 2048 -Year 2020
            Add-FixtureCopy -RelativePath 'Documents\sub\b.bin' -Bytes 2048 -Year 2021
            Add-FixtureCopy -RelativePath 'Backups\old.bak' -Bytes 3072 -Year 2020
            Add-FixtureCopy -RelativePath 'Backups2\new.bak' -Bytes 3072 -Year 2022
            Add-FixtureCopy -RelativePath 'Data\a.mdf' -Bytes 4096 -Year 2020
            Add-FixtureCopy -RelativePath 'Data2\b.mdf' -Bytes 4096 -Year 2022
            Write-FixtureScan -Groups @(
                (Get-DuplicateGroup -Bytes 1024 -RelativePaths @('Downloads\a.bin', 'Desktop\a.bin', 'Videos2\a.bin')),
                (Get-DuplicateGroup -Bytes 2048 -RelativePaths @('Documents\b.bin', 'Documents\sub\b.bin')),
                (Get-DuplicateGroup -Bytes 3072 -RelativePaths @('Backups\old.bak', 'Backups2\new.bak')),
                (Get-DuplicateGroup -Bytes 4096 -RelativePaths @('Data\a.mdf', 'Data2\b.mdf'))
            )
        }

        function Initialize-ExtensionFixture {
            $ext = Join-Path $script:sb.Home '.vscode\extensions'
            $null = Add-SandboxFile -Path (Join-Path $ext 'pub.ext-1.2.0\package.json') -Bytes 512
            $null = Add-SandboxFile -Path (Join-Path $ext 'pub.ext-1.10.0\package.json') -Bytes 512
            $null = Add-SandboxFile -Path (Join-Path $ext 'pub.other-0.1.0\package.json') -Bytes 512
            return $ext
        }

        function Get-StepRow {
            param([string]$Id)
            return @(Get-LogRows | Where-Object { $_[1] -eq $Id -and $_[2] -ne 'file' -and $_[2] -ne 'run' })[0]
        }
    }

    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }

    AfterEach {
        if ($null -ne $script:sb) {
            Restore-TestSandbox $script:sb
        }
    }

    It 'R11 keeps the oldest copy and deletes only the unprotected newer copy (contract test 14)' {
        Initialize-DuplicateFixture
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Downloads\a.bin') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Desktop\a.bin') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Videos2\a.bin') | Should -Be $false
        (Get-StepRow -Id 'exact-duplicates')[3] | Should -Be 'done'
    }

    It 'R11 leaves a group whose copies are all protected' {
        Initialize-DuplicateFixture
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Documents\b.bin') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Documents\sub\b.bin') | Should -Be $true
    }

    It 'R11 deletes the newer of two identical bak files' {
        Initialize-DuplicateFixture
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Backups\old.bak') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Backups2\new.bak') | Should -Be $false
    }

    It 'R11 keeps both identical mdf files' {
        Initialize-DuplicateFixture
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Data\a.mdf') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Data2\b.mdf') | Should -Be $true
    }

    It 'R11 skips a copy whose content changed since the scan' {
        Initialize-DuplicateFixture
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home 'Videos2\a.bin') -Bytes 1000
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Videos2\a.bin') | Should -Be $true
    }

    It 'R5 dedupe dry run reports bytes and deletes nothing' {
        Initialize-DuplicateFixture
        $before = Get-CleanSnapshot -Sandbox $script:sb
        $res = Invoke-Cleanup -Arguments @('-DryRun', '-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        $after = Get-CleanSnapshot -Sandbox $script:sb
        ($after -join "`n") | Should -Be ($before -join "`n")
        $row = Get-StepRow -Id 'exact-duplicates'
        $row[3] | Should -Be 'dry-run'
        $row[6] | Should -Be 'would free 4096 bytes'
    }

    It 'F1 dedupe skips an empty group and a group with an empty path without failing' {
        $keep = Join-Path $script:sb.Home 'Downloads\a.bin'
        $null = Add-SandboxFile -Path $keep -Bytes 2048
        $homeJson = ConvertTo-Json -InputObject $script:sb.Home
        $keepJson = ConvertTo-Json -InputObject $keep
        $json = '{"schemaVersion":1,"target":' + $homeJson + ',"home":' + $homeJson + ',"duplicates":[[],{"bytes":2048,"sha256":"00","paths":["",' + $keepJson + ']},{"bytes":2048,"sha256":"00","paths":["",""]}]}'
        [System.IO.File]::WriteAllText((Join-Path $script:sb.Out 'scan.json'), $json)
        $res = Invoke-Cleanup -Arguments @('-DryRun', '-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        $row = Get-StepRow -Id 'exact-duplicates'
        $row[3] | Should -Be 'not-applicable'
        $row[6] | Should -Be 'nothing matched'
    }

    It 'F2 dry run of user-temp keeps a marginal per-file cost under 5 ms' {
        $measureDryRun = {
            param([int]$FileCount)
            $aged = [datetime]::UtcNow.AddDays(-5)
            $perDir = 100
            for ($d = 0; $d -lt ($FileCount / $perDir); $d++) {
                $dir = Join-Path $script:sb.Temp ('d{0:D2}' -f $d)
                $null = [System.IO.Directory]::CreateDirectory($dir)
                for ($i = 0; $i -lt $perDir; $i++) {
                    $file = Join-Path $dir ('f{0}.tmp' -f $i)
                    [System.IO.File]::WriteAllBytes($file, (New-Object byte[] 16))
                    [System.IO.File]::SetLastWriteTimeUtc($file, $aged)
                }
            }
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $res = Invoke-Cleanup -Arguments @('-DryRun', '-Ids', 'user-temp')
            $watch.Stop()
            $res.ExitCode | Should -Be 0
            $row = Get-StepRow -Id 'user-temp'
            $row[3] | Should -Be 'dry-run'
            $row[6] | Should -Be ('would free {0} bytes' -f ($FileCount * 16))
            return $watch.Elapsed.TotalMilliseconds
        }
        $smallCount = 200
        $largeCount = 2000
        $smallMs = [Math]::Min((& $measureDryRun $smallCount), (& $measureDryRun $smallCount))
        $firstSandbox = $script:sb
        $largeMs = 0
        try {
            $script:sb = Initialize-TestSandbox
            $largeMs = [Math]::Min((& $measureDryRun $largeCount), (& $measureDryRun $largeCount))
        }
        finally {
            Restore-TestSandbox $script:sb
            $script:sb = $firstSandbox
        }
        $perFileMs = ($largeMs - $smallMs) / ($largeCount - $smallCount)
        $perFileMs | Should -BeLessThan 5 -Because ('200 files took {0:N0} ms and 2000 files took {1:N0} ms' -f $smallMs, $largeMs)
        $largeMs | Should -BeLessThan 120000
    }

    It 'C14 dedupe without scan.json is not applicable' {
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        $row = Get-StepRow -Id 'exact-duplicates'
        $row[3] | Should -Be 'not-applicable'
        $row[6] | Should -Be 'no scan.json'
    }

    It 'R11 dedupe without a scan target is not applicable and deletes nothing' {
        Initialize-DuplicateFixture
        $scanPath = Join-Path $script:sb.Out 'scan.json'
        $doc = Get-Content -LiteralPath $scanPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $doc.PSObject.Properties.Remove('target')
        ConvertTo-JsonFile -InputObject $doc -Path $scanPath
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Downloads\a.bin') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Videos2\a.bin') | Should -Be $true
        $row = Get-StepRow -Id 'exact-duplicates'
        $row[3] | Should -Be 'not-applicable'
        $row[6] | Should -Be 'no scan target'
    }

    It 'R4 never deletes a copy whose path climbs out of the target with dot dot' {
        $kept = Join-Path $script:sb.Home 'Downloads\a.bin'
        $outside = Join-Path $script:sb.Root 'outside\a.bin'
        $null = Add-SandboxFile -Path $kept -Bytes 1024 -LastWriteUtc ([datetime]::new(2020, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $null = Add-SandboxFile -Path $outside -Bytes 1024 -LastWriteUtc ([datetime]::new(2023, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $climb = (Join-Path $script:sb.Home 'Downloads') + '\..\..\outside\a.bin'
        $group = [ordered]@{ bytes = 1024; sha256 = (Get-FileSha256 $kept); paths = @($kept, $climb) }
        ConvertTo-JsonFile -InputObject ([ordered]@{ schemaVersion = 1; target = $script:sb.Home; home = $script:sb.Home; duplicates = @($group) }) -Path (Join-Path $script:sb.Out 'scan.json')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath $kept | Should -Be $true
        Test-Path -LiteralPath $outside | Should -Be $true
        $row = Get-StepRow -Id 'exact-duplicates'
        $row[3] | Should -Be 'not-applicable'
        $row[6] | Should -Be 'nothing matched'
    }

    It 'R4 never deletes a critical file reached through a doubled backslash' {
        $kept = Join-Path $script:sb.Home 'Downloads\c.bin'
        $cred = Join-Path $script:sb.Home '.aws\credentials'
        $null = Add-SandboxFile -Path $kept -Bytes 1024 -LastWriteUtc ([datetime]::new(2020, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $null = Add-SandboxFile -Path $cred -Bytes 1024 -LastWriteUtc ([datetime]::new(2023, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $doubled = $script:sb.Home + '\\.aws\\credentials'
        $group = [ordered]@{ bytes = 1024; sha256 = (Get-FileSha256 $kept); paths = @($kept, $doubled) }
        ConvertTo-JsonFile -InputObject ([ordered]@{ schemaVersion = 1; target = $script:sb.Home; home = $script:sb.Home; duplicates = @($group) }) -Path (Join-Path $script:sb.Out 'scan.json')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath $kept | Should -Be $true
        Test-Path -LiteralPath $cred | Should -Be $true
        $row = Get-StepRow -Id 'exact-duplicates'
        $row[3] | Should -Be 'done'
        $row[6] | Should -Be 'deleted 0 files, 0 bytes, skipped 0'
    }

    It 'R4 never deletes a copy whose path has an 8.3 short name segment' {
        $kept = Join-Path $script:sb.Home 'Downloads\a.bin'
        $short = Join-Path $script:sb.Home 'AWS~1\a.bin'
        $null = Add-SandboxFile -Path $kept -Bytes 1024 -LastWriteUtc ([datetime]::new(2020, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $null = Add-SandboxFile -Path $short -Bytes 1024 -LastWriteUtc ([datetime]::new(2023, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $group = [ordered]@{ bytes = 1024; sha256 = (Get-FileSha256 $kept); paths = @($kept, $short) }
        ConvertTo-JsonFile -InputObject ([ordered]@{ schemaVersion = 1; target = $script:sb.Home; home = $script:sb.Home; duplicates = @($group) }) -Path (Join-Path $script:sb.Out 'scan.json')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath $short | Should -Be $true
        $row = Get-StepRow -Id 'exact-duplicates'
        $row[3] | Should -Be 'not-applicable'
        $row[6] | Should -Be 'nothing matched'
    }

    It 'R4 dedupe with an 8.3 short name scan target is not applicable and deletes nothing' {
        Initialize-DuplicateFixture
        $scanPath = Join-Path $script:sb.Out 'scan.json'
        $doc = Get-Content -LiteralPath $scanPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $doc.target = Join-Path $script:sb.Root 'HOME~1'
        ConvertTo-JsonFile -InputObject $doc -Path $scanPath
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Downloads\a.bin') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Videos2\a.bin') | Should -Be $true
        $row = Get-StepRow -Id 'exact-duplicates'
        $row[3] | Should -Be 'not-applicable'
        $row[6] | Should -Be 'no scan target'
    }

    It 'R5 m1 dedupe is refused when a critical path keeps an 8.3 segment' {
        Initialize-DuplicateFixture
        $short = Join-Path $script:sb.Root 'HOME~1'
        [System.IO.Directory]::CreateDirectory($short) | Out-Null
        [Environment]::SetEnvironmentVariable('USERPROFILE', $short, 'Process')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Downloads\a.bin') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Videos2\a.bin') | Should -Be $true
        $row = Get-StepRow -Id 'exact-duplicates'
        $row[3] | Should -Be 'refused'
        $row[6] | Should -Match '^unresolved critical path '
    }

    It 'R6 I1 a USERPROFILE that is not an existing folder exits 2 and credentials survive' {
        $kept = Join-Path $script:sb.Home 'Downloads\c.bin'
        $copy = Join-Path $script:sb.Home 'Videos2\c.bin'
        $cred = Join-Path $script:sb.Home '.aws\credentials'
        $null = Add-SandboxFile -Path $kept -Bytes 1024 -LastWriteUtc ([datetime]::new(2020, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $null = Add-SandboxFile -Path $copy -Bytes 1024 -LastWriteUtc ([datetime]::new(2022, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $null = Add-SandboxFile -Path $cred -Bytes 1024 -LastWriteUtc ([datetime]::new(2023, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $group = [ordered]@{ bytes = 1024; sha256 = (Get-FileSha256 $kept); paths = @($kept, $copy, $cred) }
        ConvertTo-JsonFile -InputObject ([ordered]@{ schemaVersion = 1; target = $script:sb.Home; home = $script:sb.Home; duplicates = @($group) }) -Path (Join-Path $script:sb.Out 'scan.json')
        [Environment]::SetEnvironmentVariable('USERPROFILE', ($script:sb.Home + ' '), 'Process')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 2
        $res.StdErr | Should -Match 'Invalid argument: USERPROFILE'
        Test-Path -LiteralPath $cred | Should -Be $true
        Test-Path -LiteralPath $kept | Should -Be $true
        Test-Path -LiteralPath $copy | Should -Be $true
    }

    It 'R6 m1 a scan made for the current home deletes the plain copy' {
        Initialize-DuplicateFixture
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Downloads\a.bin') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Videos2\a.bin') | Should -Be $false
    }

    It 'R6 m1 a scan made for another home refuses the exact duplicates step' {
        Initialize-DuplicateFixture
        $scanPath = Join-Path $script:sb.Out 'scan.json'
        $doc = Get-Content -LiteralPath $scanPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $doc.home = Join-Path $script:sb.Root 'elsewhere'
        ConvertTo-JsonFile -InputObject $doc -Path $scanPath
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Downloads\a.bin') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Videos2\a.bin') | Should -Be $true
        $row = Get-StepRow -Id 'exact-duplicates'
        $row[3] | Should -Be 'refused'
        $row[6] | Should -Be 'scan made for another home'
    }

    It 'R6 m1 a scan made for the same home in another letter case still matches on windows' {
        Initialize-DuplicateFixture
        $scanPath = Join-Path $script:sb.Out 'scan.json'
        $doc = Get-Content -LiteralPath $scanPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $doc.home = $script:sb.Home.ToUpperInvariant()
        ConvertTo-JsonFile -InputObject $doc -Path $scanPath
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Videos2\a.bin') | Should -Be $false
    }

    It 'R6 m1 a scan without a home refuses the exact duplicates step' {
        Initialize-DuplicateFixture
        $scanPath = Join-Path $script:sb.Out 'scan.json'
        $doc = Get-Content -LiteralPath $scanPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $doc.PSObject.Properties.Remove('home')
        ConvertTo-JsonFile -InputObject $doc -Path $scanPath
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Home 'Videos2\a.bin') | Should -Be $true
        $row = Get-StepRow -Id 'exact-duplicates'
        $row[3] | Should -Be 'refused'
        $row[6] | Should -Be 'scan made for another home'
    }

    It 'R8 old-versions removes only lower versions (contract test 15)' {
        $ext = Initialize-ExtensionFixture
        $res = Invoke-Cleanup -Arguments @('-Ids', 'ide-old-extensions')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $ext 'pub.ext-1.2.0') | Should -Be $false
        Test-Path -LiteralPath (Join-Path $ext 'pub.ext-1.10.0') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $ext 'pub.other-0.1.0') | Should -Be $true
        (Get-StepRow -Id 'ide-old-extensions')[3] | Should -Be 'done'
    }

    It 'R5 old-versions dry run deletes nothing' {
        $null = Initialize-ExtensionFixture
        $before = Get-CleanSnapshot -Sandbox $script:sb
        $res = Invoke-Cleanup -Arguments @('-DryRun', '-Ids', 'ide-old-extensions')
        $res.ExitCode | Should -Be 0
        $after = Get-CleanSnapshot -Sandbox $script:sb
        ($after -join "`n") | Should -Be ($before -join "`n")
        $row = Get-StepRow -Id 'ide-old-extensions'
        $row[3] | Should -Be 'dry-run'
        $row[6] | Should -Match '^would free '
    }

    It 'R6 skips docker-wsl-compact when not elevated' {
        $vhdx = Join-Path $script:sb.Home 'AppData\Local\Docker\wsl\disk\docker_data.vhdx'
        $null = Add-SandboxFile -Path $vhdx -Bytes 1024
        $res = Invoke-Cleanup -Arguments @('-Ids', 'docker-wsl-compact')
        $res.ExitCode | Should -Be 0
        $row = Get-StepRow -Id 'docker-wsl-compact'
        $row[3] | Should -Be 'skipped'
        $row[6] | Should -Be 'needs admin: rerun from a terminal started with "Run as administrator"'
        @(Get-StubCalls -Sandbox $script:sb | Where-Object { $_ -match '^(wsl|diskpart)' }).Count | Should -Be 0
        (Get-Item -LiteralPath $vhdx).Length | Should -Be 1024
    }
}

Describe 'cleanup.ps1 fix 1' {
    BeforeAll {
        $scriptPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\scripts\cleanup.ps1'
        $parsed = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $definitions = $parsed.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
        . ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"))
    }

    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }

    AfterEach {
        if ($null -ne $script:sb) {
            Restore-TestSandbox $script:sb
        }
    }

    It 'M1 refuses a matched path whose parent folder is a junction' {
        $docFile = Join-Path $script:sb.Home 'Documents\caches\important.txt'
        $null = Add-SandboxFile -Path $docFile -Bytes 1024
        $null = New-Item -ItemType Junction -Path (Join-Path $script:sb.Home '.gradle') -Target (Join-Path $script:sb.Home 'Documents')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'gradle-cache')
        $res.ExitCode | Should -Be 0
        $targetRow = @(Get-LogRows | Where-Object { $_[1] -eq 'gradle-cache' -and $_[2] -ne 'file' -and $_[2] -ne 'run' })[0]
        $targetRow[3] | Should -Be 'refused'
        $targetRow[6] | Should -Match '^protected path '
        Test-Path -LiteralPath $docFile | Should -Be $true
    }

    It 'M1 old-versions refuses a matched path whose parent folder is a junction' {
        $realDir = Join-Path $script:sb.Root 'elsewhere'
        $old = Join-Path $realDir 'extensions\pub.ext-1.2.0\package.json'
        $null = Add-SandboxFile -Path $old -Bytes 512
        $null = Add-SandboxFile -Path (Join-Path $realDir 'extensions\pub.ext-1.10.0\package.json') -Bytes 512
        $null = New-Item -ItemType Junction -Path (Join-Path $script:sb.Home '.vscode') -Target $realDir
        $res = Invoke-Cleanup -Arguments @('-Ids', 'ide-old-extensions')
        $res.ExitCode | Should -Be 0
        $targetRow = @(Get-LogRows | Where-Object { $_[1] -eq 'ide-old-extensions' -and $_[2] -ne 'file' -and $_[2] -ne 'run' })[0]
        $targetRow[3] | Should -Be 'refused'
        Test-Path -LiteralPath $old | Should -Be $true
    }

    It 'M1 skips a dedupe copy whose parent folder is a junction' {
        $kept = Join-Path $script:sb.Home 'Downloads\a.bin'
        $real = Join-Path $script:sb.Home 'Videos2\a.bin'
        $null = Add-SandboxFile -Path $kept -Bytes 1024 -LastWriteUtc ([datetime]::new(2020, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $null = Add-SandboxFile -Path $real -Bytes 1024 -LastWriteUtc ([datetime]::new(2022, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $null = New-Item -ItemType Junction -Path (Join-Path $script:sb.Home 'Linked') -Target (Join-Path $script:sb.Home 'Videos2')
        $group = [ordered]@{ bytes = 1024; sha256 = (Get-FileSha256 $kept); paths = @($kept, (Join-Path $script:sb.Home 'Linked\a.bin')) }
        ConvertTo-JsonFile -InputObject ([ordered]@{ schemaVersion = 1; target = $script:sb.Home; home = $script:sb.Home; duplicates = @($group) }) -Path (Join-Path $script:sb.Out 'scan.json')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath $real | Should -Be $true
        $targetRow = @(Get-LogRows | Where-Object { $_[1] -eq 'exact-duplicates' -and $_[2] -ne 'file' -and $_[2] -ne 'run' })[0]
        $targetRow[3] | Should -Be 'not-applicable'
    }

    It 'M2 Write-LogLine keeps seven columns when the detail holds a tab or newline' {
        $log = Join-Path $script:sb.Out 'direct.log'
        Write-LogLine -Path $log -Id 'x' -Action 'file' -Result 'refused' -FreeBefore 1 -FreeAfter 2 -Detail "protected path a`tb`r`nc"
        $lines = @([System.IO.File]::ReadAllLines($log))
        $lines.Count | Should -Be 1
        @($lines[0] -split "`t").Count | Should -Be 7
    }

    It 'M4 runs no before command when every matched path is refused' {
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Home 'Documents\precious.txt') -Bytes 1024
        $null = New-Item -ItemType Directory -Path (Join-Path $script:sb.Home '.gradle') -Force
        $null = New-Item -ItemType Junction -Path (Join-Path $script:sb.Home '.gradle\caches') -Target (Join-Path $script:sb.Home 'Documents')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'gradle-cache')
        $res.ExitCode | Should -Be 0
        (Get-StubCalls -Sandbox $script:sb).Count | Should -Be 0
    }
}

Describe 'cleanup.ps1 round 1' {
    BeforeAll {
        $scriptPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\scripts\cleanup.ps1'
        $parsed = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $definitions = $parsed.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
        . ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"))

        function Get-StepRow {
            param([string]$Id)
            return @(Get-LogRows | Where-Object { $_[1] -eq $Id -and $_[2] -ne 'file' -and $_[2] -ne 'run' })[0]
        }
    }

    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }

    AfterEach {
        if ($null -ne $script:sb) {
            Restore-TestSandbox $script:sb
        }
    }

    It 'I1 keeps a folder that was already empty and removes a folder the run emptied' {
        $caches = Join-Path $script:sb.Home '.gradle\caches'
        $null = Add-SandboxFile -Path (Join-Path $caches 'a\b\c.bin') -Bytes 1024
        $null = New-Item -ItemType Directory -Path (Join-Path $caches 'already-empty') -Force
        $res = Invoke-Cleanup -Arguments @('-Ids', 'gradle-cache')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath $caches | Should -Be $true
        Test-Path -LiteralPath (Join-Path $caches 'already-empty') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $caches 'a') | Should -Be $false
    }

    It 'I1 never removes the rule root when the run empties it' {
        $caches = Join-Path $script:sb.Home '.gradle\caches'
        $null = Add-SandboxFile -Path (Join-Path $caches 'only.bin') -Bytes 1024
        $res = Invoke-Cleanup -Arguments @('-Ids', 'gradle-cache')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath $caches | Should -Be $true
    }

    It 'I1 keeps a folder that still holds a file the run skipped' {
        $caches = Join-Path $script:sb.Home '.gradle\caches'
        $null = Add-SandboxFile -Path (Join-Path $caches 'mix\db.mdf') -Bytes 1024
        $null = Add-SandboxFile -Path (Join-Path $caches 'mix\other.bin') -Bytes 1024
        $res = Invoke-Cleanup -Arguments @('-Ids', 'gradle-cache')
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $caches 'mix\db.mdf') | Should -Be $true
        Test-Path -LiteralPath (Join-Path $caches 'mix\other.bin') | Should -Be $false
    }

    It 'I2 deletes the exact non-ASCII file and never its ASCII sibling' {
        $wide = [string][char]0x141
        $old = (Get-Date).ToUniversalTime().AddDays(-3)
        $oldPath = Join-Path $script:sb.Temp ($wide + 'og.log')
        $siblingPath = Join-Path $script:sb.Temp 'Log.log'
        $null = Add-SandboxFile -Path $oldPath -Bytes 1024 -LastWriteUtc $old
        $null = Add-SandboxFile -Path $siblingPath -Bytes 2048
        $res = Invoke-Cleanup -Arguments @('-Ids', 'user-temp')
        $res.ExitCode | Should -Be 0
        [System.IO.File]::Exists($siblingPath) | Should -Be $true
        [System.IO.File]::Exists($oldPath) | Should -Be $false
    }

    It 'I2 skips a listed file that no longer qualifies' {
        $keep = Add-SandboxFile -Path (Join-Path $script:sb.Home '.gradle\caches\keep.txt') -Bytes 1024
        $root = Join-Path $script:sb.Home '.gradle\caches'
        Test-ListedFile -Path $keep -Root $root -Include @('*.bin') -MinBytes 0 -MinAgeDays 0 | Should -Be $false
        Test-ListedFile -Path $keep -Root $root -Include @('*.txt') -MinBytes 2048 -MinAgeDays 0 | Should -Be $false
        Test-ListedFile -Path $keep -Root $root -Include @('*.txt') -MinBytes 0 -MinAgeDays 5 | Should -Be $false
        Test-ListedFile -Path $keep -Root (Join-Path $script:sb.Home 'Other') -Include @('*.txt') -MinBytes 0 -MinAgeDays 0 | Should -Be $false
        Test-ListedFile -Path (Join-Path $root 'missing.txt') -Root $root -Include @('*.txt') -MinBytes 0 -MinAgeDays 0 | Should -Be $false
        Test-ListedFile -Path $root -Root $root -Include @('*') -MinBytes 0 -MinAgeDays 0 | Should -Be $false
        Test-ListedFile -Path $keep -Root $root -Include @('*.*') -MinBytes 0 -MinAgeDays 0 | Should -Be $true
    }

    It 'I2 skips a listed file that is a reparse point' {
        $target = Add-SandboxFile -Path (Join-Path $script:sb.Home 'Documents\real.txt') -Bytes 1024
        $root = Join-Path $script:sb.Home '.gradle\caches'
        $null = New-Item -ItemType Directory -Path $root -Force
        $link = Join-Path $root 'link.txt'
        try {
            $null = New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop
        } catch {
            Set-ItResult -Skipped -Because 'file symlinks need developer mode or admin'
            return
        }
        Test-ListedFile -Path $link -Root $root -Include @('*') -MinBytes 0 -MinAgeDays 0 | Should -Be $false
        $res = Invoke-Cleanup -Arguments @('-Ids', 'gradle-cache')
        $res.ExitCode | Should -Be 0
        [System.IO.File]::Exists($target) | Should -Be $true
        (Get-Item -LiteralPath $link -Force).LinkType | Should -Be 'SymbolicLink'
    }

    It 'm5 app-logs-oversized does not recurse into the Temp folder' {
        $fix = Write-FixtureRules -Sandbox $script:sb -Transform {
            param($doc)
            foreach ($r in $doc.rules) {
                if ($r.id -eq 'app-logs-oversized') {
                    $r.action.minSizeMB = 0
                }
            }
        }
        $appLog = Join-Path $script:sb.Local 'app\big.log'
        $tempLog = Join-Path $script:sb.Temp 'big.log'
        $null = Add-SandboxFile -Path $appLog -Bytes 1024
        $null = Add-SandboxFile -Path $tempLog -Bytes 1024
        $res = Invoke-Cleanup -Arguments @('-RulesPath', $fix, '-Ids', 'app-logs-oversized')
        $res.ExitCode | Should -Be 0
        [System.IO.File]::Exists($appLog) | Should -Be $false
        [System.IO.File]::Exists($tempLog) | Should -Be $true
    }

    It 'I3 a tool rule with match entries and no path under the scan target is not applicable' {
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Local 'npm-cache\x.bin') -Bytes 1024
        $isolated = Join-Path $script:sb.Home 'Isolated'
        $null = New-Item -ItemType Directory -Path $isolated -Force
        ConvertTo-JsonFile -InputObject ([ordered]@{ schemaVersion = 1; target = $isolated; home = $script:sb.Home; duplicates = @() }) -Path (Join-Path $script:sb.Out 'scan.json')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'npm-cache')
        $res.ExitCode | Should -Be 0
        $row = Get-StepRow -Id 'npm-cache'
        $row[3] | Should -Be 'not-applicable'
        $row[6] | Should -Be 'nothing matched'
        @(Get-StubCalls -Sandbox $script:sb | Where-Object { $_ -match '^npm' }).Count | Should -Be 0
    }

    It 'I3 a tool rule runs when a match entry exists under the scan target' {
        $null = Add-SandboxFile -Path (Join-Path $script:sb.Local 'npm-cache\x.bin') -Bytes 1024
        ConvertTo-JsonFile -InputObject ([ordered]@{ schemaVersion = 1; target = $script:sb.Home; home = $script:sb.Home; duplicates = @() }) -Path (Join-Path $script:sb.Out 'scan.json')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'npm-cache')
        $res.ExitCode | Should -Be 0
        (Get-StepRow -Id 'npm-cache')[3] | Should -Be 'done'
        (Get-StubCalls -Sandbox $script:sb) -contains 'npm cache clean --force' | Should -Be $true
    }

    It 'I3 dism-component-cleanup is decided by the drive of the scan target' {
        Mock Test-IsElevated { $true }
        $rules = Get-DiskCleanupRules -Path (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json')
        $rule = @($rules | Where-Object { $_.id -eq 'dism-component-cleanup' })[0]
        $systemTarget = $env:SystemDrive + '\'
        $onSystem = [pscustomobject]@{ Platform = 'windows'; Target = $systemTarget }
        Get-StepDecision -Id $rule.id -Rule $rule -Context $onSystem | Should -BeNullOrEmpty
        $homeOnSystem = [string]::Equals([System.IO.Path]::GetPathRoot($script:sb.Home), [System.IO.Path]::GetPathRoot($systemTarget), [System.StringComparison]::OrdinalIgnoreCase)
        if ($homeOnSystem) {
            Set-ItResult -Skipped -Because 'the sandbox is on the system drive'
            return
        }
        $offSystem = [pscustomobject]@{ Platform = 'windows'; Target = $script:sb.Home }
        $decision = Get-StepDecision -Id $rule.id -Rule $rule -Context $offSystem
        $decision.Result | Should -Be 'not-applicable'
        $decision.Detail | Should -Be 'nothing matched'
    }

    It 'I5 fails the compaction step without shutting Docker down when the scan folder is missing' {
        $vhdx = Join-Path $script:sb.Home 'AppData\Local\Docker\wsl\disk\docker_data.vhdx'
        $null = Add-SandboxFile -Path $vhdx -Bytes 1024
        $rules = Get-DiskCleanupRules -Path (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json')
        $rule = @($rules | Where-Object { $_.id -eq 'docker-wsl-compact' })[0]
        Mock Invoke-DockerShutdown { $true }
        Mock Invoke-DiskpartCompact { 0 }
        foreach ($folder in @('', (Join-Path $script:sb.Root 'missing-folder'))) {
            $context = [pscustomobject]@{ DryRun = $false; Platform = 'windows'; Target = $null; ScanFolder = $folder }
            $res = Invoke-CompactVhdxAction -Rule $rule -Context $context
            $res.Result | Should -Be 'failed'
        }
        Should -Invoke Invoke-DockerShutdown -Times 0 -Exactly
        Should -Invoke Invoke-DiskpartCompact -Times 0 -Exactly
    }

    It 'm4 starts Docker Desktop again after compaction when it was running' {
        $vhdx = Join-Path $script:sb.Home 'AppData\Local\Docker\wsl\disk\docker_data.vhdx'
        $null = Add-SandboxFile -Path $vhdx -Bytes 1024
        $rules = Get-DiskCleanupRules -Path (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json')
        $rule = @($rules | Where-Object { $_.id -eq 'docker-wsl-compact' })[0]
        $context = [pscustomobject]@{ DryRun = $false; Platform = 'windows'; Target = $null; ScanFolder = $script:sb.Out }
        Mock Invoke-DockerShutdown { $true }
        Mock Invoke-DiskpartCompact { 0 }
        Mock Invoke-DockerDesktopLaunch { }
        Mock Get-DockerDesktopPath { 'Docker Desktop.exe' }
        $res = Invoke-CompactVhdxAction -Rule $rule -Context $context
        $res.Result | Should -Be 'done'
        Should -Invoke Invoke-DockerDesktopLaunch -Times 1 -Exactly
    }

    It 'm4 starts Docker Desktop again when diskpart fails' {
        $vhdx = Join-Path $script:sb.Home 'AppData\Local\Docker\wsl\disk\docker_data.vhdx'
        $null = Add-SandboxFile -Path $vhdx -Bytes 1024
        $rules = Get-DiskCleanupRules -Path (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json')
        $rule = @($rules | Where-Object { $_.id -eq 'docker-wsl-compact' })[0]
        $context = [pscustomobject]@{ DryRun = $false; Platform = 'windows'; Target = $null; ScanFolder = $script:sb.Out }
        Mock Invoke-DockerShutdown { $true }
        Mock Invoke-DiskpartCompact { 1 }
        Mock Invoke-DockerDesktopLaunch { }
        Mock Get-DockerDesktopPath { 'Docker Desktop.exe' }
        $res = Invoke-CompactVhdxAction -Rule $rule -Context $context
        $res.Result | Should -Be 'failed'
        Should -Invoke Invoke-DockerDesktopLaunch -Times 1 -Exactly
    }

    It 'm4 leaves Docker Desktop stopped when it was not running' {
        $vhdx = Join-Path $script:sb.Home 'AppData\Local\Docker\wsl\disk\docker_data.vhdx'
        $null = Add-SandboxFile -Path $vhdx -Bytes 1024
        $rules = Get-DiskCleanupRules -Path (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json')
        $rule = @($rules | Where-Object { $_.id -eq 'docker-wsl-compact' })[0]
        $context = [pscustomobject]@{ DryRun = $false; Platform = 'windows'; Target = $null; ScanFolder = $script:sb.Out }
        Mock Invoke-DockerShutdown { $true }
        Mock Invoke-DiskpartCompact { 0 }
        Mock Invoke-DockerDesktopLaunch { }
        Mock Get-DockerDesktopPath { $null }
        $res = Invoke-CompactVhdxAction -Rule $rule -Context $context
        $res.Result | Should -Be 'done'
        Should -Invoke Invoke-DockerDesktopLaunch -Times 0 -Exactly
    }

    It 'I5 cleanup accepts a forward slash scan path and log path' {
        $scan = (Join-Path $script:sb.Out 'scan.json').Replace([char]92, [char]47)
        $log = (Join-Path $script:sb.Out 'fwd.log').Replace([char]92, [char]47)
        $res = Invoke-DiskCleanupScript -Name 'cleanup.ps1' -Arguments @('-Ids', 'no-such-rule', '-ScanPath', $scan, '-LogPath', $log)
        $res.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:sb.Out 'fwd.log') | Should -Be $true
    }

    It 'I7 a step that throws is recorded as failed and the run continues' {
        $fix = Write-FixtureRules -Sandbox $script:sb -Transform {
            param($doc)
            $newRule = [ordered]@{
                id = 'test-throwing-step'
                tier = 'safe'
                platforms = @('windows')
                match = [ordered]@{ windows = @('${HOME}/Throwing') }
                action = [ordered]@{ type = 'delete-files'; minSizeMB = 'not-a-number' }
                needsAdmin = $false
                description = 'Test rule'
                reason = 'Test rule'
            }
            $doc.rules = @($doc.rules) + $newRule
        }
        $res = Invoke-Cleanup -Arguments @('-RulesPath', $fix, '-Ids', 'test-throwing-step,ide-old-extensions')
        $res.ExitCode | Should -Be 1
        (Get-StepRow -Id 'test-throwing-step')[3] | Should -Be 'failed'
        (Get-StepRow -Id 'test-throwing-step')[6] | Should -Not -BeNullOrEmpty
        $res.StdOut | Should -Match 'failed test-throwing-step: .+'
        (Get-StepRow -Id 'ide-old-extensions')[3] | Should -Be 'not-applicable'
        $res.StdOut | Should -Match 'Free space: '
        @(Get-LogRows | Where-Object { $_[1] -eq '-' -and $_[2] -eq 'run' -and $_[3] -eq 'end' }).Count | Should -Be 1
    }

    It 'R2 a locked duplicate copy is skipped and the rest of the group is processed' {
        $first = Join-Path $script:sb.Home 'Downloads\a.bin'
        $second = Join-Path $script:sb.Home 'Videos2\a.bin'
        $third = Join-Path $script:sb.Home 'Music2\a.bin'
        $null = Add-SandboxFile -Path $first -Bytes 1024 -LastWriteUtc ([datetime]::new(2020, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $null = Add-SandboxFile -Path $second -Bytes 1024 -LastWriteUtc ([datetime]::new(2022, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $null = Add-SandboxFile -Path $third -Bytes 1024 -LastWriteUtc ([datetime]::new(2023, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $group = [ordered]@{ bytes = 1024; sha256 = (Get-FileSha256 $first); paths = @($first, $second, $third) }
        ConvertTo-JsonFile -InputObject ([ordered]@{ schemaVersion = 1; target = $script:sb.Home; home = $script:sb.Home; duplicates = @($group) }) -Path (Join-Path $script:sb.Out 'scan.json')
        $lock = [System.IO.File]::Open($second, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        } finally {
            $lock.Dispose()
        }
        $res.ExitCode | Should -Be 0
        (Get-StepRow -Id 'exact-duplicates')[3] | Should -Not -Be 'failed'
        [System.IO.File]::Exists($first) | Should -Be $true
        [System.IO.File]::Exists($second) | Should -Be $true
        [System.IO.File]::Exists($third) | Should -Be $false
    }

    It 'R2 Test-ListedFile returns false when the file attributes cannot be read' {
        Mock Test-ReparsePoint { throw 'access denied' }
        $path = Join-Path $script:sb.Home 'Downloads\a.bin'
        $null = Add-SandboxFile -Path $path -Bytes 1024
        Test-ListedFile -Path $path -Root $script:sb.Home -Include @('*.*') -MinBytes 0 -MinAgeDays 0 | Should -Be $false
    }

    It 'R2 Test-DuplicateCopyUnchanged returns false when the hash cannot be computed' {
        Mock Get-FileSha256 { throw 'locked' }
        $path = Join-Path $script:sb.Home 'Downloads\a.bin'
        $null = Add-SandboxFile -Path $path -Bytes 1024
        $group = [pscustomobject]@{ bytes = 1024; sha256 = 'x'; paths = @($path) }
        $context = [pscustomobject]@{ Home = $script:sb.Home; Target = $script:sb.Home }
        Test-DuplicateCopyUnchanged -Path $path -Group $group -Context $context | Should -Be $false
    }

    It 'R2 Docker Desktop is launched unelevated through explorer' {
        Mock Start-Process { }
        Invoke-DockerDesktopLaunch -Path 'C:\Program Files\Docker\Docker Desktop.exe'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'explorer.exe' -and $ArgumentList -eq '"C:\Program Files\Docker\Docker Desktop.exe"' }
    }

    It 'R2 an old version folder that became a junction is not deleted' {
        $root = Join-Path $script:sb.Home 'Root'
        $real = Join-Path $script:sb.Home 'Real'
        $null = Add-SandboxFile -Path (Join-Path $real 'keep.bin') -Bytes 1024
        $null = New-Item -ItemType Directory -Path $root -Force
        $junction = Join-Path $root 'pkg-1.0.0'
        $null = New-Item -ItemType Junction -Path $junction -Target $real
        $context = [pscustomobject]@{ NullDir = $null; CriticalSet = $null }
        $outcome = Invoke-OldVersionFolderDeletion -Directory $junction -Root $root -Context $context
        $outcome.Deleted | Should -Be 0
        $outcome.Skipped | Should -Be 1
        [System.IO.File]::Exists((Join-Path $real 'keep.bin')) | Should -Be $true
    }

    It 'R2 an old version folder outside the rule root is not deleted' {
        $root = Join-Path $script:sb.Home 'Root'
        $outside = Join-Path $script:sb.Home 'Outside\pkg-1.0.0'
        $null = Add-SandboxFile -Path (Join-Path $outside 'keep.bin') -Bytes 1024
        $null = New-Item -ItemType Directory -Path $root -Force
        $context = [pscustomobject]@{ NullDir = $null; CriticalSet = $null }
        $outcome = Invoke-OldVersionFolderDeletion -Directory $outside -Root $root -Context $context
        $outcome.Deleted | Should -Be 0
        $outcome.Skipped | Should -Be 1
        [System.IO.File]::Exists((Join-Path $outside 'keep.bin')) | Should -Be $true
    }

    It 'R2 extensions.json fsPath with backslashes keeps the referenced version folder' {
        $ext = Join-Path $script:sb.Home '.vscode\extensions'
        $null = Add-SandboxFile -Path (Join-Path $ext 'pub.other-0.1.0\package.json') -Bytes 512
        $null = Add-SandboxFile -Path (Join-Path $ext 'pub.other-0.2.0\package.json') -Bytes 512
        $entries = @(
            [ordered]@{ identifier = [ordered]@{ id = 'pub.other' }; location = [ordered]@{ fsPath = (Join-Path $ext 'pub.other-0.1.0') } }
        )
        [System.IO.File]::WriteAllText((Join-Path $ext 'extensions.json'), (ConvertTo-Json -InputObject $entries -Depth 5), (New-Object System.Text.UTF8Encoding $false))
        $res = Invoke-Cleanup -Arguments @('-Ids', 'ide-old-extensions')
        $res.ExitCode | Should -Be 0
        [System.IO.File]::Exists((Join-Path $ext 'pub.other-0.1.0\package.json')) | Should -Be $true
        [System.IO.File]::Exists((Join-Path $ext 'pub.other-0.2.0\package.json')) | Should -Be $true
    }

    It 'm2 a hard link of the kept copy is not deleted and a real copy is' {
        $kept = Join-Path $script:sb.Home 'Downloads\a.bin'
        $linked = Join-Path $script:sb.Home 'Videos2\a.bin'
        $real = Join-Path $script:sb.Home 'Music2\a.bin'
        $null = Add-SandboxFile -Path $kept -Bytes 1024 -LastWriteUtc ([datetime]::new(2020, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $linked) -Force
        $null = New-Item -ItemType HardLink -Path $linked -Target $kept
        $null = Add-SandboxFile -Path $real -Bytes 1024 -LastWriteUtc ([datetime]::new(2022, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $group = [ordered]@{ bytes = 1024; sha256 = (Get-FileSha256 $kept); paths = @($kept, $linked, $real) }
        ConvertTo-JsonFile -InputObject ([ordered]@{ schemaVersion = 1; target = $script:sb.Home; home = $script:sb.Home; duplicates = @($group) }) -Path (Join-Path $script:sb.Out 'scan.json')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        [System.IO.File]::Exists($kept) | Should -Be $true
        [System.IO.File]::Exists($linked) | Should -Be $true
        [System.IO.File]::Exists($real) | Should -Be $false
        (Get-StepRow -Id 'exact-duplicates')[6] | Should -Be 'deleted 1 files, 1024 bytes, skipped 0'
    }

    It 'm2 two paths that are the same file delete nothing' {
        $kept = Join-Path $script:sb.Home 'Downloads\a.bin'
        $linked = Join-Path $script:sb.Home 'Videos2\a.bin'
        $null = Add-SandboxFile -Path $kept -Bytes 1024 -LastWriteUtc ([datetime]::new(2020, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $linked) -Force
        $null = New-Item -ItemType HardLink -Path $linked -Target $kept
        $group = [ordered]@{ bytes = 1024; sha256 = (Get-FileSha256 $kept); paths = @($kept, $linked) }
        ConvertTo-JsonFile -InputObject ([ordered]@{ schemaVersion = 1; target = $script:sb.Home; home = $script:sb.Home; duplicates = @($group) }) -Path (Join-Path $script:sb.Out 'scan.json')
        $res = Invoke-Cleanup -Arguments @('-Ids', 'exact-duplicates')
        $res.ExitCode | Should -Be 0
        [System.IO.File]::Exists($kept) | Should -Be $true
        [System.IO.File]::Exists($linked) | Should -Be $true
        (Get-StepRow -Id 'exact-duplicates')[6] | Should -Be 'deleted 0 files, 0 bytes, skipped 0'
    }

    It 'm3 never deletes a version folder that extensions.json references' {
        $ext = Join-Path $script:sb.Home '.vscode\extensions'
        $null = Add-SandboxFile -Path (Join-Path $ext 'pub.ext-1.2.0\package.json') -Bytes 512
        $null = Add-SandboxFile -Path (Join-Path $ext 'pub.ext-1.10.0\package.json') -Bytes 512
        $null = Add-SandboxFile -Path (Join-Path $ext 'pub.other-0.1.0\package.json') -Bytes 512
        $null = Add-SandboxFile -Path (Join-Path $ext 'pub.other-0.2.0\package.json') -Bytes 512
        $null = Add-SandboxFile -Path (Join-Path $ext 'pub.third-1.0.0\package.json') -Bytes 512
        $null = Add-SandboxFile -Path (Join-Path $ext 'pub.third-2.0.0\package.json') -Bytes 512
        $entries = @(
            [ordered]@{ identifier = [ordered]@{ id = 'pub.ext' }; relativeLocation = 'pub.ext-1.2.0' },
            [ordered]@{ identifier = [ordered]@{ id = 'pub.other' }; location = [ordered]@{ path = '/c:/x/.vscode/extensions/pub.other-0.1.0'; scheme = 'file' } }
        )
        [System.IO.File]::WriteAllText((Join-Path $ext 'extensions.json'), (ConvertTo-Json -InputObject $entries -Depth 5), (New-Object System.Text.UTF8Encoding $false))
        $res = Invoke-Cleanup -Arguments @('-Ids', 'ide-old-extensions')
        $res.ExitCode | Should -Be 0
        [System.IO.File]::Exists((Join-Path $ext 'pub.ext-1.2.0\package.json')) | Should -Be $true
        [System.IO.File]::Exists((Join-Path $ext 'pub.other-0.1.0\package.json')) | Should -Be $true
        [System.IO.File]::Exists((Join-Path $ext 'pub.third-1.0.0\package.json')) | Should -Be $false
        [System.IO.File]::Exists((Join-Path $ext 'pub.third-2.0.0\package.json')) | Should -Be $true
    }
}

Describe 'cleanup.ps1 CI1' {
    BeforeAll {
        $scriptPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\scripts\cleanup.ps1'
        $parsed = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $definitions = $parsed.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
        . ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"))
    }

    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }

    AfterEach {
        if ($null -ne $script:sb) {
            Restore-TestSandbox $script:sb
        }
    }

    It 'I3 runs diskpart with /s and a script file inside the scan folder that is gone afterwards' {
        $stub = "@echo %~n0 %*>>`"%DISK_CLEANUP_STUB_LOG%`"`r`n@type `"%~2`">>`"%DISK_CLEANUP_STUB_LOG%`"`r`n@exit /b 0`r`n"
        [System.IO.File]::WriteAllText((Join-Path $script:sb.Bin 'diskpart.cmd'), $stub, [System.Text.Encoding]::ASCII)
        $disk = Join-Path $script:sb.Home 'docker_data.vhdx'
        $code = Invoke-DiskpartCompact -Disk $disk -ScanFolder $script:sb.Out
        $code | Should -Be 0
        $calls = @(Get-StubCalls -Sandbox $script:sb)
        $calls[0] | Should -Match '^diskpart /s '
        $scriptFile = $calls[0].Substring('diskpart /s '.Length).Trim('"')
        [System.IO.Path]::GetDirectoryName($scriptFile) | Should -Be $script:sb.Out
        @($calls | Select-Object -Skip 1) | Should -Be @("select vdisk file=""$disk""", 'attach vdisk readonly', 'compact vdisk', 'detach vdisk', 'exit')
        @(Get-ChildItem -LiteralPath $script:sb.Out -Force).Count | Should -Be 0
    }

    It 'I3 compaction through the action runs diskpart once per disk and leaves no file in the scan folder' {
        $vhdx = Join-Path $script:sb.Home 'AppData\Local\Docker\wsl\disk\docker_data.vhdx'
        $null = Add-SandboxFile -Path $vhdx -Bytes 1024
        $rules = Get-DiskCleanupRules -Path (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json')
        $rule = @($rules | Where-Object { $_.id -eq 'docker-wsl-compact' })[0]
        $context = [pscustomobject]@{ DryRun = $false; Platform = 'windows'; Target = $null; ScanFolder = $script:sb.Out }
        Mock Invoke-DockerShutdown { $true }
        Mock Invoke-DockerDesktopLaunch { }
        Mock Get-DockerDesktopPath { $null }
        $res = Invoke-CompactVhdxAction -Rule $rule -Context $context
        $res.Result | Should -Be 'done'
        @(Get-StubCalls -Sandbox $script:sb | Where-Object { $_ -match '^diskpart /s ' }).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $script:sb.Out -Force).Count | Should -Be 0
    }

    It 'I3 deletes the script file when diskpart fails' {
        Add-FailingStub -Sandbox $script:sb -Name 'diskpart'
        $code = Invoke-DiskpartCompact -Disk (Join-Path $script:sb.Home 'd.vhdx') -ScanFolder $script:sb.Out
        $code | Should -Be 1
        @(Get-ChildItem -LiteralPath $script:sb.Out -Force).Count | Should -Be 0
    }

    It 'I3 fails the step without running diskpart when the script file already exists' {
        $vhdx = Join-Path $script:sb.Home 'AppData\Local\Docker\wsl\disk\docker_data.vhdx'
        $null = Add-SandboxFile -Path $vhdx -Bytes 1024
        $planted = Join-Path $script:sb.Out 'diskpart-compact.txt'
        [System.IO.File]::WriteAllText($planted, 'planted', [System.Text.Encoding]::ASCII)
        $rules = Get-DiskCleanupRules -Path (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json')
        $rule = @($rules | Where-Object { $_.id -eq 'docker-wsl-compact' })[0]
        $context = [pscustomobject]@{ DryRun = $false; Platform = 'windows'; Target = $null; ScanFolder = $script:sb.Out }
        Mock Invoke-DockerShutdown { $true }
        Mock Invoke-DockerDesktopLaunch { }
        Mock Get-DockerDesktopPath { $null }
        $res = Invoke-CompactVhdxAction -Rule $rule -Context $context
        $res.Result | Should -Be 'failed'
        $res.Detail | Should -Match '^diskpart script not created: '
        @(Get-StubCalls -Sandbox $script:sb | Where-Object { $_ -match '^diskpart' }).Count | Should -Be 0
        [System.IO.File]::ReadAllText($planted) | Should -Be 'planted'
    }
    It 'F2 uses the per-user LOCALAPPDATA diskscan folder for the scan file and the log by default' {
        $res = Invoke-DiskCleanupScript -Name 'cleanup.ps1' -Arguments @()
        $res.ExitCode | Should -Be 0
        [System.IO.File]::Exists((Join-Path $script:sb.Local 'diskscan\cleanup.log')) | Should -BeTrue
    }

    It 'F2 refuses a scan folder that is a junction with exit 3 before it writes anything' {
        $link = Join-Path $script:sb.Root 'linked-out'
        $null = New-Item -ItemType Junction -Path $link -Target $script:sb.Out
        try {
            $res = Invoke-DiskCleanupScript -Name 'cleanup.ps1' -Arguments @('-ScanPath', (Join-Path $link 'scan.json'))
            $res.ExitCode | Should -Be 3
            $res.StdErr | Should -Match 'Scan folder refused'
            @(Get-ChildItem -LiteralPath $script:sb.Out -Force).Count | Should -Be 0
        } finally {
            [System.IO.Directory]::Delete($link)
        }
    }

    It 'm6 checks a scan file given without a folder part and refuses a junction with exit 3' {
        $target = Join-Path $script:sb.Root 'junction-target'
        $null = New-Item -ItemType Directory -Path $target
        $link = Join-Path $script:sb.Out 'scan.json'
        $null = New-Item -ItemType Junction -Path $link -Target $target
        $previous = [System.Environment]::CurrentDirectory
        [System.Environment]::CurrentDirectory = $script:sb.Out
        try {
            $res = Invoke-DiskCleanupScript -Name 'cleanup.ps1' -Arguments @('-ScanPath', 'scan.json', '-Ids', 'npm-cache')
            $res.ExitCode | Should -Be 3
            $res.StdErr | Should -Match 'Scan folder refused'
        } finally {
            [System.Environment]::CurrentDirectory = $previous
            [System.IO.Directory]::Delete($link)
        }
    }
    It 'F2 never deletes an oversized log inside the scan folder while other oversized logs go' {
        $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
        $fixture = Get-Content -LiteralPath $rulesPath -Raw | ConvertFrom-Json
        @($fixture.rules | Where-Object { $_.id -eq 'app-logs-oversized' })[0].action.minSizeMB = 1
        $fixturePath = Join-Path $script:sb.Root 'rules.json'
        [System.IO.File]::WriteAllText($fixturePath, (ConvertTo-Json -InputObject $fixture -Depth 12), (New-Object System.Text.UTF8Encoding $false))
        $kept = Add-SandboxFile -Path (Join-Path $script:sb.Local 'diskscan\big.log') -Bytes 2097152
        $gone = Add-SandboxFile -Path (Join-Path $script:sb.Local 'OtherApp\big.log') -Bytes 2097152
        $res = Invoke-DiskCleanupScript -Name 'cleanup.ps1' -Arguments @('-Ids', 'app-logs-oversized', '-RulesPath', $fixturePath)
        $res.ExitCode | Should -Be 0
        [System.IO.File]::Exists($gone) | Should -BeFalse
        [System.IO.File]::Exists($kept) | Should -BeTrue
    }
}
