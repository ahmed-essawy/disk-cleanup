function ConvertTo-NormalizedPath {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        return $full.TrimEnd('\')
    }
    return $full
}

function Get-DiskCleanupRules {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Rules file invalid: $Path"
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        $data = $raw | ConvertFrom-Json
    } catch {
        throw "Rules file invalid: $Path"
    }
    if ($null -eq $data -or $null -eq $data.rules) {
        throw "Rules file invalid: $Path"
    }
    $rulesList = @($data.rules)
    foreach ($rule in $rulesList) {
        if ($null -eq $rule.id -or -not ($rule.id -is [string]) -or $null -eq $rule.tier -or -not ($rule.tier -is [string])) {
            throw "Rules file invalid: $Path"
        }
    }
    return $rulesList
}

function Get-CurrentPlatform {
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        return 'windows'
    }
    throw "Unsupported OS: $([System.Environment]::OSVersion.Platform)"
}

function Get-RulesForPlatform {
    param(
        [object[]]$Rules,
        [string]$Platform
    )
    return @($Rules | Where-Object { $_.platforms -contains $Platform })
}

function Get-MatchEntries {
    param(
        [object]$Rule,
        [string]$Platform
    )
    if ($null -eq $Rule.match -or $null -eq $Rule.match.$Platform) {
        return [string[]]@()
    }
    $items = @($Rule.match.$Platform | Where-Object { $null -ne $_ })
    return [string[]]$items
}

