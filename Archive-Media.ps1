[CmdletBinding()]
param(
    [string] $DriveRoot,

    [string] $ConfigPath,

    [switch] $DryRun
)

Set-StrictMode -Version 5.1
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }

function Normalize-DriveRoot {
    param([string] $Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.EndsWith('\')) {
        $resolved += '\'
    }
    return $resolved
}

function Get-ArchiveConfig {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file was not found: $Path"
    }

    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string] $config.ArchiveRoot)) {
        throw 'ArchiveRoot must be configured.'
    }

    $extensions = @($config.MediaExtensions | ForEach-Object { ([string] $_).ToLowerInvariant() })
    if ($extensions.Count -eq 0) {
        throw 'MediaExtensions must contain at least one extension.'
    }

    return [pscustomobject]@{
        ArchiveRoot = [Environment]::ExpandEnvironmentVariables([string] $config.ArchiveRoot)
        MediaExtensions = $extensions
    }
}

function Get-UsbDiskForDrive {
    param([string] $Root)

    $driveLetter = ([IO.Path]::GetPathRoot($Root)).TrimEnd(':\')
    if ([string]::IsNullOrWhiteSpace($driveLetter)) {
        throw "DriveRoot must be a drive-letter path: $Root"
    }

    try {
        $partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    }
    catch {
        throw "Unable to resolve USB disk for $Root. $($_.Exception.Message)"
    }

    if ([string]$disk.BusType -ne 'USB') {
        throw "The source drive is not USB-backed: $Root (BusType=$($disk.BusType))"
    }

    return $disk
}

function Get-MediaFiles {
    param(
        [string] $Root,
        [string[]] $Extensions
    )

    $normalized = @($Extensions | ForEach-Object { if ($_ -notmatch '^\.') { ".$($_)" } else { $_ } } | ForEach-Object { $_.ToLowerInvariant() })
    $allFiles = @(Get-ChildItem -LiteralPath $Root -File -Force -Recurse -ErrorAction Stop |
        Where-Object { (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) })
    $mediaFiles = @($allFiles | Where-Object { $normalized -contains $_.Extension.ToLowerInvariant() })

    if ($normalized -contains '.srt') {
        $mp4Keys = @{}
        foreach ($file in ($allFiles | Where-Object { $_.Extension.ToLowerInvariant() -eq '.mp4' })) {
            $mp4Keys[$file.FullName.Substring($Root.Length).ToLowerInvariant()] = $true
        }

        $mediaFiles = @($mediaFiles | Where-Object {
            if ($_.Extension.ToLowerInvariant() -ne '.srt') { return $true }
            $mp4Key = $_.FullName.Substring($Root.Length, $_.FullName.Length - $Root.Length - $_.Extension.Length).ToLowerInvariant() + '.mp4'
            return $mp4Keys.ContainsKey($mp4Key)
        })
    }

    $mediaFiles | Sort-Object { $_.FullName.Substring($Root.Length).ToLowerInvariant() }
}

function Get-SequentialName {
    param(
        [int] $Index,
        [string] $Extension
    )

    return ('{0:D6}{1}' -f $Index, $Extension)
}

function Get-DestinationRecords {
    param(
        [string] $Root,
        [object[]] $Files
    )

    $records = New-Object System.Collections.Generic.List[object]
    $pairNames = @{}
    $nextIndex = 1

    foreach ($file in $Files) {
        $relativePath = $file.FullName.Substring($Root.Length)
        $pairKey = [IO.Path]::ChangeExtension($relativePath, $null).ToLowerInvariant()
        $extension = $file.Extension

        if ($extension.ToLowerInvariant() -eq '.srt' -and $pairNames.ContainsKey($pairKey)) {
            $destinationName = $pairNames[$pairKey] + $extension
        }
        else {
            $destinationBaseName = Get-SequentialName -Index $nextIndex -Extension ''
            $nextIndex++
            if ($extension.ToLowerInvariant() -eq '.mp4') {
                $pairNames[$pairKey] = $destinationBaseName
            }
            $destinationName = $destinationBaseName + $extension
        }

        $records.Add([pscustomobject]@{
            SourcePath = $file.FullName
            RelativeSourcePath = $relativePath
            DestinationName = $destinationName
            SourceLength = $file.Length
            SourceHash = $null
            DestinationHash = $null
            Status = 'Discovered'
        })
    }

    return $records.ToArray()
}

function Test-DestinationIsSafe {
    param(
        [string] $SourceRoot,
        [string] $ArchiveRoot
    )

    $sourceVolume = ([IO.Path]::GetPathRoot($SourceRoot)).ToLowerInvariant()
    $archiveVolume = ([IO.Path]::GetPathRoot($ArchiveRoot)).ToLowerInvariant()
    if ($sourceVolume -eq $archiveVolume) {
        throw "ArchiveRoot must not be on the inserted USB volume: $ArchiveRoot"
    }
}

function Invoke-Archive {
    param(
        [string] $SourceRoot,
        [string] $SettingsPath,
        [switch] $Preview
    )

    $source = Normalize-DriveRoot $SourceRoot
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Source drive is not available: $source"
    }

    Get-UsbDiskForDrive $source | Out-Null
    $config = Get-ArchiveConfig $SettingsPath
    $archiveRoot = [IO.Path]::GetFullPath($config.ArchiveRoot)
    Test-DestinationIsSafe $source $archiveRoot

    $files = @(Get-MediaFiles -Root $source -Extensions $config.MediaExtensions)
    if ($files.Count -eq 0) {
        Write-Host "No configured media files found on $source"
        return
    }

    $dateRoot = Join-Path $archiveRoot (Get-Date -Format 'yyyy-MM-dd')
    $runRoot = Join-Path $dateRoot ('Run-' + (Get-Date -Format 'HHmmssfff') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $stagingRoot = Join-Path $runRoot 'staging'
    $manifestPath = Join-Path $runRoot 'manifest.json'
    $records = @(Get-DestinationRecords -Root $source -Files $files)

    if ($Preview) {
        $records | Select-Object RelativeSourcePath, DestinationName, SourceLength | Format-Table -AutoSize
        return
    }

    try {
        New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
        foreach ($record in $records) {
            $record.SourceHash = (Get-FileHash -LiteralPath $record.SourcePath -Algorithm SHA256).Hash
            $destination = Join-Path $stagingRoot $record.DestinationName
            Copy-Item -LiteralPath $record.SourcePath -Destination $destination -Force:$false -ErrorAction Stop
            $record.DestinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            if ($record.SourceHash -ne $record.DestinationHash) {
                throw "Hash mismatch after copying $($record.SourcePath)"
            }
            $record.Status = 'StagedAndVerified'
        }

        $finalRoot = $runRoot
        foreach ($record in $records) {
            Move-Item -LiteralPath (Join-Path $stagingRoot $record.DestinationName) -Destination (Join-Path $finalRoot $record.DestinationName) -Force:$false
            $finalHash = (Get-FileHash -LiteralPath (Join-Path $finalRoot $record.DestinationName) -Algorithm SHA256).Hash
            if ($record.SourceHash -ne $finalHash) {
                throw "Hash mismatch after finalizing $($record.DestinationName)"
            }
            $record.DestinationHash = $finalHash
            $record.Status = 'FinalizedAndVerified'
        }
        Remove-Item -LiteralPath $stagingRoot -Force -ErrorAction SilentlyContinue

        foreach ($record in $records) {
            if (-not (Test-Path -LiteralPath $record.SourcePath -PathType Leaf)) {
                throw "Source disappeared before deletion: $($record.SourcePath)"
            }
            $current = Get-FileHash -LiteralPath $record.SourcePath -Algorithm SHA256
            if ($current.Hash -ne $record.SourceHash) {
                throw "Source changed after copying: $($record.SourcePath)"
            }
        }

        foreach ($record in $records) {
            Remove-Item -LiteralPath $record.SourcePath -Force -ErrorAction Stop
            $record.Status = 'Deleted'
        }

        [pscustomobject]@{
            SourceRoot = $source
            ArchiveRun = $runRoot
            CompletedAt = (Get-Date).ToString('o')
            Files = @($records)
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        Write-Host "Archived and deleted $($records.Count) file(s) to $runRoot"
    }
    catch {
        [pscustomobject]@{
            SourceRoot = $source
            ArchiveRun = $runRoot
            FailedAt = (Get-Date).ToString('o')
            Error = $_.Exception.Message
            Files = @($records)
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction SilentlyContinue
        throw
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ([string]::IsNullOrWhiteSpace($DriveRoot)) {
            throw 'DriveRoot is required.'
        }
        Invoke-Archive -SourceRoot $DriveRoot -SettingsPath $ConfigPath -Preview:$DryRun
        exit 0
    }
    catch {
        Write-Error $_
        exit 1
    }
}
