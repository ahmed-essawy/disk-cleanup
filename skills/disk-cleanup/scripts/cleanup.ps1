[CmdletBinding()]
param(
    [string[]]$Ids,
    [switch]$DryRun,
    [string]$LogPath,
    [string]$ScanPath = "$env:LOCALAPPDATA\diskscan\scan.json",
    [string]$RulesPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($RulesPath)) {
    $RulesPath = Join-Path $PSScriptRoot '..\rules\rules.json'
}
. (Join-Path $PSScriptRoot 'common.ps1')

function Get-RequestedIds {
    param([string[]]$Ids)
    return @($Ids | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
}

function Resolve-LogPath {
    param(
        [string]$LogPath,
        [string]$ScanPath
    )
    $scanParent = Split-Path -Parent $ScanPath
    if ([string]::IsNullOrEmpty($scanParent)) {
        $scanParent = (Get-Location).Path
    }
    $defaultLog = Join-Path $scanParent 'cleanup.log'
    $chosen = $defaultLog
    if (-not [string]::IsNullOrEmpty($LogPath)) {
        if (Test-IsTempPath -Path $LogPath) {
            [Console]::Error.WriteLine("Log path refused (inside Temp), using $defaultLog")
            $chosen = $defaultLog
        } else {
            $chosen = $LogPath
        }
    }
    if (Test-IsTempPath -Path $chosen) {
        [Console]::Error.WriteLine("No usable log path: $chosen")
        exit 3
    }
    $parentDir = Split-Path -Parent $chosen
    if (-not [string]::IsNullOrEmpty($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
        try {
            $null = [System.IO.Directory]::CreateDirectory($parentDir)
        } catch {
            [Console]::Error.WriteLine("No usable log path: $chosen")
            exit 3
        }
    }
    return $chosen
}

function Write-LogLine {
    param(
        [string]$Path,
        [string]$Id,
        [string]$Action,
        [string]$Result,
        [int64]$FreeBefore,
        [int64]$FreeAfter,
        [string]$Detail
    )
    $ts = Format-UtcTimestamp (Get-Date)
    $cleanDetail = if ($null -ne $Detail) { $Detail -replace "[`t`r`n]", ' ' } else { '' }
    $cols = @($ts, $Id, $Action, $Result, [string]$FreeBefore, [string]$FreeAfter, $cleanDetail)
    $line = $cols -join "`t"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::AppendAllText($Path, $line + "`r`n", $utf8NoBom)
}

function Get-StepDecision {
    param(
        [string]$Id,
        [object]$Rule,
        [object]$Context
    )
    $null = $Id
    if ($null -eq $Rule) {
        return [pscustomobject]@{
            Result = 'refused'
            Detail = 'unknown id'
            Bytes = [int64]0
            RefusedPaths = @()
        }
    }
    if ($Rule.tier -eq 'critical') {
        return [pscustomobject]@{
            Result = 'refused'
            Detail = 'critical'
            Bytes = [int64]0
            RefusedPaths = @()
        }
    }
    if ($null -eq $Rule.action) {
        return [pscustomobject]@{
            Result = 'refused'
            Detail = 'no action'
            Bytes = [int64]0
            RefusedPaths = @()
        }
    }
    if ($null -eq $Rule.platforms -or ($Rule.platforms -notcontains $Context.Platform)) {
        return [pscustomobject]@{
            Result = 'not-applicable'
            Detail = 'other OS'
            Bytes = [int64]0
            RefusedPaths = @()
        }
    }
    if ($Rule.needsAdmin -and (-not (Test-IsElevated))) {
        return [pscustomobject]@{
            Result = 'skipped'
            Detail = 'needs admin: rerun from a terminal started with "Run as administrator"'
            Bytes = [int64]0
            RefusedPaths = @()
        }
    }
    if ($Rule.action.type -eq 'tool') {
        $cmd = Get-Command $Rule.action.command -CommandType Application -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            return [pscustomobject]@{
                Result = 'not-applicable'
                Detail = "tool not found: $($Rule.action.command)"
                Bytes = [int64]0
                RefusedPaths = @()
            }
        }
    }
    if ($Rule.action.type -eq 'tool' -and -not [string]::IsNullOrEmpty($Context.Target)) {
        if (-not (Test-ToolRuleInScope -Rule $Rule -Platform $Context.Platform -Target $Context.Target)) {
            return [pscustomobject]@{
                Result = 'not-applicable'
                Detail = 'nothing matched'
                Bytes = [int64]0
                RefusedPaths = @()
            }
        }
    }
    if ($Rule.action.type -eq 'dedupe') {
        if ($null -eq $Context.Duplicates) {
            return [pscustomobject]@{
                Result = 'not-applicable'
                Detail = 'no scan.json'
                Bytes = [int64]0
                RefusedPaths = @()
            }
        }
    }
    return $null
}

function Invoke-BeforeCommands {
    param([object]$Rule)
    $ErrorActionPreference = 'Continue'
    if ($null -eq $Rule.before) {
        return
    }
    foreach ($item in $Rule.before) {
        if ([string]::IsNullOrEmpty($item.command)) {
            continue
        }
        $cmd = Get-Command $item.command -CommandType Application -ErrorAction SilentlyContinue
        if ($null -ne $cmd) {
            [string[]]$argsToPass = $item.args
            try {
                $null = & $item.command @argsToPass 2>&1
            } catch {
                $null = $_
            }
        }
    }
}

function Invoke-ToolAction {
    param(
        [object]$Rule,
        [object]$Context
    )
    if ($Context.DryRun) {
        $paths = @(Get-RulePaths -Rule $Rule -Platform $Context.Platform -Target $Context.Target)
        [int64]$sum = 0
        foreach ($p in $paths) {
            $fb = Get-FolderBytes -Path $p -NullDir $Context.NullDir -CriticalSet $Context.CriticalSet
            $sum += [int64]$fb.Bytes
        }
        return [pscustomobject]@{
            Result = 'dry-run'
            Detail = "would free $sum bytes"
            Bytes = $sum
            RefusedPaths = @()
        }
    }
    $ErrorActionPreference = 'Continue'
    [string[]]$argsToPass = $Rule.action.args
    try {
        $null = & $Rule.action.command @argsToPass 2>&1
        $code = $LASTEXITCODE
        if ($null -eq $code -or $code -eq 0) {
            return [pscustomobject]@{
                Result = 'done'
                Detail = 'exit 0'
                Bytes = [int64]0
                RefusedPaths = @()
            }
        } else {
            return [pscustomobject]@{
                Result = 'failed'
                Detail = "exit $code"
                Bytes = [int64]0
                RefusedPaths = @()
            }
        }
    } catch {
        return [pscustomobject]@{
            Result = 'failed'
            Detail = 'exit 1'
            Bytes = [int64]0
            RefusedPaths = @()
        }
    }
}

function Invoke-SafeDelete {
    param([string]$Path)
    try {
        [System.IO.File]::Delete($Path)
        return $true
    } catch {
        return $false
    }
}

function Clear-EmptyDirectory {
    param(
        [string]$Root,
        [object]$CriticalSet
    )
    if (-not [System.IO.Directory]::Exists($Root)) {
        return
    }
    try {
        $subDirs = [System.IO.Directory]::EnumerateDirectories($Root)
        foreach ($d in $subDirs) {
            try {
                $attr = [System.IO.File]::GetAttributes($d)
                if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) {
                    continue
                }
            } catch {
                continue
            }
            if ($null -ne $CriticalSet -and (Test-CriticalPath -Path $d -CriticalSet $CriticalSet)) {
                continue
            }
            Clear-EmptyDirectory -Root $d -CriticalSet $CriticalSet
            try {
                [System.IO.Directory]::Delete($d, $false)
            } catch {
                $null = $_
            }
        }
    } catch {
        $null = $_
    }
}

