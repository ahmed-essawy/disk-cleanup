Describe 'rules.json' {
    BeforeAll {
        $script:RulesPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\disk-cleanup\rules\rules.json'
        $script:Raw = [System.IO.File]::ReadAllText($script:RulesPath, [System.Text.Encoding]::UTF8)
        $script:Data = $script:Raw | ConvertFrom-Json
        $script:Rules = @($script:Data.rules)
        $script:Expected = @(
            @{ Id = 'user-temp'; Tier = 'safe'; Platforms = 'windows,macos,linux'; Type = 'delete-files'; Admin = $false },
            @{ Id = 'nuget-cache'; Tier = 'safe'; Platforms = 'windows,macos,linux'; Type = 'tool'; Admin = $false },
            @{ Id = 'npm-cache'; Tier = 'safe'; Platforms = 'windows,macos,linux'; Type = 'tool'; Admin = $false },
            @{ Id = 'yarn-cache'; Tier = 'safe'; Platforms = 'windows,macos,linux'; Type = 'tool'; Admin = $false },
            @{ Id = 'pip-cache'; Tier = 'safe'; Platforms = 'windows,macos,linux'; Type = 'tool'; Admin = $false },
            @{ Id = 'gradle-cache'; Tier = 'safe'; Platforms = 'windows,macos,linux'; Type = 'clear-dir'; Admin = $false },
            @{ Id = 'maven-repository'; Tier = 'safe'; Platforms = 'windows,macos,linux'; Type = 'clear-dir'; Admin = $false },
            @{ Id = 'windows-update-cache'; Tier = 'safe'; Platforms = 'windows'; Type = 'clear-dir'; Admin = $true },
            @{ Id = 'dism-component-cleanup'; Tier = 'safe'; Platforms = 'windows'; Type = 'tool'; Admin = $true },
            @{ Id = 'crash-dumps'; Tier = 'safe'; Platforms = 'windows,macos'; Type = 'delete-files'; Admin = $false },
            @{ Id = 'app-logs-oversized'; Tier = 'safe'; Platforms = 'windows,macos,linux'; Type = 'delete-files'; Admin = $false },
            @{ Id = 'exact-duplicates'; Tier = 'your_call'; Platforms = 'windows,macos,linux'; Type = 'dedupe'; Admin = $false },
            @{ Id = 'docker-dangling-images'; Tier = 'your_call'; Platforms = 'windows,macos,linux'; Type = 'tool'; Admin = $false },
            @{ Id = 'docker-build-cache'; Tier = 'your_call'; Platforms = 'windows,macos,linux'; Type = 'tool'; Admin = $false },
            @{ Id = 'docker-wsl-compact'; Tier = 'your_call'; Platforms = 'windows'; Type = 'compact-docker-vhdx'; Admin = $true },
            @{ Id = 'ide-old-extensions'; Tier = 'your_call'; Platforms = 'windows,macos,linux'; Type = 'old-versions'; Admin = $false },
            @{ Id = 'android-system-images'; Tier = 'your_call'; Platforms = 'windows,macos,linux'; Type = 'clear-dir'; Admin = $false },
            @{ Id = 'chrome-on-device-model'; Tier = 'your_call'; Platforms = 'windows,macos,linux'; Type = 'clear-dir'; Admin = $false },
            @{ Id = 'claude-session-logs'; Tier = 'your_call'; Platforms = 'windows,macos,linux'; Type = 'delete-files'; Admin = $false },
            @{ Id = 'old-installers'; Tier = 'your_call'; Platforms = 'windows,macos,linux'; Type = 'delete-files'; Admin = $false },
            @{ Id = 'database-files'; Tier = 'critical'; Platforms = 'windows,macos,linux'; Type = $null; Admin = $false },
            @{ Id = 'database-data-dirs'; Tier = 'critical'; Platforms = 'windows,macos,linux'; Type = $null; Admin = $false },
            @{ Id = 'database-maintenance'; Tier = 'critical'; Platforms = 'windows,macos,linux'; Type = $null; Admin = $false },
            @{ Id = 'database-backups'; Tier = 'critical'; Platforms = 'windows,macos,linux'; Type = $null; Admin = $false },
            @{ Id = 'docker-data'; Tier = 'critical'; Platforms = 'windows,macos,linux'; Type = $null; Admin = $false },
            @{ Id = 'vm-disks'; Tier = 'critical'; Platforms = 'windows,macos,linux'; Type = $null; Admin = $false },
            @{ Id = 'restore-points'; Tier = 'critical'; Platforms = 'windows'; Type = $null; Admin = $false },
            @{ Id = 'pagefile-hibernation'; Tier = 'critical'; Platforms = 'windows,macos,linux'; Type = $null; Admin = $false },
            @{ Id = 'windows-system'; Tier = 'critical'; Platforms = 'windows'; Type = $null; Admin = $false },
            @{ Id = 'program-files'; Tier = 'critical'; Platforms = 'windows,macos,linux'; Type = $null; Admin = $false },
            @{ Id = 'programdata-apps'; Tier = 'critical'; Platforms = 'windows'; Type = $null; Admin = $false },
            @{ Id = 'mail-stores'; Tier = 'critical'; Platforms = 'windows,macos,linux'; Type = $null; Admin = $false },
            @{ Id = 'user-folders'; Tier = 'critical'; Platforms = 'windows,macos,linux'; Type = $null; Admin = $false },
            @{ Id = 'cloud-sync'; Tier = 'critical'; Platforms = 'windows,macos'; Type = $null; Admin = $false },
            @{ Id = 'source-code'; Tier = 'critical'; Platforms = 'windows,macos,linux'; Type = $null; Admin = $false },
            @{ Id = 'credentials'; Tier = 'critical'; Platforms = 'windows,macos,linux'; Type = $null; Admin = $false }
        )
    }

    It 'has version 1 and a rules array' {
        $script:Data.version | Should -Be 1
        $script:Data.rules | Should -Not -BeNullOrEmpty
        $script:Rules.Count | Should -Be 36
    }

    It 'lists the 36 catalog ids in catalog order' {
        $actualIds = @($script:Rules | ForEach-Object { $_.id })
        $expectedIds = @($script:Expected | ForEach-Object { $_.Id })
        $actualIds.Count | Should -Be 36
        for ($i = 0; $i -lt 36; $i++) {
            $actualIds[$i] | Should -Be $expectedIds[$i]
        }
    }

    It 'gives every catalog rule its tier, platforms, action type and needsAdmin' {
        foreach ($exp in $script:Expected) {
            $found = @($script:Rules | Where-Object { $_.id -eq $exp.Id })
            $found.Count | Should -Be 1
            $rule = $found[0]
            $rule.tier | Should -Be $exp.Tier
            ($rule.platforms -join ',') | Should -Be $exp.Platforms
            if ($null -eq $exp.Type) {
                $rule.action | Should -BeNullOrEmpty
            } else {
                $rule.action | Should -Not -BeNullOrEmpty
                $rule.action.type | Should -Be $exp.Type
            }
            $rule.needsAdmin | Should -Be $exp.Admin
        }
    }

    It 'has every required field on every rule' {
        $requiredFields = @('id', 'tier', 'platforms', 'match', 'action', 'needsAdmin', 'description', 'reason')
        foreach ($rule in $script:Rules) {
            foreach ($field in $requiredFields) {
                ($null -ne $rule.PSObject.Properties[$field]) | Should -BeTrue
            }
        }
    }

    It 'has unique kebab-case ids' {
        $ids = @($script:Rules | ForEach-Object { $_.id })
        $uniqueIds = @($ids | Select-Object -Unique)
        $uniqueIds.Count | Should -Be $ids.Count
        foreach ($id in $ids) {
            ($id -match '^[a-z0-9]+(-[a-z0-9]+)*$') | Should -BeTrue
        }
    }

    It 'has an action if and only if the tier is not critical' {
        $validTypes = @('tool', 'clear-dir', 'delete-files', 'old-versions', 'dedupe', 'compact-docker-vhdx')
        foreach ($rule in $script:Rules) {
            if ($rule.tier -eq 'critical') {
                $rule.action | Should -BeNullOrEmpty
            } else {
                $rule.action | Should -Not -BeNullOrEmpty
                ($validTypes -contains $rule.action.type) | Should -BeTrue
            }
        }
    }

    It 'never marks a critical rule needsAdmin and never gives it before commands' {
        $criticalRules = @($script:Rules | Where-Object { $_.tier -eq 'critical' })
        foreach ($rule in $criticalRules) {
            $rule.needsAdmin | Should -BeFalse
            $hasBefore = ($null -ne $rule.PSObject.Properties['before']) -and ($null -ne $rule.before)
            $hasBefore | Should -BeFalse
        }
    }

    It 'has match keys equal to platforms' {
        foreach ($rule in $script:Rules) {
            $matchKeys = @($rule.match.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
            $platKeys = @($rule.platforms | Sort-Object)
            ($matchKeys -join ',') | Should -Be ($platKeys -join ',')
        }
    }

    It 'uses only allowed platforms without repeats' {
        $allowed = @('windows', 'macos', 'linux')
        foreach ($rule in $script:Rules) {
            $rule.platforms.Count | Should -BeGreaterThan 0
            $unique = @($rule.platforms | Select-Object -Unique)
            $unique.Count | Should -Be $rule.platforms.Count
            foreach ($platform in $rule.platforms) {
                ($allowed -contains $platform) | Should -BeTrue
            }
        }
    }

    It 'uses tool actions with a plain command name and an args array' {
        $toolRules = @($script:Rules | Where-Object { $null -ne $_.action -and $_.action.type -eq 'tool' })
        $toolRules.Count | Should -BeGreaterThan 0
        foreach ($rule in $toolRules) {
            ($rule.action.command -match '^[A-Za-z0-9._-]+$') | Should -BeTrue
            $null -ne $rule.action.args | Should -BeTrue
            $rule.action.args.Count | Should -BeGreaterThan 0
        }
    }

    It 'uses delete-files actions with include, recurse, minSizeMB and olderThanDays' {
        $deleteRules = @($script:Rules | Where-Object { $null -ne $_.action -and $_.action.type -eq 'delete-files' })
        $deleteRules.Count | Should -BeGreaterThan 0
        foreach ($rule in $deleteRules) {
            $action = $rule.action
            $null -ne $action.include | Should -BeTrue
            $action.include.Count | Should -BeGreaterThan 0
            ($action.recurse -is [bool]) | Should -BeTrue
            ($action.minSizeMB -ge 0) | Should -BeTrue
            ($action.olderThanDays -ge 0) | Should -BeTrue
        }
    }

    It 'allows duplicate removal only on database-backups' {
        foreach ($rule in $script:Rules) {
            $hasFlag = ($null -ne $rule.PSObject.Properties['allowDuplicateRemoval']) -and ($null -ne $rule.allowDuplicateRemoval)
            if ($rule.id -eq 'database-backups') {
                $hasFlag | Should -BeTrue
                $rule.allowDuplicateRemoval | Should -BeTrue
            } else {
                $hasFlag | Should -BeFalse
            }
        }
    }

    It 'starts every windows entry with a token or a name pattern' {
        foreach ($rule in $script:Rules) {
            if ($null -ne $rule.match.PSObject.Properties['windows']) {
                foreach ($entry in $rule.match.windows) {
                    ($entry -match '^(\${|\*\*/)') | Should -BeTrue
                }
            }
        }
    }

    It 'has no user names, home paths, drive letters, tildes, backslashes or parent segments in entries' {
        $forbiddenPattern = '(^[A-Za-z]:)|~|\\|\.\.|/Users/|/home/'
        foreach ($rule in $script:Rules) {
            foreach ($prop in $rule.match.PSObject.Properties) {
                foreach ($entry in $prop.Value) {
                    ($entry -match $forbiddenPattern) | Should -BeFalse
                }
            }
        }
    }

    It 'uses name patterns only in critical rules' {
        foreach ($rule in $script:Rules) {
            foreach ($prop in $rule.match.PSObject.Properties) {
                foreach ($entry in $prop.Value) {
                    if ($entry -match '^\*\*/') {
                        $rule.tier | Should -Be 'critical'
                    }
                }
            }
        }
    }

    It 'uses absolute unix paths only in macos and linux arrays' {
        $unixPlatforms = @('macos', 'linux')
        foreach ($rule in $script:Rules) {
            foreach ($prop in $rule.match.PSObject.Properties) {
                foreach ($entry in $prop.Value) {
                    if ($entry -match '^/') {
                        ($unixPlatforms -contains $prop.Name) | Should -BeTrue
                    }
                }
            }
        }
    }

    It 'keeps description within 80 and reason within 200 characters' {
        foreach ($rule in $script:Rules) {
            ($rule.description.Length -ge 1) | Should -BeTrue
            ($rule.description.Length -le 80) | Should -BeTrue
            ($rule.reason.Length -ge 1) | Should -BeTrue
            ($rule.reason.Length -le 200) | Should -BeTrue
        }
    }

    It 'contains no em dash or en dash' {
        ($script:Raw.IndexOf([char]0x2014) -lt 0) | Should -BeTrue
        ($script:Raw.IndexOf([char]0x2013) -lt 0) | Should -BeTrue
    }
}
