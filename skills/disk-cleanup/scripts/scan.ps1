[CmdletBinding()]
param(
    [string]$Target = "$env:SystemDrive\",
    [string]$OutputDir = '',
    [int]$MinFileMB = 500,
    [string]$RulesPath = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($RulesPath)) {
    $RulesPath = Join-Path $PSScriptRoot '..\rules\rules.json'
}
. (Join-Path $PSScriptRoot 'common.ps1')

$BytesPerMegabyte = [int64]1048576
$MaxMinFileMB = 1048576
$MaxFolders = 100

function Measure-PathBytes {
    param(
        [string]$Path,
        [string]$NullDir,
        [object]$CriticalSet
    )
    if ([System.IO.Directory]::Exists($Path)) {
        $folderResult = Get-FolderBytes -Path $Path -NullDir $NullDir -CriticalSet $CriticalSet
        return [int64]$folderResult.Bytes
    }
    if ([System.IO.File]::Exists($Path)) {
        try {
            $fi = New-Object System.IO.FileInfo $Path
            return [int64]$fi.Length
        } catch {
            return [int64]0
        }
    }
    return [int64]0
}

function Get-ScanFolders {
    param(
        [string]$Target,
        [string]$NullDir
    )
    $parentCandidates = [System.Collections.Generic.List[string]]::new()
    $parentCandidates.Add($Target)
    $envVars = @(
        $env:USERPROFILE,
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:ProgramData,
        $env:SystemRoot
    )
    foreach ($v in $envVars) {
        if (-not [string]::IsNullOrEmpty($v) -and (Test-Path -LiteralPath $v -PathType Container)) {
            if (Test-PathUnder -Path $v -Parent $Target) {
                $parentCandidates.Add((ConvertTo-NormalizedPath $v))
            }
        }
    }

    $uniqueFolderPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $unreadable = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($parent in $parentCandidates) {
        try {
            $di = New-Object System.IO.DirectoryInfo $parent
            $subDirs = $di.GetDirectories()
            foreach ($sub in $subDirs) {
                if (($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) {
                    continue
                }
                $norm = ConvertTo-NormalizedPath $sub.FullName
                $uniqueFolderPaths.Add($norm) | Out-Null
            }
        } catch [System.UnauthorizedAccessException] {
            $unreadable.Add((ConvertTo-NormalizedPath $parent)) | Out-Null
        } catch {
            $null = $_
        }
    }

    $sizedFolders = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $uniqueFolderPaths) {
        $folderBytes = Get-FolderBytes -Path $p -NullDir $NullDir -CriticalSet $null
        foreach ($un in $folderBytes.Unreadable) {
            $unreadable.Add($un) | Out-Null
        }
        $sizedFolders.Add([pscustomobject]@{
            Path = $p
            Bytes = [int64]$folderBytes.Bytes
        })
    }

    $sorted = @($sizedFolders | Sort-Object -Property Bytes -Descending)
    $maxCount = [System.Math]::Min($sorted.Count, $MaxFolders)
    $top = if ($maxCount -gt 0) { @($sorted[0..($maxCount - 1)]) } else { @() }

    return [pscustomobject]@{
        Folders = @($top)
        Unreadable = [string[]]@($unreadable)
    }
}

function Get-LargeFiles {
    param(
        [string]$Target,
        [string]$NullDir,
        [int64]$MinBytes
    )
    $listing = Get-FileListing -Root $Target -NullDir $NullDir -CriticalSet $null -Recurse -MinBytes $MinBytes
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $listing.Files) {
        $mtime = try { [System.IO.File]::GetLastWriteTimeUtc($f.Path) } catch { [datetime]::UtcNow }
        $files.Add([pscustomobject]@{
            Path = $f.Path
            Bytes = [int64]$f.Bytes
            Modified = $mtime
        })
    }
    $sorted = @($files | Sort-Object -Property Bytes -Descending)
    return [pscustomobject]@{
        Files = @($sorted)
        Unreadable = [string[]]@($listing.Unreadable)
    }
}

