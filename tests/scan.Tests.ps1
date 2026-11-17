BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\scripts\common.ps1')

    function Invoke-TestScan {
        param([string[]]$Extra)
        Invoke-DiskCleanupScript -Name 'scan.ps1' -Arguments (@('-Target', $script:sb.Home, '-OutputDir', $script:sb.Out, '-MinFileMB', '1') + @($Extra))
    }
}

Describe 'scan.ps1' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
        $fixedDate = [datetime]::new(2026, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        Add-SandboxFile -Path (Join-Path $script:sb.Local 'npm-cache\x.bin') -Bytes 1024 -LastWriteUtc $fixedDate | Out-Null
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'Documents\notes\a.txt') -Bytes 10 -LastWriteUtc $fixedDate | Out-Null
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'Unrelated\b.txt') -Bytes 10 -LastWriteUtc $fixedDate | Out-Null
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'Downloads\big1.bin') -Bytes 2097152 -LastWriteUtc $fixedDate | Out-Null
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'Videos2\big2.bin') -Bytes 2097152 -LastWriteUtc $fixedDate | Out-Null
        Get-ChildItem -LiteralPath $script:sb.Root -Recurse -Directory | ForEach-Object {
            [System.IO.Directory]::SetLastWriteTimeUtc($_.FullName, $fixedDate)
        }
        [System.IO.Directory]::SetLastWriteTimeUtc($script:sb.Root, $fixedDate)
    }

    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'exits 0 and prints the Scan complete line' {
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        $res.StdOut | Should -Match 'Scan complete: .*scan\.json \(\d+ folders, 2 large files, 1 duplicate groups, \d+ unreadable\)'
    }

    It 'S1 writes nothing outside the output folder' {
        $fixedDate = [datetime]::new(2026, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        Get-ChildItem -LiteralPath $script:sb.Root -Recurse -Directory | ForEach-Object {
            [System.IO.Directory]::SetLastWriteTimeUtc($_.FullName, $fixedDate)
        }
        [System.IO.Directory]::SetLastWriteTimeUtc($script:sb.Root, $fixedDate)
        $before = Get-TreeSnapshot -Sandbox $script:sb
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        Remove-Item -LiteralPath (Join-Path $script:sb.Local 'Microsoft') -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $script:sb.Root -Recurse -Directory | ForEach-Object {
            [System.IO.Directory]::SetLastWriteTimeUtc($_.FullName, $fixedDate)
        }
        [System.IO.Directory]::SetLastWriteTimeUtc($script:sb.Root, $fixedDate)
        $after = Get-TreeSnapshot -Sandbox $script:sb
        ($after -join "`n") | Should -Be ($before -join "`n")
    }

    It 'leaves only scan.json in the output folder' {
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        $files = @(Get-ChildItem -LiteralPath $script:sb.Out -Force -Name)
        $files | Should -Be @('scan.json')
    }

    It 'S2 refuses an output folder inside Temp with exit 3 and creates nothing' {
        $fixedDate = [datetime]::new(2026, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        $tempOut = Join-Path $script:sb.Temp 'diskscan'
        Get-ChildItem -LiteralPath $script:sb.Root -Recurse -Directory | ForEach-Object {
            [System.IO.Directory]::SetLastWriteTimeUtc($_.FullName, $fixedDate)
        }
        [System.IO.Directory]::SetLastWriteTimeUtc($script:sb.Root, $fixedDate)
        $before = Get-TreeSnapshot -Sandbox $script:sb
        $res = Invoke-DiskCleanupScript -Name 'scan.ps1' -Arguments @('-Target', $script:sb.Home, '-OutputDir', $tempOut)
        $res.ExitCode | Should -Be 3
        $res.StdErr | Should -Match 'Output folder refused: .* is inside a Temp folder'
        (Test-Path -LiteralPath $tempOut) | Should -BeFalse
        Remove-Item -LiteralPath (Join-Path $script:sb.Local 'Microsoft') -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $script:sb.Root -Recurse -Directory | ForEach-Object {
            [System.IO.Directory]::SetLastWriteTimeUtc($_.FullName, $fixedDate)
        }
        [System.IO.Directory]::SetLastWriteTimeUtc($script:sb.Root, $fixedDate)
        $after = Get-TreeSnapshot -Sandbox $script:sb
        ($after -join "`n") | Should -Be ($before -join "`n")
    }

    It 'lists a 2 MiB file with its exact size' {
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        $json = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw | ConvertFrom-Json
        $target = Join-Path $script:sb.Home 'Downloads\big1.bin'
        $file = @($json.largeFiles | Where-Object { $_.path -eq $target })
        $file.Count | Should -Be 1
        $file[0].bytes | Should -Be 2097152
        $modVal = if ($file[0].modified -is [datetime]) { Format-UtcTimestamp $file[0].modified } else { [string]$file[0].modified }
        $modVal | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
    }

    It 'groups two identical 2 MiB files as one duplicate group' {
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        $json = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw | ConvertFrom-Json
        $json.duplicates.Count | Should -Be 1
        $json.duplicates[0].paths.Count | Should -Be 2
        $json.duplicates[0].bytes | Should -Be 2097152
        $json.duplicates[0].sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'F1 writes an empty duplicates array and counts 0 groups when nothing is duplicated' {
        Remove-Item -LiteralPath (Join-Path $script:sb.Home 'Videos2\big2.bin') -Force
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        $res.StdOut | Should -Match '1 large files, 0 duplicate groups,'
        $raw = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw
        $raw | Should -Match '"duplicates":\s*\[\s*\]'
        $raw | Should -Not -Match '"duplicates":\s*\[\s*\['
        $json = $raw | ConvertFrom-Json
        @($json.duplicates).Count | Should -Be 0
    }

    It 'emits every top-level key with the right types' {
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        $json = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw | ConvertFrom-Json
        $expectedKeys = @('schemaVersion', 'createdAt', 'os', 'target', 'home', 'minFileBytes', 'drive', 'rules', 'folders', 'largeFiles', 'duplicates', 'unreadable')
        $props = @($json.psobject.Properties.Name)
        $props | Should -Be $expectedKeys
        $json.schemaVersion | Should -Be 1
        $json.os | Should -Be 'windows'
        $json.target | Should -Be $script:sb.Home
        $json.minFileBytes | Should -Be 1048576
        $json.drive.root | Should -Match '^[A-Za-z]:\\$'
        $json.drive.totalBytes | Should -BeGreaterThan 0
        $json.drive.usedBytes | Should -BeGreaterThan 0
        $json.drive.freeBytes | Should -BeGreaterThan 0
        $createdVal = if ($json.createdAt -is [datetime]) { Format-UtcTimestamp $json.createdAt } else { [string]$json.createdAt }
        $createdVal | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
    }

    It 'S5 keeps one-element arrays as arrays' {
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        $raw = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw
        $raw | Should -Match '"unreadable":\s*\['
        $json = $raw | ConvertFrom-Json
        $npm = @($json.rules | Where-Object { $_.id -eq 'npm-cache' })[0]
        ($npm.paths -is [array]) | Should -BeTrue
        $npm.paths.Count | Should -Be 1
        foreach ($folder in $json.folders) {
            ($folder.ruleIds -is [array]) | Should -BeTrue
        }
    }

    It 'lists only rules for windows in file order' {
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        $json = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw | ConvertFrom-Json
        $allRules = Get-Content -LiteralPath (Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json') -Raw | ConvertFrom-Json
        $expectedIds = @($allRules.rules | Where-Object { $_.platforms -contains 'windows' } | ForEach-Object { $_.id })
        $actualIds = @($json.rules | ForEach-Object { $_.id })
        $actualIds | Should -Be $expectedIds
    }

    It 'reports a seeded npm cache as available with bytes' {
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        $json = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw | ConvertFrom-Json
        $npm = @($json.rules | Where-Object { $_.id -eq 'npm-cache' })[0]
        $npm.available | Should -BeTrue
        $npm.bytes | Should -BeGreaterThan 0
        $npm.paths | Should -Be @((Join-Path $script:sb.Local 'npm-cache'))
        $npm.tier | Should -Be 'safe'
    }

    It 'S4 marks a folder under Documents as critical' {
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        $json = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw | ConvertFrom-Json
        $doc = @($json.folders | Where-Object { $_.path -eq (Join-Path $script:sb.Home 'Documents') })
        $doc.Count | Should -Be 1
        $doc[0].tier | Should -Be 'critical'
        $doc[0].ruleIds | Should -Contain 'user-folders'
    }

    It 'S4 marks a folder no rule covers as critical' {
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        $json = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw | ConvertFrom-Json
        $unr = @($json.folders | Where-Object { $_.path -eq (Join-Path $script:sb.Home 'Unrelated') })
        $unr.Count | Should -Be 1
        $unr[0].tier | Should -Be 'critical'
        $unr[0].ruleIds.Count | Should -Be 0
    }

    It 'exits 2 for a missing target' {
        $missing = Join-Path $script:sb.Root 'missing'
        $res = Invoke-DiskCleanupScript -Name 'scan.ps1' -Arguments @('-Target', $missing, '-OutputDir', $script:sb.Out)
        $res.ExitCode | Should -Be 2
        $res.StdErr | Should -Match 'Invalid argument:'
    }

    It 'exits 4 for an invalid rules file' {
        $badRules = Join-Path $script:sb.Root 'bad.json'
        [System.IO.File]::WriteAllText($badRules, '{ bad')
        $res = Invoke-DiskCleanupScript -Name 'scan.ps1' -Arguments @('-Target', $script:sb.Home, '-OutputDir', $script:sb.Out, '-RulesPath', $badRules)
        $res.ExitCode | Should -Be 4
        $res.StdErr | Should -Match 'Rules file invalid:'
    }

    It 'R6 I1 exits 2 and writes nothing when USERPROFILE is not an existing folder' {
        [Environment]::SetEnvironmentVariable('USERPROFILE', ($script:sb.Home + ' '), 'Process')
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 2
        $res.StdErr | Should -Match 'Invalid argument: USERPROFILE'
        Test-Path -LiteralPath (Join-Path $script:sb.Out 'scan.json') | Should -Be $false
    }

    It 'R6 m1 writes the canonical home into scan.json' {
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        $json = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw | ConvertFrom-Json
        $json.home | Should -Be $script:sb.Home
    }

    It 'S3 runs no tool stub' {
        $res = Invoke-TestScan
        $res.ExitCode | Should -Be 0
        @(Get-StubCalls -Sandbox $script:sb).Count | Should -Be 0
    }
}
Describe 'scan.ps1 round 1' {
    BeforeEach {
        $script:sb = Initialize-TestSandbox
    }

    AfterEach {
        Restore-TestSandbox -Sandbox $script:sb
    }

    It 'I3 a tool rule with match entries but no path under the target is unavailable with zero bytes' {
        Add-SandboxFile -Path (Join-Path $script:sb.Local 'npm-cache\x.bin') -Bytes 1024 | Out-Null
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'Isolated\a.txt') -Bytes 10 | Out-Null
        $res = Invoke-DiskCleanupScript -Name 'scan.ps1' -Arguments @('-Target', (Join-Path $script:sb.Home 'Isolated'), '-OutputDir', $script:sb.Out, '-MinFileMB', '1')
        $res.ExitCode | Should -Be 0
        $json = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw | ConvertFrom-Json
        foreach ($id in @('nuget-cache', 'npm-cache', 'yarn-cache', 'pip-cache')) {
            $rule = @($json.rules | Where-Object { $_.id -eq $id })[0]
            $rule.available | Should -BeFalse -Because $id
            $rule.bytes | Should -Be 0 -Because $id
        }
    }

    It 'I3 a tool rule without match entries keeps null bytes' {
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'Isolated\a.txt') -Bytes 10 | Out-Null
        $res = Invoke-DiskCleanupScript -Name 'scan.ps1' -Arguments @('-Target', (Join-Path $script:sb.Home 'Isolated'), '-OutputDir', $script:sb.Out, '-MinFileMB', '1')
        $res.ExitCode | Should -Be 0
        $json = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw | ConvertFrom-Json
        $rule = @($json.rules | Where-Object { $_.id -eq 'docker-dangling-images' })[0]
        $rule.available | Should -BeTrue
        $null -eq $rule.bytes | Should -BeTrue
    }

    It 'I3 dism-component-cleanup is available only when the target is on the system drive' {
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'Isolated\a.txt') -Bytes 10 | Out-Null
        $res = Invoke-DiskCleanupScript -Name 'scan.ps1' -Arguments @('-Target', (Join-Path $script:sb.Home 'Isolated'), '-OutputDir', $script:sb.Out, '-MinFileMB', '1')
        $res.ExitCode | Should -Be 0
        $json = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw | ConvertFrom-Json
        $rule = @($json.rules | Where-Object { $_.id -eq 'dism-component-cleanup' })[0]
        $onSystemDrive = [string]::Equals([System.IO.Path]::GetPathRoot($script:sb.Home), [System.IO.Path]::GetPathRoot($env:SystemDrive + '\'), [System.StringComparison]::OrdinalIgnoreCase)
        $rule.available | Should -Be $onSystemDrive
        $null -eq $rule.bytes | Should -BeTrue
    }

    It 'I5 accepts a forward slash target and output folder' {
        Add-SandboxFile -Path (Join-Path $script:sb.Home 'Isolated\a.txt') -Bytes 10 | Out-Null
        $target = (Join-Path $script:sb.Home 'Isolated').Replace([char]92, [char]47)
        $outDir = $script:sb.Out.Replace([char]92, [char]47)
        $res = Invoke-DiskCleanupScript -Name 'scan.ps1' -Arguments @('-Target', $target, '-OutputDir', $outDir, '-MinFileMB', '1')
        $res.ExitCode | Should -Be 0
        $json = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw | ConvertFrom-Json
        $json.target | Should -Be (Join-Path $script:sb.Home 'Isolated')
    }

    It 'm2 hard linked copies claim no reclaimable bytes' {
        $fixedDate = [datetime]::new(2026, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        $kept = Join-Path $script:sb.Home 'Downloads\a.bin'
        $linked = Join-Path $script:sb.Home 'Videos2\a.bin'
        $null = Add-SandboxFile -Path $kept -Bytes 2097152 -LastWriteUtc $fixedDate
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $linked) -Force
        $null = New-Item -ItemType HardLink -Path $linked -Target $kept
        $res = Invoke-DiskCleanupScript -Name 'scan.ps1' -Arguments @('-Target', $script:sb.Home, '-OutputDir', $script:sb.Out, '-MinFileMB', '1')
        $res.ExitCode | Should -Be 0
        $json = Get-Content -LiteralPath (Join-Path $script:sb.Out 'scan.json') -Raw | ConvertFrom-Json
        $rule = @($json.rules | Where-Object { $_.id -eq 'exact-duplicates' })[0]
        $rule.bytes | Should -Be 0
    }

    It 'F2 writes scan.json to the per-user LOCALAPPDATA diskscan folder by default' {
        $res = Invoke-DiskCleanupScript -Name 'scan.ps1' -Arguments @('-Target', $script:sb.Home)
        $res.ExitCode | Should -Be 0
        $expected = Join-Path $script:sb.Local 'diskscan\scan.json'
        [System.IO.File]::Exists($expected) | Should -BeTrue
        $res.StdOut | Should -Match ([regex]::Escape($expected))
    }

    It 'F2 refuses an output folder that is a junction with exit 3' {
        $link = Join-Path $script:sb.Root 'linked-out'
        $null = New-Item -ItemType Junction -Path $link -Target $script:sb.Out
        try {
            $res = Invoke-DiskCleanupScript -Name 'scan.ps1' -Arguments @('-Target', $script:sb.Home, '-OutputDir', $link)
            $res.ExitCode | Should -Be 3
            $res.StdErr | Should -Match 'Output folder refused: .* is a link or not owned by the current user'
            @(Get-ChildItem -LiteralPath $script:sb.Out -Force).Count | Should -Be 0
        } finally {
            [System.IO.Directory]::Delete($link)
        }
    }

    It 'F2 trusts a missing path and a folder owned by the current user and refuses a junction' {
        Test-TrustedScanItem -Path (Join-Path $script:sb.Root 'missing') | Should -BeTrue
        Test-TrustedScanItem -Path $script:sb.Out | Should -BeTrue
        $link = Join-Path $script:sb.Root 'linked-check'
        $null = New-Item -ItemType Junction -Path $link -Target $script:sb.Out
        try {
            Test-TrustedScanItem -Path $link | Should -BeFalse
        } finally {
            [System.IO.Directory]::Delete($link)
        }
    }
}
