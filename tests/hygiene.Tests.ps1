Describe 'repository hygiene' {
    BeforeAll {
        $script:Root = Split-Path -Parent $PSScriptRoot
        $script:Files = @(git -C $script:Root ls-files -co --exclude-standard | Where-Object { $_ -notlike 'tests/.sandbox/*' })
        $script:Author = (Get-Content -LiteralPath (Join-Path $script:Root '.claude-plugin/plugin.json') -Raw | ConvertFrom-Json).author.name
        $script:Manifests = @('.claude-plugin/plugin.json', '.claude-plugin/marketplace.json')
        $script:CommentExtensions = @('.ps1', '.psd1', '.sh', '.bash', '.bats', '.yml', '.yaml')
        $script:MarkupExtensions = @('.md', '.html')
        $script:UserPathPatterns = @('[A-Za-z]:\\Users\\[A-Za-z]','[A-Za-z]:/Users/[A-Za-z]', '(?<!})/Users/[A-Za-z]', '(?<!})/home/[A-Za-z]')

        function Get-RepoText {
            param([string]$RelativePath)
            [System.IO.File]::ReadAllText((Join-Path $script:Root $RelativePath), [System.Text.Encoding]::UTF8)
        }

        function Get-FilesMatching {
            param([string[]]$Paths, [scriptblock]$Predicate)
            @($Paths | Where-Object { & $Predicate (Get-RepoText $_) })
        }

        function Get-FilesWithExtension {
            param([string[]]$Extensions)
            @($script:Files | Where-Object { $Extensions -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant() })
        }
    }

    It 'finds repository files' {
        $script:Files.Count | Should -BeGreaterThan 20
    }

    It 'has no em dash or en dash in any file' {
        $emDash = [string][char]0x2014
        $enDash = [string][char]0x2013
        $found = Get-FilesMatching $script:Files { param($text) $text.Contains($emDash) -or $text.Contains($enDash) }
        $found | Should -BeNullOrEmpty -Because ("these files contain a dash character: " + ($found -join ', '))
    }

    It 'has no AI attribution lines' {
        $botAddress = 'noreply' + '@' + 'anthropic.com'
        $patterns = @('Co-Authored-By', 'Generated with', [regex]::Escape($botAddress))
        $paths = @($script:Files | Where-Object { $_ -ne 'tests/hygiene.Tests.ps1' })
        $found = Get-FilesMatching $paths {
            param($text)
            @($patterns | Where-Object { $text -match ('(?i)' + $_) }).Count -gt 0
        }
        $found | Should -BeNullOrEmpty -Because ("these files hold AI attribution: " + ($found -join ', '))
    }

    It 'has no absolute user paths' {
        $patterns = @('[A-Za-z]:\\Users\\[A-Za-z]', '(?<![A-Za-z0-9_}")])/Users/[a-z]', '(?<![A-Za-z0-9_}")])/home/[a-z]')
        $found = Get-FilesMatching $script:Files {
            param($text)
            @($patterns | Where-Object { $text -match $_ }).Count -gt 0
        }
        $found | Should -BeNullOrEmpty -Because ("these files hold an absolute user path: " + ($found -join ', '))
    }

    It 'matches user paths and ignores variable based paths' {
        $slash = [string][char]47
        $users = $slash + 'Users' + $slash
        $positives = @(('"' + $users + 'Alice/x"'), ('C:' + $users + 'x/y'), ('/' + 'home/bob/x'))
        foreach ($sample in $positives) {
            @($script:UserPathPatterns | Where-Object { $sample -match $_ }).Count | Should -BeGreaterThan 0 -Because $sample
        }
        $negative = '${SANDBOX}' + $slash + 'home' + $slash + 'tmp'
        @($script:UserPathPatterns | Where-Object { $negative -match $_ }).Count | Should -Be 0
    }

    It 'has email addresses only in the plugin manifests' {
        $paths = @($script:Files | Where-Object { $script:Manifests -notcontains $_ })
        $found = Get-FilesMatching $paths { param($text) $text -match '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' }
        $found | Should -BeNullOrEmpty -Because ("these files hold an email address: " + ($found -join ', '))
    }

    It 'has the author name only in LICENSE and the plugin manifests' {
        $allowed = @('LICENSE') + $script:Manifests
        $paths = @($script:Files | Where-Object { $allowed -notcontains $_ })
        $found = Get-FilesMatching $paths { param($text) $text.Contains($script:Author) }
        $found | Should -BeNullOrEmpty -Because ("these files hold the author name: " + ($found -join ', '))
    }

    It 'has no comment lines in scripts, configs and workflows' {
        $offending = foreach ($path in Get-FilesWithExtension $script:CommentExtensions) {
            $lines = (Get-RepoText $path) -split "`r?`n"
            for ($index = 0; $index -lt $lines.Count; $index++) {
                $isShebang = $index -eq 0 -and $lines[$index].StartsWith('#!')
                if (-not $isShebang -and $lines[$index] -match '^\s*(#|<#)') {
                    '{0}:{1}' -f $path, ($index + 1)
                }
            }
        }
        $offending | Should -BeNullOrEmpty -Because ("comment lines found at: " + (@($offending) -join ', '))
    }

    It 'expands bash arrays only in the form safe for an empty array on bash 3.2' {
        $safeForm = '\$\{(\w+)\[@\]\+"\$\{\1\[@\]\}"\}'
        $bareForm = '\$\{\w+\[[@*]\]\}'
        $offending = foreach ($path in Get-FilesWithExtension @('.sh', '.bash', '.bats')) {
            $lines = (Get-RepoText $path) -split "`r?`n"
            for ($index = 0; $index -lt $lines.Count; $index++) {
                if (([regex]::Replace($lines[$index], $safeForm, '')) -match $bareForm) {
                    '{0}:{1}' -f $path, ($index + 1)
                }
            }
        }
        $offending | Should -BeNullOrEmpty -Because ("unsafe empty array expansion at: " + (@($offending) -join ', '))
    }

    It 'has no HTML comments in markdown and html files' {
        $found = Get-FilesMatching (Get-FilesWithExtension $script:MarkupExtensions) { param($text) $text.Contains('<!--') }
        $found | Should -BeNullOrEmpty -Because ("these files hold an HTML comment: " + ($found -join ', '))
    }

    It 'tracks no AI tool or planning files' {
        $pattern = '(?i)^(\.specify|specs|\.claude|\.superpowers|\.agents?|\.antigravity|\.gemini|\.codex|\.cursor|\.windsurf|\.devin|\.cline|\.clinerules|\.opencode)/|^\.github/(copilot-instructions\.md|instructions/|skills/)|(^|/)(CLAUDE(\.local)?|AGENTS(\.override)?|GEMINI)\.md$'
        $found = @($script:Files | Where-Object { $_ -match $pattern })
        $found | Should -BeNullOrEmpty -Because ("these AI tool or planning paths are tracked: " + ($found -join ', '))
    }

    It 'ignores AI tool and planning paths in .gitignore' {
        $lines = @(git -C $script:Root check-ignore -v --no-index '.specify/x' 'specs/x' '.claude/x' '.superpowers/x' '.cursor/x' '.windsurf/x' '.codex/x' '.gemini/x' '.agents/x' '.antigravity/x' 'CLAUDE.md' 'AGENTS.md' 'GEMINI.md')
        $lines.Count | Should -Be 13
        @($lines | Where-Object { -not $_.StartsWith('.gitignore:') }) | Should -BeNullOrEmpty
        git -C $script:Root check-ignore -q --no-index '.claude-plugin/plugin.json'
        $LASTEXITCODE | Should -Be 1
    }
}