function Get-DuplicateGroups {
    param([object[]]$LargeFiles)
    if ($null -eq $LargeFiles -or $LargeFiles.Count -eq 0) {
        return @()
    }
    $sizeGroups = @($LargeFiles | Group-Object -Property Bytes | Where-Object { $_.Count -ge 2 })
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($sg in $sizeGroups) {
        $hashedItems = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $sg.Group) {
            try {
                $hash = Get-FileSha256 -Path $item.Path
                $hashedItems.Add([pscustomobject]@{
                    Path = $item.Path
                    Bytes = [int64]$item.Bytes
                    Hash = $hash
                })
            } catch {
                $null = $_
            }
        }
        $hashGroups = @($hashedItems | Group-Object -Property Hash | Where-Object { $_.Count -ge 2 })
        foreach ($hg in $hashGroups) {
            $sortedPaths = [string[]]@($hg.Group | ForEach-Object { $_.Path })
            [Array]::Sort($sortedPaths, [System.StringComparer]::Ordinal)
            $groups.Add([ordered]@{
                bytes = [int64]$hg.Group[0].Bytes
                sha256 = $hg.Name
                paths = @($sortedPaths)
            })
        }
    }
    return $groups.ToArray()
}

function Get-RuleInfo {
    param(
        [object[]]$Rules,
        [string]$Platform
    )
    $infoList = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Rules) {
        $type = if ($r.action) { $r.action.type } else { '' }
        $paths = @(Get-RulePaths -Rule $r -Platform $Platform)
        $criticalSet = if ($r.tier -eq 'critical') { Get-CriticalSet -Rules @($r) -Platform $Platform } else { $null }
        $infoList.Add([pscustomobject]@{
            Rule = $r
            Id = $r.id
            Tier = $r.tier
            Type = $type
            Paths = $paths
            CriticalSet = $criticalSet
        })
    }
    return @($infoList)
}