function Clear-EmptiedParents {
    param(
        [string]$FilePath,
        [string]$Root,
        [object]$CriticalSet
    )
    $normRoot = ConvertTo-NormalizedPath -Path $Root
    $dir = [System.IO.Path]::GetDirectoryName($FilePath)
    while (-not [string]::IsNullOrEmpty($dir) -and (Test-PathUnder -Path $dir -Parent $normRoot) -and -not [string]::Equals((ConvertTo-NormalizedPath -Path $dir), $normRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ([System.IO.Directory]::Exists($dir)) {
            if ((Test-ReparsePoint -Path $dir) -or (Test-CriticalPath -Path $dir -CriticalSet $CriticalSet)) {
                return
            }
            try {
                [System.IO.Directory]::Delete($dir, $false)
            } catch {
                return
            }
        }
        $dir = [System.IO.Path]::GetDirectoryName($dir)
    }
}

function Test-ReparsePoint {
    param([string]$Path)
    return ([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
}

function Test-LinkedAncestor {
    param(
        [string]$Path,
        [string]$HomePath
    )
    if ([string]::IsNullOrEmpty($HomePath) -or -not (Test-PathUnder -Path $Path -Parent $HomePath)) {
        return $false
    }
    $normHome = ConvertTo-NormalizedPath -Path $HomePath
    $dir = [System.IO.Path]::GetDirectoryName((ConvertTo-NormalizedPath -Path $Path))
    while (-not [string]::IsNullOrEmpty($dir) -and -not [string]::Equals($dir.TrimEnd('\'), $normHome.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        if ((Test-Path -LiteralPath $dir) -and (Test-ReparsePoint -Path $dir)) {
            return $true
        }
        $dir = [System.IO.Path]::GetDirectoryName($dir)
    }
    return $false
}

function Test-RefusedRoot {
    param(
        [string]$Path,
        [object]$Context
    )
    return ((Test-ReparsePoint -Path $Path) -or (Test-LinkedAncestor -Path $Path -HomePath $Context.Home) -or (Test-ProtectedTarget -Path $Path -CriticalSet $Context.CriticalSet))
}

function Test-IncludeMatch {
    param(
        [string]$Name,
        [string[]]$Include
    )
    foreach ($pattern in $Include) {
        if ($pattern -eq '*.*' -or $Name -like $pattern) {
            return $true
        }
    }
    return $false
}

function Test-ListedFile {
    param(
        [string]$Path,
        [string]$Root,
        [string[]]$Include,
        [int64]$MinBytes,
        [int]$MinAgeDays
    )
    try {
        if (-not [System.IO.File]::Exists($Path) -or (Test-ReparsePoint -Path $Path)) {
            return $false
        }
    } catch {
        return $false
    }
    if (-not (Test-PathUnder -Path $Path -Parent $Root)) {
        return $false
    }
    if (-not (Test-IncludeMatch -Name ([System.IO.Path]::GetFileName($Path)) -Include $Include)) {
        return $false
    }
    $info = New-Object System.IO.FileInfo $Path
    if ($info.Length -lt $MinBytes) {
        return $false
    }
    return ($MinAgeDays -le 0) -or ($info.LastWriteTimeUtc -le [datetime]::UtcNow.AddDays(-$MinAgeDays))
}

function Test-AsciiText {
    param([string]$Text)
    return -not ($Text -cmatch '[^\u0000-\u007F]')
}

function Invoke-FileDeletion {
    param(
        [object]$Rule,
        [object]$Context,
        [string[]]$Include,
        [switch]$Recurse,
        [int64]$MinBytes = 0,
        [int]$MinAgeDays = 0
    )
    $paths = @(Get-RulePaths -Rule $Rule -Platform $Context.Platform -Target $Context.Target)
    if ($paths.Count -eq 0) {
        return [pscustomobject]@{
            Result = 'not-applicable'
            Detail = 'nothing matched'
            Bytes = [int64]0
            RefusedPaths = @()
        }
    }
    $refusedPaths = [System.Collections.Generic.List[string]]::new()
    $validPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $paths) {
        if (Test-RefusedRoot -Path $p -Context $Context) {
            $refusedPaths.Add($p)
        } else {
            $validPaths.Add($p)
        }
    }
    if ($validPaths.Count -eq 0) {
        return [pscustomobject]@{
            Result = 'refused'
            Detail = "protected path $($refusedPaths[0])"
            Bytes = [int64]0
            RefusedPaths = @($refusedPaths)
        }
    }
    if (-not $Context.DryRun) {
        Invoke-BeforeCommands -Rule $Rule
    }

    [int64]$totalBytes = 0
    $allFiles = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $validPaths) {
        $listing = Get-FileListing -Root $p -NullDir $Context.NullDir -CriticalSet $Context.CriticalSet -Include $Include -Recurse:$Recurse -MinBytes $MinBytes -MinAgeDays $MinAgeDays -ExcludeTempFolders
        foreach ($f in $listing.Files) {
            $allFiles.Add([pscustomobject]@{ Path = $f.Path; Bytes = $f.Bytes; Root = $p })
            $totalBytes += [int64]$f.Bytes
        }
    }

    if ($Context.DryRun) {
        return [pscustomobject]@{
            Result = 'dry-run'
            Detail = "would free $totalBytes bytes"
            Bytes = $totalBytes
            RefusedPaths = @($refusedPaths)
        }
    }

    $deletedCount = 0
    [int64]$deletedBytes = 0
    $skippedCount = 0
    $deletedFiles = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $allFiles) {
        $isGuarded = (Test-CriticalPath -Path $f.Path -CriticalSet $Context.CriticalSet) -or (Test-ProtectedTarget -Path $f.Path -CriticalSet $Context.CriticalSet)
        $qualifies = Test-ListedFile -Path $f.Path -Root $f.Root -Include $Include -MinBytes $MinBytes -MinAgeDays $MinAgeDays
        if (-not $isGuarded -and $qualifies -and (Invoke-SafeDelete -Path $f.Path)) {
            $deletedCount++
            $deletedBytes += [int64]$f.Bytes
            $deletedFiles.Add($f)
        } else {
            $skippedCount++
        }
    }

    foreach ($f in $deletedFiles) {
        Clear-EmptiedParents -FilePath $f.Path -Root $f.Root -CriticalSet $Context.CriticalSet
    }

    $resultStatus = if ($skippedCount -gt 0) { 'partial' } else { 'done' }
    return [pscustomobject]@{
        Result = $resultStatus
        Detail = "deleted $deletedCount files, $deletedBytes bytes, skipped $skippedCount"
        Bytes = $deletedBytes
        RefusedPaths = @($refusedPaths)
    }
}

function Get-ActionResult {
    param(
        [string]$Result,
        [string]$Detail,
        [int64]$Bytes = 0,
        [string[]]$RefusedPaths = @()
    )
    return [pscustomobject]@{
        Result = $Result
        Detail = $Detail
        Bytes = $Bytes
        RefusedPaths = @($RefusedPaths)
    }
}

function Invoke-GuardedDelete {
    param(
        [string]$Path,
        [object]$CriticalSet
    )
    if ((Test-CriticalPath -Path $Path -CriticalSet $CriticalSet) -or (Test-ProtectedTarget -Path $Path -CriticalSet $CriticalSet)) {
        return $false
    }
    return (Invoke-SafeDelete -Path $Path)
}

function Get-DeletionOutcome {
    param(
        [int]$DeletedCount,
        [int64]$DeletedBytes,
        [int]$SkippedCount,
        [string[]]$RefusedPaths = @()
    )
    $status = if ($SkippedCount -gt 0) { 'partial' } else { 'done' }
    return (Get-ActionResult -Result $status -Detail "deleted $DeletedCount files, $DeletedBytes bytes, skipped $SkippedCount" -Bytes $DeletedBytes -RefusedPaths $RefusedPaths)
}

function Test-ScanMadeForHome {
    param(
        [string]$ScanHome,
        [string]$CurrentHome
    )
    if ([string]::IsNullOrEmpty($ScanHome)) {
        return $false
    }
    return [string]::Equals($ScanHome, $CurrentHome, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-DuplicateCopyUnchanged {
    param(
        [string]$Path,
        [object]$Group,
        [object]$Context
    )
    if (Test-ShortNamePath -Path $Path) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    if (Test-LinkedAncestor -Path $Path -HomePath $Context.Home) {
        return $false
    }
    if (-not (Test-PathUnder -Path $Path -Parent $Context.Target)) {
        return $false
    }
    if ((Get-Item -LiteralPath $Path -Force).Length -ne [int64]$Group.bytes) {
        return $false
    }
    try {
        return ((Get-FileSha256 $Path) -eq $Group.sha256)
    } catch {
        return $false
    }
}

function Invoke-DedupeAction {
    param(
        [object]$Rule,
        [object]$Context
    )
    $null = $Rule
    $unresolved = @($Context.ProtectedSet.Unresolved)
    if ($unresolved.Count -gt 0) {
        return (Get-ActionResult -Result 'refused' -Detail "unresolved critical path $($unresolved[0])")
    }
    if ([string]::IsNullOrEmpty($Context.Target) -or (Test-ShortNamePath -Path $Context.Target)) {
        return (Get-ActionResult -Result 'not-applicable' -Detail 'no scan target')
    }
    if (-not (Test-ScanMadeForHome -ScanHome $Context.ScanHome -CurrentHome $Context.Home)) {
        return (Get-ActionResult -Result 'refused' -Detail 'scan made for another home')
    }
    $matchedGroups = 0
    [int64]$wouldFree = 0
    $deletedCount = 0
    [int64]$deletedBytes = 0
    $skippedCount = 0
    foreach ($group in @($Context.Duplicates)) {
        $candidates = @(@($group.paths) | Where-Object { -not [string]::IsNullOrEmpty($_) })
        if ($candidates.Count -lt 2) {
            continue
        }
        $kept = @($candidates | Where-Object { Test-DuplicateCopyUnchanged -Path $_ -Group $group -Context $Context })
        if ($kept.Count -lt 2) {
            continue
        }
        $matchedGroups++
        $victims = @(Get-DedupeDeletions -Paths $kept -ProtectedSet $Context.ProtectedSet)
        if ($Context.DryRun) {
            $wouldFree += [int64]$group.bytes * $victims.Count
            continue
        }
        foreach ($v in $victims) {
            if (Invoke-GuardedDelete -Path $v -CriticalSet $Context.ProtectedSet) {
                $deletedCount++
                $deletedBytes += [int64]$group.bytes
            } else {
                $skippedCount++
            }
        }
    }
    if ($matchedGroups -eq 0) {
        return (Get-ActionResult -Result 'not-applicable' -Detail 'nothing matched')
    }
    if ($Context.DryRun) {
        return (Get-ActionResult -Result 'dry-run' -Detail "would free $wouldFree bytes" -Bytes $wouldFree)
    }
    return (Get-DeletionOutcome -DeletedCount $deletedCount -DeletedBytes $deletedBytes -SkippedCount $skippedCount)
}

function Test-DeletableVersionFolder {
    param(
        [string]$Directory,
        [string]$Root
    )
    try {
        return ([System.IO.Directory]::Exists($Directory) -and -not (Test-ReparsePoint -Path $Directory) -and (Test-PathUnder -Path $Directory -Parent $Root))
    } catch {
        return $false
    }
}

function Invoke-OldVersionFolderDeletion {
    param(
        [string]$Directory,
        [string]$Root,
        [object]$Context
    )
    if (-not (Test-DeletableVersionFolder -Directory $Directory -Root $Root)) {
        return [pscustomobject]@{
            Deleted = 0
            Bytes = [int64]0
            Skipped = 1
        }
    }
    $listing = Get-FileListing -Root $Directory -NullDir $Context.NullDir -CriticalSet $Context.CriticalSet -Recurse
    $deleted = 0
    [int64]$bytes = 0
    $skipped = 0
    foreach ($f in $listing.Files) {
        if (Invoke-GuardedDelete -Path $f.Path -CriticalSet $Context.CriticalSet) {
            $deleted++
            $bytes += [int64]$f.Bytes
        } else {
            $skipped++
        }
    }
    Clear-EmptyDirectory -Root $Directory -CriticalSet $Context.CriticalSet
    try {
        [System.IO.Directory]::Delete($Directory, $false)
    } catch {
        $skipped++
    }
    return [pscustomobject]@{
        Deleted = $deleted
        Bytes = $bytes
        Skipped = $skipped
    }
}

function Invoke-OldVersionsAction {
    param(
        [object]$Rule,
        [object]$Context
    )
    $paths = @(Get-RulePaths -Rule $Rule -Platform $Context.Platform -Target $Context.Target)
    if ($paths.Count -eq 0) {
        return (Get-ActionResult -Result 'not-applicable' -Detail 'nothing matched')
    }
    $refusedPaths = [System.Collections.Generic.List[string]]::new()
    [int64]$wouldFree = 0
    $deletedCount = 0
    [int64]$deletedBytes = 0
    $skippedCount = 0
    $beforeRan = $false
    foreach ($p in $paths) {
        if (Test-RefusedRoot -Path $p -Context $Context) {
            $refusedPaths.Add($p)
            continue
        }
        if (-not $beforeRan -and -not $Context.DryRun) {
            Invoke-BeforeCommands -Rule $Rule
            $beforeRan = $true
        }
        $dirs = @(Get-OldVersionFolders -Path $p | Where-Object { -not (Test-CriticalPath -Path $_ -CriticalSet $Context.CriticalSet) })
        foreach ($d in $dirs) {
            if ($Context.DryRun) {
                $wouldFree += [int64](Get-FolderBytes -Path $d -NullDir $Context.NullDir -CriticalSet $Context.CriticalSet).Bytes
                continue
            }
            $outcome = Invoke-OldVersionFolderDeletion -Directory $d -Root $p -Context $Context
            $deletedCount += $outcome.Deleted
            $deletedBytes += $outcome.Bytes
            $skippedCount += $outcome.Skipped
        }
    }
    if ($refusedPaths.Count -eq $paths.Count) {
        return (Get-ActionResult -Result 'refused' -Detail "protected path $($refusedPaths[0])" -RefusedPaths $refusedPaths)
    }
    if ($Context.DryRun) {
        return (Get-ActionResult -Result 'dry-run' -Detail "would free $wouldFree bytes" -Bytes $wouldFree -RefusedPaths $refusedPaths)
    }
    return (Get-DeletionOutcome -DeletedCount $deletedCount -DeletedBytes $deletedBytes -SkippedCount $skippedCount -RefusedPaths $refusedPaths)
}

function Get-DockerDesktopPath {
    $ErrorActionPreference = 'Continue'
    $process = Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $process) {
        return $null
    }
    return $process.Path
}

function Invoke-DockerDesktopLaunch {
    param([string]$Path)
    $ErrorActionPreference = 'Continue'
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $Path + '"')
}

function Invoke-DockerShutdown {
    $ErrorActionPreference = 'Continue'
    if ($null -ne (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        Stop-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue
    }
    $null = & wsl --shutdown 2>&1
    for ($i = 0; $i -lt 30; $i++) {
        if ($null -eq (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Write-DiskpartScript {
    param(
        [string]$Path,
        [string]$Disk
    )
    $lines = @("select vdisk file=""$Disk""", 'attach vdisk readonly', 'compact vdisk', 'detach vdisk', 'exit')
    $bytes = [System.Text.Encoding]::ASCII.GetBytes((($lines -join "`r`n") + "`r`n"))
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
}

function Invoke-DiskpartCompact {
    param(
        [string]$Disk,
        [string]$ScanFolder
    )
    $ErrorActionPreference = 'Continue'
    $scriptPath = Join-Path $ScanFolder 'diskpart-compact.txt'
    Write-DiskpartScript -Path $scriptPath -Disk $Disk
    try {
        $null = & diskpart /s $scriptPath 2>&1
        return [int]$LASTEXITCODE
    } finally {
        [System.IO.File]::Delete($scriptPath)
    }
}

function Invoke-CompactVhdxAction {
    param(
        [object]$Rule,
        [object]$Context
    )
    $disks = @(Get-RulePaths -Rule $Rule -Platform $Context.Platform -Target $Context.Target)
    if ($disks.Count -eq 0) {
        return (Get-ActionResult -Result 'not-applicable' -Detail 'nothing matched')
    }
    if ($Context.DryRun) {
        return (Get-ActionResult -Result 'dry-run' -Detail "would compact $($disks.Count) disks")
    }
    foreach ($disk in $disks) {
        if (-not (Test-AsciiText -Text $disk)) {
            return (Get-ActionResult -Result 'failed' -Detail "non-ASCII path not supported by diskpart: $disk")
        }
    }
    if ([string]::IsNullOrEmpty($Context.ScanFolder) -or -not [System.IO.Directory]::Exists($Context.ScanFolder)) {
        return (Get-ActionResult -Result 'failed' -Detail 'scan folder not found for the diskpart script')
    }
    $dockerPath = Get-DockerDesktopPath
    if (-not (Invoke-DockerShutdown)) {
        return (Get-ActionResult -Result 'failed' -Detail 'Docker Desktop still running')
    }
    try {
        foreach ($disk in $disks) {
            try {
                $code = Invoke-DiskpartCompact -Disk $disk -ScanFolder $Context.ScanFolder
            } catch [System.IO.IOException] {
                return (Get-ActionResult -Result 'failed' -Detail "diskpart script not created: $($_.Exception.Message)")
            }
            if ($code -ne 0) {
                return (Get-ActionResult -Result 'failed' -Detail "diskpart exit $code")
            }
        }
        return (Get-ActionResult -Result 'done' -Detail "compacted $($disks.Count) disks")
    } finally {
        if (-not [string]::IsNullOrEmpty($dockerPath)) {
            Invoke-DockerDesktopLaunch -Path $dockerPath
        }
    }
}

function Invoke-RuleAction {
    param(
        [object]$Rule,
        [object]$Context
    )
    $actionType = if ($Rule.action) { $Rule.action.type } else { '' }
    $beforeInAction = @('clear-dir', 'delete-files', 'old-versions')
    if (-not $Context.DryRun -and $actionType -notin $beforeInAction) {
        Invoke-BeforeCommands -Rule $Rule
    }
    switch ($actionType) {
        'tool' {
            return (Invoke-ToolAction -Rule $Rule -Context $Context)
        }
        'clear-dir' {
            return (Invoke-FileDeletion -Rule $Rule -Context $Context -Include @('*.*') -Recurse -MinBytes 0 -MinAgeDays 0)
        }
        'delete-files' {
            $a = $Rule.action
            $inc = if ($null -ne $a.include) { @($a.include) } else { @('*.*') }
            $rec = if ($a.recurse) { $true } else { $false }
            $minBytes = if ($a.minSizeMB) { [int64]$a.minSizeMB * [int64]1048576 } else { [int64]0 }
            $olderThan = if ($a.olderThanDays) { [int]$a.olderThanDays } else { 0 }
            return (Invoke-FileDeletion -Rule $Rule -Context $Context -Include $inc -Recurse:$rec -MinBytes $minBytes -MinAgeDays $olderThan)
        }
        'dedupe' {
            return (Invoke-DedupeAction -Rule $Rule -Context $Context)
        }
        'old-versions' {
            return (Invoke-OldVersionsAction -Rule $Rule -Context $Context)
        }
        'compact-docker-vhdx' {
            return (Invoke-CompactVhdxAction -Rule $Rule -Context $Context)
        }
        default {
            return [pscustomobject]@{
                Result = 'failed'
                Detail = "unsupported action $actionType"
                Bytes = [int64]0
                RefusedPaths = @()
            }
        }
    }
}

function Write-Summary {
    param(
        [object[]]$Steps,
        [bool]$DryRun,
        [int64]$FreeStart,
        [int64]$FreeEnd
    )
    if ($DryRun) {
        [int64]$drySum = 0
        foreach ($s in $Steps) {
            if ($s.Result -eq 'dry-run') {
                $drySum += [int64]$s.Bytes
            }
        }
        $formatted = Format-Gigabytes -Bytes $drySum
        [Console]::Out.WriteLine("Dry run: nothing deleted. Would free about $formatted GB.")
    } else {
        $startGb = Format-Gigabytes -Bytes $FreeStart
        $endGb = Format-Gigabytes -Bytes $FreeEnd
        [int64]$diff = $FreeEnd - $FreeStart
        if ($diff -lt 0) {
            $diff = 0
        }
        $freedGb = Format-Gigabytes -Bytes $diff
        [Console]::Out.WriteLine("Free space: $startGb GB -> $endGb GB (freed $freedGb GB)")
    }

    $adminSkipped = [System.Collections.Generic.List[string]]::new()
    $refusedList = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $Steps) {
        if ($s.Result -eq 'skipped' -and $s.Detail -match 'needs admin') {
            $adminSkipped.Add($s.Id)
        }
        if ($s.Result -eq 'refused') {
            $det = $s.Detail
            if ($det -like 'protected path*') {
                $det = 'protected path'
            }
            $refusedList.Add("$($s.Id) ($det)")
        }
    }
    if ($adminSkipped.Count -gt 0) {
        $joined = $adminSkipped -join ', '
        [Console]::Out.WriteLine("Skipped (needs admin): $joined. Rerun from a terminal started with ""Run as administrator"".")
    }
    if ($refusedList.Count -gt 0) {
        $joined = $refusedList -join ', '
        [Console]::Out.WriteLine("Refused: $joined")
    }
}

try {
    $platform = Get-CurrentPlatform
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

if (-not (Test-UserProfileCanonical)) {
    [Console]::Error.WriteLine("Invalid argument: USERPROFILE is not a canonical existing folder: $env:USERPROFILE")
    exit 2
}
if (-not [string]::IsNullOrEmpty($ScanPath)) {
    $scanParentPath = Split-Path -Parent $ScanPath
    $scanFolderTrusted = [string]::IsNullOrEmpty($scanParentPath) -or (Test-TrustedScanItem -Path $scanParentPath)
    if (-not ($scanFolderTrusted -and (Test-TrustedScanItem -Path $ScanPath))) {
        [Console]::Error.WriteLine("Scan folder refused: $scanParentPath or $ScanPath is a link or not owned by the current user")
        exit 3
    }
}
$actualLogPath = Resolve-LogPath -LogPath $LogPath -ScanPath $ScanPath

try {
    $allRules = Get-DiskCleanupRules -Path $RulesPath
} catch {
    [Console]::Error.WriteLine("Rules file invalid: $RulesPath")
    exit 4
}

$rulesForPlatform = @($allRules | Where-Object { $null -ne $_.platforms -and ($_.platforms -contains $platform) })

$requestedIds = @(Get-RequestedIds -Ids $Ids)
if ($requestedIds.Count -eq 0) {
    $DryRun = [switch]::new($true)
    $requestedIds = @($rulesForPlatform | Where-Object { $_.tier -eq 'safe' } | ForEach-Object { $_.id })
}

$scanTarget = $null
$scanDuplicates = $null
$scanHome = $null
if (-not [string]::IsNullOrEmpty($ScanPath) -and (Test-Path -LiteralPath $ScanPath -PathType Leaf)) {
    try {
        $scanJsonContent = Get-Content -LiteralPath $ScanPath -Raw -Encoding UTF8
        $parsedScan = ConvertFrom-Json $scanJsonContent
        $scanTarget = $parsedScan.target
        $scanDuplicates = $parsedScan.duplicates
        $scanHome = $parsedScan.home
    } catch {
        $null = $_
    }
}

$scanFolder = if (-not [string]::IsNullOrEmpty($ScanPath)) { Split-Path -Parent $ScanPath } else { '' }
$logFolder = Split-Path -Parent $actualLogPath
$nullDir = Join-Path $logFolder '.robocopy-null'
$scanFolderGuard = if ([string]::IsNullOrEmpty($scanFolder)) { @() } else { @($scanFolder) }
$criticalSet = Get-CriticalSet -Rules $allRules -Platform $platform -ExtraPaths $scanFolderGuard
$protectedRules = @($allRules | Where-Object { $_.allowDuplicateRemoval -ne $true })
$protectedSet = Get-CriticalSet -Rules $protectedRules -Platform $platform -ExtraPaths $scanFolderGuard
$freeRoot = if (-not [string]::IsNullOrEmpty($scanTarget)) { $scanTarget } else { $env:USERPROFILE }

$Context = [pscustomobject]@{
    DryRun = [bool]$DryRun
    Platform = $platform
    Target = $scanTarget
    NullDir = $nullDir
    CriticalSet = $criticalSet
    ProtectedSet = $protectedSet
    Duplicates = $scanDuplicates
    ScanHome = $scanHome
    ScanFolder = $scanFolder
    FreeRoot = $freeRoot
    Home = $env:USERPROFILE
}

$freeStart = Get-FreeBytes -Path $Context.FreeRoot
$dryRunStr = if ($Context.DryRun) { 'true' } else { 'false' }
Write-LogLine -Path $actualLogPath -Id '-' -Action 'run' -Result 'start' -FreeBefore $freeStart -FreeAfter $freeStart -Detail "dryRun=$dryRunStr ids=$($requestedIds -join ',')"

$rulesById = [ordered]@{}
foreach ($r in $allRules) {
    $rulesById[$r.id] = $r
}

$executionOrder = [System.Collections.Generic.List[string]]::new()
foreach ($r in $allRules) {
    if ($requestedIds -contains $r.id) {
        $executionOrder.Add($r.id)
    }
}
foreach ($id in $requestedIds) {
    if (-not $executionOrder.Contains($id)) {
        $executionOrder.Add($id)
    }
}

$executedSteps = [System.Collections.Generic.List[object]]::new()
foreach ($id in $executionOrder) {
    $freeBefore = Get-FreeBytes -Path $Context.FreeRoot
    $rule = if ($rulesById.Contains($id)) { $rulesById[$id] } else { $null }
    try {
        $decision = Get-StepDecision -Id $id -Rule $rule -Context $Context
        $stepResult = if ($null -ne $decision) {
            $decision
        } else {
            Invoke-RuleAction -Rule $rule -Context $Context
        }
    } catch {
        $stepResult = Get-ActionResult -Result 'failed' -Detail $_.Exception.Message
    }
    $freeAfter = Get-FreeBytes -Path $Context.FreeRoot

    if ($null -ne $stepResult.RefusedPaths -and $stepResult.RefusedPaths.Count -gt 0) {
        foreach ($rp in $stepResult.RefusedPaths) {
            Write-LogLine -Path $actualLogPath -Id $id -Action 'file' -Result 'refused' -FreeBefore $freeBefore -FreeAfter $freeBefore -Detail "protected path $rp"
        }
    }

    $actionType = if ($null -ne $rule -and $null -ne $rule.action -and -not [string]::IsNullOrEmpty($rule.action.type)) { $rule.action.type } else { '-' }
    Write-LogLine -Path $actualLogPath -Id $id -Action $actionType -Result $stepResult.Result -FreeBefore $freeBefore -FreeAfter $freeAfter -Detail $stepResult.Detail
    [Console]::Out.WriteLine("$($stepResult.Result) ${id}: $($stepResult.Detail)")

    $executedSteps.Add([pscustomobject]@{
        Id = $id
        Result = $stepResult.Result
        Detail = $stepResult.Detail
        Bytes = $stepResult.Bytes
    })
}

$failedCount = 0
foreach ($s in $executedSteps) {
    if ($s.Result -eq 'failed') {
        $failedCount++
    }
}
$freeEnd = Get-FreeBytes -Path $Context.FreeRoot
Write-LogLine -Path $actualLogPath -Id '-' -Action 'run' -Result 'end' -FreeBefore $freeStart -FreeAfter $freeEnd -Detail "failed=$failedCount"

Write-Summary -Steps @($executedSteps) -DryRun $Context.DryRun -FreeStart $freeStart -FreeEnd $freeEnd

if ($failedCount -gt 0) {
    exit 1
} else {
    exit 0
}