function Resolve-MatchToken {
    param([string]$Entry)
    $resolved = $Entry
    $tokenMatches = [regex]::Matches($Entry, '\$\{([A-Za-z_][A-Za-z0-9_()]*)\}')
    foreach ($m in $tokenMatches) {
        $varName = $m.Groups[1].Value
        $val = [Environment]::GetEnvironmentVariable($varName)
        if ([string]::IsNullOrEmpty($val)) {
            return $null
        }
        $resolved = $resolved.Replace($m.Value, $val)
    }
    return $resolved.Replace('/', '\')
}

function Expand-MatchEntry {
    param([string]$Entry)
    if ($Entry.StartsWith('**/', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [string[]]@()
    }
    $p = Resolve-MatchToken -Entry $Entry
    if ($null -eq $p) {
        return [string[]]@()
    }
    if ($p.IndexOfAny([char[]]@('*', '?')) -ge 0) {
        $items = @(Get-Item -Path $p -Force -ErrorAction SilentlyContinue | ForEach-Object {
            ConvertTo-NormalizedPath -Path $_.FullName
        })
        return [string[]]$items
    }
    if (Test-Path -LiteralPath $p) {
        return [string[]]@((ConvertTo-NormalizedPath -Path $p))
    }
    return [string[]]@()
}

function Get-RulePaths {
    param(
        [object]$Rule,
        [string]$Platform,
        [string]$Target = ''
    )
    $entries = Get-MatchEntries -Rule $Rule -Platform $Platform
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $entries) {
        $expanded = Expand-MatchEntry -Entry $entry
        foreach ($p in $expanded) {
            $paths.Add($p)
        }
    }
    $result = @($paths)
    if (-not [string]::IsNullOrEmpty($Target)) {
        $result = @($result | Where-Object { Test-PathUnder -Path $_ -Parent $Target })
    }
    return [string[]]@($result | Select-Object -Unique)
}

function Test-IsSystemDrive {
    param([string]$Path)
    $systemRoot = [System.IO.Path]::GetPathRoot((ConvertTo-NormalizedPath -Path ([Environment]::GetEnvironmentVariable('SystemDrive') + '\')))
    $pathRoot = [System.IO.Path]::GetPathRoot((ConvertTo-NormalizedPath -Path $Path))
    return [string]::Equals($systemRoot, $pathRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-ToolRuleInScope {
    param(
        [object]$Rule,
        [string]$Platform,
        [string]$Target
    )
    if ((Get-MatchEntries -Rule $Rule -Platform $Platform).Count -eq 0) {
        return ($Rule.id -ne 'dism-component-cleanup') -or (Test-IsSystemDrive -Path $Target)
    }
    return @(Get-RulePaths -Rule $Rule -Platform $Platform -Target $Target).Count -gt 0
}

function Get-CriticalSet {
    param(
        [object[]]$Rules,
        [string]$Platform
    )
    $paths = [System.Collections.Generic.List[string]]::new()
    $namePatterns = [System.Collections.Generic.List[string]]::new()
    $criticalRules = @($Rules | Where-Object { $_.tier -eq 'critical' -and $_.platforms -contains $Platform })
    foreach ($rule in $criticalRules) {
        $entries = Get-MatchEntries -Rule $rule -Platform $Platform
        foreach ($entry in $entries) {
            if ($entry.StartsWith('**/', [System.StringComparison]::OrdinalIgnoreCase)) {
                $namePatterns.Add($entry.Substring(3))
            } elseif ($entry.IndexOfAny([char[]]@('*', '?')) -ge 0) {
                $expanded = Expand-MatchEntry -Entry $entry
                foreach ($p in $expanded) {
                    $paths.Add($p)
                }
            } else {
                $resolved = Resolve-MatchToken -Entry $entry
                if ($null -ne $resolved) {
                    $paths.Add((ConvertTo-NormalizedPath -Path $resolved))
                }
            }
        }
    }
    $expandedPaths = @($paths | ForEach-Object { Expand-ShortNamePath -Path $_ })
    $uniquePaths = [string[]]@($expandedPaths | Select-Object -Unique)
    return [pscustomobject]@{
        Paths = $uniquePaths
        PathSet = Get-PathSet -Paths $uniquePaths
        DirectoryVerdicts = [System.Collections.Generic.Dictionary[string,bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
        NamePatterns = [string[]]@($namePatterns | Select-Object -Unique)
        Unresolved = [string[]]@($expandedPaths | Where-Object { Test-ShortNamePath -Path $_ } | Select-Object -Unique)
    }
}

function Expand-ShortNamePath {
    param([string]$Path)
    if (-not (Test-ShortNamePath -Path $Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $Path
    }
    return (Get-Item -LiteralPath $Path -Force).FullName
}

function Test-ShortNamePath {
    param([string]$Path)
    return (@($Path -split '[\\/]' | Where-Object { $_ -match '~\d' }).Count -gt 0)
}

function Test-PathUnder {
    param(
        [string]$Path,
        [string]$Parent
    )
    $normPath = ConvertTo-NormalizedPath -Path $Path
    $normParent = ConvertTo-NormalizedPath -Path $Parent
    if ([string]::Equals($normPath, $normParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $normParent
    if (-not $prefix.EndsWith('\')) {
        $prefix += '\'
    }
    if ($normPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $false
}

function Get-PathSet {
    param([string[]]$Paths)
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Paths) {
        $null = $set.Add((ConvertTo-NormalizedPath -Path $p))
    }
    return , $set
}

function Test-NormalizedPathInSet {
    param(
        [string]$NormPath,
        [System.Collections.Generic.HashSet[string]]$PathSet
    )
    $current = $NormPath
    while (-not [string]::IsNullOrEmpty($current)) {
        if ($PathSet.Contains($current)) {
            return $true
        }
        $current = [System.IO.Path]::GetDirectoryName($current)
    }
    return $false
}
function Test-NameMatch {
    param(
        [string]$Path,
        [string[]]$NamePatterns
    )
    if ($null -eq $NamePatterns -or $NamePatterns.Count -eq 0) {
        return $false
    }
    $segments = $Path.Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($seg in $segments) {
        foreach ($pattern in $NamePatterns) {
            if ($seg -like $pattern) {
                return $true
            }
        }
    }
    return $false
}

function Get-CriticalPathSet {
    param([object]$CriticalSet)
    $pathSet = $CriticalSet.PathSet
    if ($null -eq $pathSet) {
        $pathSet = Get-PathSet -Paths @($CriticalSet.Paths)
    }
    return , $pathSet
}
function Test-CriticalDirectory {
    param(
        [string]$Directory,
        [object]$CriticalSet
    )
    $verdicts = $CriticalSet.DirectoryVerdicts
    $cached = $false
    if ($null -ne $verdicts -and $verdicts.TryGetValue($Directory, [ref]$cached)) {
        return $cached
    }
    $pathSet = Get-CriticalPathSet -CriticalSet $CriticalSet
    $critical = (Test-NormalizedPathInSet -NormPath $Directory -PathSet $pathSet) -or (Test-NameMatch -Path $Directory -NamePatterns $CriticalSet.NamePatterns)
    if ($null -ne $verdicts) {
        $verdicts[$Directory] = $critical
    }
    return $critical
}

function Test-CriticalPath {
    param(
        [string]$Path,
        [object]$CriticalSet
    )
    if ($null -eq $CriticalSet) {
        return $false
    }
    $normPath = ConvertTo-NormalizedPath -Path $Path
    $pathSet = Get-CriticalPathSet -CriticalSet $CriticalSet
    if ($pathSet.Contains($normPath)) {
        return $true
    }
    $directory = [System.IO.Path]::GetDirectoryName($normPath)
    if (-not [string]::IsNullOrEmpty($directory) -and (Test-CriticalDirectory -Directory $directory -CriticalSet $CriticalSet)) {
        return $true
    }
    return (Test-NameMatch -Path ([System.IO.Path]::GetFileName($normPath)) -NamePatterns $CriticalSet.NamePatterns)
}
function Test-ProtectedTarget {
    param(
        [string]$Path,
        [object]$CriticalSet
    )
    $n = ConvertTo-NormalizedPath -Path $Path
    $root = [System.IO.Path]::GetPathRoot($n)
    if ([string]::Equals($n, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $userProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    if (-not [string]::IsNullOrEmpty($userProfile)) {
        $normProfile = ConvertTo-NormalizedPath -Path $userProfile
        if ([string]::Equals($normProfile, $n, [System.StringComparison]::OrdinalIgnoreCase) -or $normProfile.StartsWith($n + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    if (Test-CriticalPath -Path $n -CriticalSet $CriticalSet) {
        return $true
    }
    return $false
}

function Test-UserProfileCanonical {
    $userProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    if ([string]::IsNullOrEmpty($userProfile)) {
        return $false
    }
    try {
        $normalized = ConvertTo-NormalizedPath -Path $userProfile
    } catch {
        return $false
    }
    if (-not [string]::Equals($userProfile, $normalized, [System.StringComparison]::Ordinal)) {
        return $false
    }
    return (Test-Path -LiteralPath $userProfile -PathType Container)
}

function Get-TempRoots {
    $tempRoots = [System.Collections.Generic.List[string]]::new()
    $tempVar = [Environment]::GetEnvironmentVariable('TEMP')
    if (-not [string]::IsNullOrEmpty($tempVar)) {
        $tempRoots.Add($tempVar)
    }
    $tmpVar = [Environment]::GetEnvironmentVariable('TMP')
    if (-not [string]::IsNullOrEmpty($tmpVar)) {
        $tempRoots.Add($tmpVar)
    }
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if (-not [string]::IsNullOrEmpty($localAppData)) {
        $tempRoots.Add((Join-Path $localAppData 'Temp'))
    }
    $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
    if (-not [string]::IsNullOrEmpty($systemRoot)) {
        $tempRoots.Add((Join-Path $systemRoot 'Temp'))
    }
    return [string[]]@($tempRoots)
}

function Test-IsTempPath {
    param([string]$Path)
    foreach ($root in (Get-TempRoots)) {
        if (Test-PathUnder -Path $Path -Parent $root) {
            return $true
        }
    }
    return $false
}

function Test-IsElevated {
    if ([Environment]::GetEnvironmentVariable('DISK_CLEANUP_FORCE_NOT_ELEVATED') -eq '1') {
        return $false
    }
    return [bool](([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
}

function Get-FreeBytes {
    param([string]$Path)
    $normalized = ConvertTo-NormalizedPath $Path
    $root = [System.IO.Path]::GetPathRoot($normalized)
    $drive = New-Object System.IO.DriveInfo $root
    return [int64]$drive.AvailableFreeSpace
}

function Format-Gigabytes {
    param([int64]$Bytes)
    $gb = [double]$Bytes / 1073741824.0
    return $gb.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-JsonFile {
    param(
        [object]$InputObject,
        [string]$Path
    )
    $json = ConvertTo-Json -InputObject $InputObject -Depth 8
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Get-Command Get-FileHash -ErrorAction SilentlyContinue)) {
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            Import-Module Microsoft.PowerShell.Utility -RequiredVersion 3.1.0.0 -ErrorAction SilentlyContinue
        } else {
            Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
        }
    }
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
    return $hash.Hash.ToLowerInvariant()
}

function Format-UtcTimestamp {
    param([datetime]$Value)
    return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-RoboExclusionArgs {
    param(
        [string]$Root,
        [object]$CriticalSet,
        [string[]]$ExtraDirectories = @()
    )
    if ($null -eq $CriticalSet -and $ExtraDirectories.Count -eq 0) {
        return @()
    }
    $normalizedRoot = ConvertTo-NormalizedPath $Root
    $items = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $CriticalSet.Paths) {
        foreach ($p in $CriticalSet.Paths) {
            if ((Test-PathUnder -Path $p -Parent $Root) -and ($p -ne $normalizedRoot)) {
                $items.Add($p)
            }
        }
    }
    if ($null -ne $CriticalSet.NamePatterns) {
        foreach ($np in $CriticalSet.NamePatterns) {
            $items.Add($np)
        }
    }
    if ($items.Count -eq 0 -and $ExtraDirectories.Count -eq 0) {
        return @()
    }
    $result = @('/XD') + @($items) + @($ExtraDirectories)
    if ($items.Count -gt 0) {
        $result += @('/XF') + @($items)
    }
    return $result
}

function Invoke-RoboList {
    param(
        [string]$Source,
        [string]$NullDir,
        [string[]]$Arguments
    )
    $ErrorActionPreference = 'Continue'
    $src = $Source
    if ($src.EndsWith('\')) {
        $src = $src + '.'
    }
    $logFolder = Split-Path -Parent $NullDir
    $null = [System.IO.Directory]::CreateDirectory($logFolder)
    $logPath = Join-Path $logFolder ('.robocopy-' + [guid]::NewGuid().ToString('N') + '.log')
    try {
        $null = & robocopy $src $NullDir @Arguments "/UNILOG:$logPath" 2>&1
        if (-not [System.IO.File]::Exists($logPath)) {
            return @()
        }
        return @([System.IO.File]::ReadAllLines($logPath, [System.Text.Encoding]::Unicode))
    } finally {
        [System.IO.File]::Delete($logPath)
    }
}

function ConvertFrom-RoboFileLines {
    param([string[]]$Lines)
    $results = [System.Collections.Generic.List[object]]::new()
    $pattern = '^\s*(\d+)\s+([A-Za-z]:\\.+?)\s*$'
    foreach ($line in $Lines) {
        if ($line -match $pattern) {
            $results.Add([pscustomobject]@{
                Path = $Matches[2]
                Bytes = [int64]$Matches[1]
            })
        }
    }
    return @($results)
}

function Get-RoboSummaryBytes {
    param([string[]]$Lines)
    $pattern = '^\s*[^:\d\s][^:]*:\s+(\d+)(\s+\d+){5}\s*$'
    $count = 0
    foreach ($line in $Lines) {
        if ($line -match $pattern) {
            $count++
            if ($count -eq 3) {
                return [int64]$Matches[1]
            }
        }
    }
    return [int64]0
}

function Get-RoboErrorPaths {
    param([string[]]$Lines)
    $results = [System.Collections.Generic.List[string]]::new()
    $pattern = '\(0x[0-9A-Fa-f]{8}\).*?([A-Za-z]:\\.*?)\\?\s*$'
    foreach ($line in $Lines) {
        if ($line -match $pattern) {
            $p = $Matches[1]
            if (-not $results.Contains($p)) {
                $results.Add($p)
            }
        }
    }
    return @($results)
}

function Get-FileListing {
    param(
        [string]$Root,
        [string]$NullDir,
        [object]$CriticalSet,
        [string[]]$Include = @('*.*'),
        [switch]$Recurse,
        [int64]$MinBytes = 0,
        [int]$MinAgeDays = 0,
        [switch]$ExcludeTempFolders
    )
    $robocopyArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($inc in $Include) {
        $robocopyArgs.Add($inc)
    }
    $robocopyArgs.AddRange([string[]]@('/L', '/NJH', '/NJS', '/BYTES', '/FP', '/NC', '/NDL', '/XJ', '/R:0', '/W:0', '/MT:16'))
    if ($Recurse) {
        $robocopyArgs.Add('/S')
    }
    if ($MinBytes -gt 0) {
        $robocopyArgs.Add("/MIN:$MinBytes")
    }
    if ($MinAgeDays -gt 0) {
        $robocopyArgs.Add("/MINAGE:$MinAgeDays")
    }
    $tempExcludes = @()
    if ($ExcludeTempFolders -and -not (Test-IsTempPath -Path $Root)) {
        $tempExcludes = @(Get-TempRoots | Where-Object { Test-PathUnder -Path $_ -Parent $Root })
    }
    $exclusionArgs = Get-RoboExclusionArgs -Root $Root -CriticalSet $CriticalSet -ExtraDirectories $tempExcludes
    foreach ($ex in $exclusionArgs) {
        $robocopyArgs.Add($ex)
    }
    $lines = Invoke-RoboList -Source $Root -NullDir $NullDir -Arguments @($robocopyArgs)
    $rawFiles = ConvertFrom-RoboFileLines -Lines $lines
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $rawFiles) {
        if ($null -ne $CriticalSet) {
            if (Test-CriticalPath -Path $f.Path -CriticalSet $CriticalSet) {
                continue
            }
        }
        $files.Add($f)
    }
    $unreadable = Get-RoboErrorPaths -Lines $lines
    return [pscustomobject]@{
        Files = @($files)
        Unreadable = @($unreadable)
    }
}

function Get-FolderBytes {
    param(
        [string]$Path,
        [string]$NullDir,
        [object]$CriticalSet
    )
    $robocopyArgs = [System.Collections.Generic.List[string]]::new()
    $robocopyArgs.AddRange([string[]]@('/L', '/S', '/NJH', '/BYTES', '/NFL', '/NDL', '/NC', '/XJ', '/R:0', '/W:0', '/MT:16'))
    $exclusionArgs = Get-RoboExclusionArgs -Root $Path -CriticalSet $CriticalSet
    foreach ($ex in $exclusionArgs) {
        $robocopyArgs.Add($ex)
    }
    $lines = Invoke-RoboList -Source $Path -NullDir $NullDir -Arguments @($robocopyArgs)
    $bytes = Get-RoboSummaryBytes -Lines $lines
    $unreadable = Get-RoboErrorPaths -Lines $lines
    return [pscustomobject]@{
        Bytes = [int64]$bytes
        Unreadable = @($unreadable)
    }
}

function Get-ReferencedExtensionFolders {
    param([string]$Path)
    $file = Join-Path $Path 'extensions.json'
    $names = [System.Collections.Generic.List[string]]::new()
    if (-not [System.IO.File]::Exists($file)) {
        return [string[]]@()
    }
    try {
        $entries = @(ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($file)) | ForEach-Object { $_ })
    } catch {
        return [string[]]@()
    }
    foreach ($entry in $entries) {
        $candidates = @($entry.relativeLocation, $entry.location.path, $entry.location.fsPath)
        foreach ($candidate in $candidates) {
            if ($candidate -is [string] -and -not [string]::IsNullOrEmpty($candidate)) {
                $names.Add(($candidate.TrimEnd('/', '\') -split '[\\/]')[-1])
            }
        }
    }
    return [string[]]@($names)
}

function Get-OldVersionFolders {
    param([string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) {
        return @()
    }
    $dirInfo = New-Object System.IO.DirectoryInfo $Path
    $subDirs = $dirInfo.GetDirectories()
    $referenced = @(Get-ReferencedExtensionFolders -Path $Path)
    $regex = [regex]'^(.+)-(\d+(\.\d+){1,3})(-.+)?$'
    $dict = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[object]]' ([System.StringComparer]::Ordinal)
    foreach ($dir in $subDirs) {
        if (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            continue
        }
        $m = $regex.Match($dir.Name)
        if (-not $m.Success) {
            continue
        }
        $key = $m.Groups[1].Value + $m.Groups[4].Value
        $rawParts = $m.Groups[2].Value.Split('.')
        $parts = [System.Collections.Generic.List[string]]::new($rawParts)
        while ($parts.Count -lt 4) {
            $parts.Add('0')
        }
        $ver = try {
            [version]($parts -join '.')
        } catch {
            $null
        }
        if ($null -eq $ver) {
            continue
        }
        if (-not $dict.ContainsKey($key)) {
            $dict[$key] = [System.Collections.Generic.List[object]]::new()
        }
        $dict[$key].Add([pscustomobject]@{
            Directory = $dir
            Version = $ver
        })
    }
    $toDelete = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $dict.Values) {
        if ($entry.Count -lt 2) {
            continue
        }
        $entry.Sort([System.Comparison[object]]{
            param($a, $b)
            return $b.Version.CompareTo($a.Version)
        })
        for ($i = 1; $i -lt $entry.Count; $i++) {
            if ($referenced -contains $entry[$i].Directory.Name) {
                continue
            }
            $toDelete.Add($entry[$i].Directory.FullName)
        }
    }
    return [string[]]@($toDelete)
}

function Get-FileIdentity {
    param([string]$Path)
    if (-not ('DiskCleanup.FileIdentity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace DiskCleanup
{
    public static class FileIdentity
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileTimeValue
        {
            public uint Low;
            public uint High;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public FileTimeValue CreationTime;
            public FileTimeValue LastAccessTime;
            public FileTimeValue LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleFileInformation information);

        public static string Get(string path)
        {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(stream.SafeFileHandle, out information))
                {
                    return null;
                }
                return information.VolumeSerialNumber + ":" + information.FileIndexHigh + ":" + information.FileIndexLow;
            }
        }
    }
}
'@
    }
    try {
        return [DiskCleanup.FileIdentity]::Get($Path)
    } catch {
        return $null
    }
}

function Get-DedupeDeletions {
    param(
        [string[]]$Paths,
        [object]$ProtectedSet
    )
    $existing = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $Paths) {
        if ([System.IO.File]::Exists($p)) {
            $existing.Add([pscustomobject]@{
                Path = $p
                Time = [System.IO.File]::GetLastWriteTimeUtc($p)
                Identity = Get-FileIdentity -Path $p
            })
        }
    }
    if ($existing.Count -lt 2) {
        return [string[]]@()
    }
    $existing.Sort([System.Comparison[object]]{
        param($a, $b)
        $c = $a.Time.CompareTo($b.Time)
        if ($c -ne 0) {
            return $c
        }
        return [string]::CompareOrdinal($a.Path, $b.Path)
    })
    $identityCounts = @{}
    foreach ($item in $existing) {
        $identityCounts[[string]$item.Identity] = 1 + [int]$identityCounts[[string]$item.Identity]
    }
    $results = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -lt $existing.Count; $i++) {
        $candidate = $existing[$i].Path
        if ([string]::IsNullOrEmpty($existing[$i].Identity) -or $identityCounts[[string]$existing[$i].Identity] -gt 1) {
            continue
        }
        if ($null -ne $ProtectedSet) {
            if (Test-CriticalPath -Path $candidate -CriticalSet $ProtectedSet) {
                continue
            }
        }
        $results.Add($candidate)
    }
    return [string[]]@($results)
}