function Get-MatchingRuleIds {
    param(
        [string]$Path,
        [bool]$IsFile,
        [int64]$Bytes,
        [datetime]$Modified,
        [object[]]$RuleInfo
    )
    $matched = [System.Collections.Generic.List[string]]::new()
    foreach ($info in $RuleInfo) {
        $id = $info.Id
        if ($info.Tier -eq 'critical') {
            if ($null -ne $info.CriticalSet -and (Test-CriticalPath -Path $Path -CriticalSet $info.CriticalSet)) {
                $matched.Add($id)
                continue
            }
        }
        if ($info.Type -eq 'clear-dir') {
            $isUnder = $false
            foreach ($p in $info.Paths) {
                if (Test-PathUnder -Path $Path -Parent $p) {
                    $isUnder = $true
                    break
                }
            }
            if ($isUnder) {
                $matched.Add($id)
                continue
            }
        }
        if ($IsFile -and $info.Type -eq 'delete-files') {
            $parentMatch = $false
            foreach ($p in $info.Paths) {
                if (Test-PathUnder -Path $Path -Parent $p) {
                    if ($info.Rule.action.recurse) {
                        $parentMatch = $true
                        break
                    } else {
                        $parentDir = [System.IO.Path]::GetDirectoryName($Path)
                        if ([string]::Equals($parentDir, $p, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $parentMatch = $true
                            break
                        }
                    }
                }
            }
            if (-not $parentMatch) {
                continue
            }
            $fileName = [System.IO.Path]::GetFileName($Path)
            $includeMatch = $false
            foreach ($inc in $info.Rule.action.include) {
                if ($fileName -like $inc) {
                    $includeMatch = $true
                    break
                }
            }
            if (-not $includeMatch) {
                continue
            }
            $minBytesThreshold = [int64]$info.Rule.action.minSizeMB * $BytesPerMegabyte
            if ($Bytes -lt $minBytesThreshold) {
                continue
            }
            if ($info.Rule.action.olderThanDays -gt 0) {
                $cutoff = [datetime]::UtcNow.AddDays(-$info.Rule.action.olderThanDays)
                if ($Modified -gt $cutoff) {
                    continue
                }
            }
            $matched.Add($id)
        }
    }
    return [string[]]@($matched)
}

function Get-ItemTier {
    param(
        [string[]]$RuleIds,
        [object[]]$RuleInfo
    )
    if ($null -eq $RuleIds -or $RuleIds.Count -eq 0) {
        return 'critical'
    }
    foreach ($id in $RuleIds) {
        $info = $RuleInfo | Where-Object { $_.Id -eq $id }
        if ($info -and $info.Tier -eq 'critical') {
            return 'critical'
        }
    }
    foreach ($id in $RuleIds) {
        $info = $RuleInfo | Where-Object { $_.Id -eq $id }
        if ($info -and $info.Tier -eq 'your_call') {
            return 'your_call'
        }
    }
    return 'safe'
}

function Get-RuleSummary {
    param(
        [object[]]$RuleInfo,
        [string]$Target,
        [string]$NullDir,
        [object[]]$Duplicates,
        [object]$ProtectedSet,
        [object]$CriticalSet,
        [string]$Platform
    )
    $summaries = [System.Collections.Generic.List[object]]::new()
    foreach ($info in $RuleInfo) {
        $paths = [string[]]@($info.Paths | Where-Object { Test-PathUnder -Path $_ -Parent $Target })
        $available = $false
        $bytes = $null

        if ($info.Tier -eq 'critical') {
            $available = $paths.Count -gt 0
            [int64]$sum = 0
            foreach ($p in $paths) {
                $sum += (Measure-PathBytes -Path $p -NullDir $NullDir -CriticalSet $null)
            }
            $bytes = $sum
        }
        elseif ($info.Type -eq 'tool') {
            $cmd = $info.Rule.action.command
            $commandFound = $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue)
            $available = $commandFound -and (Test-ToolRuleInScope -Rule $info.Rule -Platform $Platform -Target $Target)
            if ((Get-MatchEntries -Rule $info.Rule -Platform $Platform).Count -gt 0) {
                [int64]$sum = 0
                foreach ($p in $paths) {
                    $sum += (Measure-PathBytes -Path $p -NullDir $NullDir -CriticalSet $CriticalSet)
                }
                $bytes = $sum
            }
        }
        elseif ($info.Type -eq 'compact-docker-vhdx') {
            $available = $paths.Count -gt 0
            $bytes = $null
        }
        elseif ($info.Type -eq 'clear-dir') {
            $available = $paths.Count -gt 0
            [int64]$sum = 0
            foreach ($p in $paths) {
                if (-not (Test-ProtectedTarget -Path $p -CriticalSet $CriticalSet)) {
                    $sum += (Measure-PathBytes -Path $p -NullDir $NullDir -CriticalSet $CriticalSet)
                }
            }
            $bytes = $sum
        }
        elseif ($info.Type -eq 'delete-files') {
            $available = $paths.Count -gt 0
            $a = $info.Rule.action
            [int64]$sum = 0
            foreach ($p in $paths) {
                if (-not (Test-ProtectedTarget -Path $p -CriticalSet $CriticalSet)) {
                    $recurseFlag = if ($a.recurse) { $true } else { $false }
                    $listing = Get-FileListing -Root $p -NullDir $NullDir -CriticalSet $CriticalSet -Include @($a.include) -Recurse:$recurseFlag -MinBytes ([int64]$a.minSizeMB * $BytesPerMegabyte) -MinAgeDays ([int]$a.olderThanDays) -ExcludeTempFolders
                    foreach ($f in $listing.Files) {
                        $sum += [int64]$f.Bytes
                    }
                }
            }
            $bytes = $sum
        }
        elseif ($info.Type -eq 'old-versions') {
            $available = $paths.Count -gt 0
            [int64]$sum = 0
            foreach ($p in $paths) {
                if (-not (Test-ProtectedTarget -Path $p -CriticalSet $CriticalSet)) {
                    $oldDirs = Get-OldVersionFolders -Path $p
                    foreach ($d in $oldDirs) {
                        if (-not (Test-CriticalPath -Path $d -CriticalSet $CriticalSet)) {
                            $sum += (Measure-PathBytes -Path $d -NullDir $NullDir -CriticalSet $CriticalSet)
                        }
                    }
                }
            }
            $bytes = $sum
        }
        elseif ($info.Type -eq 'dedupe') {
            $available = ($null -ne $Duplicates -and $Duplicates.Count -gt 0)
            [int64]$sum = 0
            if ($null -ne $Duplicates) {
                foreach ($g in $Duplicates) {
                    $toDelete = @(Get-DedupeDeletions -Paths @($g.paths) -ProtectedSet $ProtectedSet)
                    $sum += ([int64]$toDelete.Count * [int64]$g.bytes)
                }
            }
            $bytes = $sum
        }
        else {
            $available = $paths.Count -gt 0
            $bytes = $null
        }

        $summaries.Add([ordered]@{
            id = $info.Id
            tier = $info.Tier
            available = $available
            bytes = $bytes
            paths = @($paths)
        })
    }
    return @($summaries)
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

if ($MinFileMB -lt 1 -or $MinFileMB -gt $MaxMinFileMB) {
    [Console]::Error.WriteLine('Invalid argument: MinFileMB must be between 1 and 1048576')
    exit 2
}

if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    [Console]::Error.WriteLine("Invalid argument: target not found: $Target")
    exit 2
}
$targetPath = ConvertTo-NormalizedPath $Target

$outputPath = if ($OutputDir -ne '') {
    ConvertTo-NormalizedPath $OutputDir
} else {
    ConvertTo-NormalizedPath (Join-Path ([System.IO.Path]::GetPathRoot($targetPath)) 'tmp\diskscan')
}

