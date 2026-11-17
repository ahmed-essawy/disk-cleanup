function Get-RepoRoot {
    Split-Path -Parent $PSScriptRoot
}

function Assert-SandboxPath {
    param([string]$Path)
    $base = [System.IO.Path]::GetFullPath((Join-Path (Get-RepoRoot) 'tests\.sandbox')) + '\'
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Sandbox path outside tests/.sandbox: $Path"
    }
}

function Initialize-TestSandbox {
    $name = -join ((1..8) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    $root = Join-Path (Get-RepoRoot) "tests\.sandbox\$name"
    Assert-SandboxPath $root
    $homeDir = Join-Path $root 'home'
    $localDir = Join-Path $root 'home\AppData\Local'
    $roamingDir = Join-Path $root 'home\AppData\Roaming'
    $tempDir = Join-Path $root 'home\AppData\Local\Temp'
    $programDataDir = Join-Path $root 'ProgramData'
    $binDir = Join-Path $root 'bin'
    $outDir = Join-Path $root 'out'
    [System.IO.Directory]::CreateDirectory($homeDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($localDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($roamingDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($tempDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($programDataDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($binDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($outDir) | Out-Null
    $saved = @{}
    $varNames = @(
        'USERPROFILE',
        'HOME',
        'TEMP',
        'TMP',
        'LOCALAPPDATA',
        'APPDATA',
        'ProgramData',
        'OneDrive',
        'OneDriveCommercial',
        'PATH',
        'DISK_CLEANUP_FORCE_NOT_ELEVATED',
        'DISK_CLEANUP_STUB_LOG'
    )
    foreach ($varName in $varNames) {
        $saved[$varName] = [Environment]::GetEnvironmentVariable($varName, 'Process')
    }
    [Environment]::SetEnvironmentVariable('USERPROFILE', $homeDir, 'Process')
    [Environment]::SetEnvironmentVariable('HOME', $homeDir, 'Process')
    [Environment]::SetEnvironmentVariable('TEMP', $tempDir, 'Process')
    [Environment]::SetEnvironmentVariable('TMP', $tempDir, 'Process')
    [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $localDir, 'Process')
    [Environment]::SetEnvironmentVariable('APPDATA', $roamingDir, 'Process')
    [Environment]::SetEnvironmentVariable('ProgramData', $programDataDir, 'Process')
    [Environment]::SetEnvironmentVariable('OneDrive', $null, 'Process')
    [Environment]::SetEnvironmentVariable('OneDriveCommercial', $null, 'Process')
    $savedPath = $saved['PATH']
    [Environment]::SetEnvironmentVariable('PATH', "$binDir;$savedPath", 'Process')
    [Environment]::SetEnvironmentVariable('DISK_CLEANUP_FORCE_NOT_ELEVATED', '1', 'Process')
    $stubLog = Join-Path $root 'stub.log'
    [Environment]::SetEnvironmentVariable('DISK_CLEANUP_STUB_LOG', $stubLog, 'Process')
    $sandbox = [pscustomobject]@{
        Root = [System.IO.Path]::GetFullPath($root)
        Home = [System.IO.Path]::GetFullPath($homeDir)
        Local = [System.IO.Path]::GetFullPath($localDir)
        Roaming = [System.IO.Path]::GetFullPath($roamingDir)
        Temp = [System.IO.Path]::GetFullPath($tempDir)
        ProgramData = [System.IO.Path]::GetFullPath($programDataDir)
        Bin = [System.IO.Path]::GetFullPath($binDir)
        Out = [System.IO.Path]::GetFullPath($outDir)
        StubLog = [System.IO.Path]::GetFullPath($stubLog)
        Saved = $saved
    }
    Add-ToolStubs -Sandbox $sandbox
    return $sandbox
}

function Restore-TestSandbox {
    param([object]$Sandbox)
    foreach ($key in $Sandbox.Saved.Keys) {
        [Environment]::SetEnvironmentVariable($key, $Sandbox.Saved[$key], 'Process')
    }
    Assert-SandboxPath $Sandbox.Root
    if (Test-Path -LiteralPath $Sandbox.Root) {
        Remove-Item -LiteralPath $Sandbox.Root -Recurse -Force
    }
}

function Add-ToolStubs {
    param([object]$Sandbox)
    $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
    $rulesJson = Get-Content -LiteralPath $rulesPath -Raw | ConvertFrom-Json
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $rulesJson.rules) {
        if ($null -ne $r.action -and $null -ne $r.action.command) {
            $names.Add([string]$r.action.command)
        }
        if ($null -ne $r.before) {
            foreach ($b in $r.before) {
                if ($null -ne $b.command) {
                    $names.Add([string]$b.command)
                }
            }
        }
    }
    $names.Add('sudo')
    $names.Add('wsl')
    $names.Add('diskpart')
    $names.Add('runas')
    $uniqueNames = @($names | Select-Object -Unique)
    $stubContent = "@echo %~n0 %*>>`"%DISK_CLEANUP_STUB_LOG%`"`r`n@exit /b 0`r`n"
    foreach ($cmdName in $uniqueNames) {
        $stubPath = Join-Path $Sandbox.Bin "$cmdName.cmd"
        [System.IO.File]::WriteAllText($stubPath, $stubContent, [System.Text.Encoding]::ASCII)
    }
}

function Add-FailingStub {
    param(
        [object]$Sandbox,
        [string]$Name
    )
    $stubPath = Join-Path $Sandbox.Bin "$Name.cmd"
    $stubContent = "@echo %~n0 %*>>`"%DISK_CLEANUP_STUB_LOG%`"`r`n@exit /b 1`r`n"
    [System.IO.File]::WriteAllText($stubPath, $stubContent, [System.Text.Encoding]::ASCII)
}

function Add-SandboxFile {
    param(
        [string]$Path,
        [int64]$Bytes,
        [datetime]$LastWriteUtc
    )
    Assert-SandboxPath $Path
    if ($Bytes -gt 2097152) {
        throw "Add-SandboxFile supports at most 2097152 bytes"
    }
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrEmpty($parent) -and -not (Test-Path -LiteralPath $parent)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
    if ($PSBoundParameters.ContainsKey('LastWriteUtc')) {
        [System.IO.File]::SetLastWriteTimeUtc($Path, $LastWriteUtc)
    }
    return $Path
}

function Get-TreeSnapshot {
    param([object]$Sandbox)
    $lines = [System.Collections.Generic.List[string]]::new()
    $rootFull = [System.IO.Path]::GetFullPath($Sandbox.Root).TrimEnd('\')
    $rootLength = $rootFull.Length
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($rootFull)
    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()
        $dirInfo = New-Object System.IO.DirectoryInfo $dir
        $items = $dirInfo.GetFileSystemInfos()
        foreach ($item in $items) {
            $rel = $item.FullName.Substring($rootLength + 1)
            if ($rel -eq 'out' -or $rel.StartsWith("out\", [System.StringComparison]::OrdinalIgnoreCase) -or $rel -eq 'stub.log') {
                continue
            }
            $isDir = ($item.Attributes -band [System.IO.FileAttributes]::Directory) -eq [System.IO.FileAttributes]::Directory
            if ($isDir) {
                $lines.Add("$rel|0|$($item.LastWriteTimeUtc.Ticks)")
                $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
                if (-not $isReparse) {
                    $queue.Enqueue($item.FullName)
                }
            } else {
                $lines.Add("$rel|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)")
            }
        }
    }
    $arr = [string[]]$lines.ToArray()
    [Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return $arr
}

function Get-StubCalls {
    param([object]$Sandbox)
    if (-not (Test-Path -LiteralPath $Sandbox.StubLog)) {
        return [string[]]@()
    }
    $lines = @(Get-Content -LiteralPath $Sandbox.StubLog | ForEach-Object { $_.Trim() })
    return [string[]]$lines
}

function ConvertTo-ProcessArgument {
    param([string]$Value)
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-DiskCleanupScript {
    param(
        [string]$Name,
        [string[]]$Arguments
    )
    $script = Join-Path (Get-RepoRoot) "skills\disk-cleanup\scripts\$Name"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $argParts = [System.Collections.Generic.List[string]]::new()
    $argParts.Add('-NoProfile')
    $argParts.Add('-ExecutionPolicy')
    $argParts.Add('Bypass')
    $argParts.Add('-File')
    $argParts.Add((ConvertTo-ProcessArgument $script))
    if ($null -ne $Arguments) {
        foreach ($arg in $Arguments) {
            $argParts.Add((ConvertTo-ProcessArgument $arg))
        }
    }
    $psi.Arguments = $argParts -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut = $outTask.Result
        StdErr = $errTask.Result
    }
}

function Write-FixtureRules {
    param(
        [object]$Sandbox,
        [scriptblock]$Transform
    )
    $rulesPath = Join-Path (Get-RepoRoot) 'skills\disk-cleanup\rules\rules.json'
    $raw = Get-Content -LiteralPath $rulesPath -Raw
    $data = $raw | ConvertFrom-Json
    & $Transform $data
    $path = Join-Path $Sandbox.Root 'rules.json'
    $json = ConvertTo-Json -InputObject $data -Depth 8
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))
    return $path
}