if (Test-IsTempPath -Path $outputPath) {
    [Console]::Error.WriteLine("Output folder refused: $outputPath is inside a Temp folder")
    exit 3
}

try {
    [void][System.IO.Directory]::CreateDirectory($outputPath)
} catch {
    [Console]::Error.WriteLine("Cannot create output folder: $outputPath")
    exit 3
}

try {
    $allRules = Get-DiskCleanupRules -Path $RulesPath
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 4
}
$rules = Get-RulesForPlatform -Rules $allRules -Platform $platform

$nullDir = Join-Path $outputPath '.robocopy-null'
$criticalSet = Get-CriticalSet -Rules $allRules -Platform $platform
$protectedSet = Get-CriticalSet -Rules @($allRules | Where-Object { -not $_.allowDuplicateRemoval }) -Platform $platform

$root = [System.IO.Path]::GetPathRoot($targetPath)
$di = New-Object System.IO.DriveInfo $root
$drive = [ordered]@{
    root = $root
    totalBytes = [int64]$di.TotalSize
    usedBytes = [int64]($di.TotalSize - $di.TotalFreeSpace)
    freeBytes = [int64]$di.AvailableFreeSpace
}

$minBytes = [int64]$MinFileMB * $BytesPerMegabyte
$scanFoldersResult = Get-ScanFolders -Target $targetPath -NullDir $nullDir
$largeFilesResult = Get-LargeFiles -Target $targetPath -NullDir $nullDir -MinBytes $minBytes
$duplicateGroups = @(Get-DuplicateGroups -LargeFiles $largeFilesResult.Files)
$ruleInfoList = Get-RuleInfo -Rules $rules -Platform $platform
$rulesSummary = Get-RuleSummary -RuleInfo $ruleInfoList -Target $targetPath -NullDir $nullDir -Duplicates $duplicateGroups -ProtectedSet $protectedSet -CriticalSet $criticalSet -Platform $platform

$folderItems = [System.Collections.Generic.List[object]]::new()
foreach ($f in $scanFoldersResult.Folders) {
    $matchedIds = @(Get-MatchingRuleIds -Path $f.Path -IsFile $false -Bytes 0 -Modified ([datetime]::UtcNow) -RuleInfo $ruleInfoList)
    $tier = Get-ItemTier -RuleIds $matchedIds -RuleInfo $ruleInfoList
    $folderItems.Add([ordered]@{
        path = $f.Path
        bytes = [int64]$f.Bytes
        tier = $tier
        ruleIds = [string[]]@($matchedIds)
    })
}

$largeFileItems = [System.Collections.Generic.List[object]]::new()
foreach ($f in $largeFilesResult.Files) {
    $matchedIds = @(Get-MatchingRuleIds -Path $f.Path -IsFile $true -Bytes $f.Bytes -Modified $f.Modified -RuleInfo $ruleInfoList)
    $tier = Get-ItemTier -RuleIds $matchedIds -RuleInfo $ruleInfoList
    $largeFileItems.Add([ordered]@{
        path = $f.Path
        bytes = [int64]$f.Bytes
        modified = Format-UtcTimestamp $f.Modified
        tier = $tier
        ruleIds = [string[]]@($matchedIds)
    })
}

$unreadableSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($un in $scanFoldersResult.Unreadable) {
    $unreadableSet.Add($un) | Out-Null
}
foreach ($un in $largeFilesResult.Unreadable) {
    $unreadableSet.Add($un) | Out-Null
}
$unreadableList = [string[]]@($unreadableSet)
[Array]::Sort($unreadableList, [System.StringComparer]::Ordinal)

$result = [ordered]@{
    schemaVersion = 1
    createdAt = Format-UtcTimestamp ([datetime]::UtcNow)
    os = $platform
    target = $targetPath
    home = $env:USERPROFILE
    minFileBytes = $minBytes
    drive = $drive
    rules = @($rulesSummary)
    folders = @($folderItems.ToArray())
    largeFiles = @($largeFileItems.ToArray())
    duplicates = @($duplicateGroups)
    unreadable = [string[]]@($unreadableList)
}

$jsonPath = Join-Path $outputPath 'scan.json'
ConvertTo-JsonFile -InputObject $result -Path $jsonPath

Write-Output ('Scan complete: {0} ({1} folders, {2} large files, {3} duplicate groups, {4} unreadable)' -f $jsonPath, $folderItems.Count, $largeFileItems.Count, $duplicateGroups.Count, $unreadableList.Length)
exit 0
