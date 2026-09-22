[CmdletBinding()]
param(
    [string] $DriveRoot,

    [string] $MtpPath,

    [string] $MtpName = 'MTP device',

    [string] $ArchiveRoot = (Join-Path $env:USERPROFILE 'Pictures\UsbArchive'),

    [switch] $DryRun
)

Set-StrictMode -Version 5.1
$ErrorActionPreference = 'Stop'
$MediaExtensions = @(
    '.jpg', '.jpeg', '.png', '.gif', '.heic', '.tif', '.tiff', '.webp',
    '.mp4', '.srt', '.mov', '.m4v', '.avi', '.mkv', '.mts', '.m2ts',
    '.mp3', '.wav', '.m4a', '.flac', '.aac', '.ogg'
)

function Normalize-DriveRoot {
    param([string] $Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.EndsWith('\')) {
        $resolved += '\'
    }
    return $resolved
}

function Get-UsbMediaRoot {
    param([string] $DriveRoot)

    $mediaRoot = Join-Path (Normalize-DriveRoot $DriveRoot) 'DCIM'
    if (-not (Test-Path -LiteralPath $mediaRoot -PathType Container)) {
        return $null
    }
    return (Normalize-DriveRoot $mediaRoot)
}

function Join-MtpRelativePath {
    param(
        [string] $BasePath,
        [string] $ChildPath
    )

    if ([string]::IsNullOrWhiteSpace($BasePath)) { return $ChildPath }
    return Join-Path $BasePath $ChildPath
}

function Get-MtpRootDcimFolders {
    param([object] $DeviceRoot)

    $dcimFolders = New-Object System.Collections.Generic.List[object]
    foreach ($rootItem in @($DeviceRoot.Items())) {
        if (-not $rootItem.IsFolder) { continue }

        $rootName = [string]$rootItem.Name
        $rootFolder = $rootItem.GetFolder()
        foreach ($item in @($rootFolder.Items())) {
            if ($item.IsFolder -and [string]$item.Name -ieq 'DCIM') {
                $dcimFolders.Add([pscustomobject]@{
                    Folder = $item.GetFolder()
                    RelativePath = Join-MtpRelativePath $rootName 'DCIM'
                }) | Out-Null
            }
        }
    }
    return $dcimFolders.ToArray()
}

function Get-MtpItemExtension {
    param(
        [object] $Item,
        [string[]] $Extensions
    )

    foreach ($candidate in @([string]$Item.Name, [string]$Item.Path)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $extension = [IO.Path]::GetExtension($candidate)
        if (-not [string]::IsNullOrWhiteSpace($extension)) {
            return $extension.ToLowerInvariant()
        }
    }

    foreach ($propertyName in @(
        'System.FileExtension',
        'System.Video.FileExtension',
        'System.Photo.FileExtension',
        'System.Music.FileExtension'
    )) {
        try {
            $propertyValue = [string]$Item.ExtendedProperty($propertyName)
            if (-not [string]::IsNullOrWhiteSpace($propertyValue)) {
                $extension = [IO.Path]::GetExtension($propertyValue)
                if (-not [string]::IsNullOrWhiteSpace($extension)) {
                    return $extension.ToLowerInvariant()
                }
            }
        }
        catch {
            continue
        }
    }

    $itemType = ''
    if ($null -ne $Item.PSObject.Properties['Type']) {
        $itemType = [string]$Item.Type
    }
    foreach ($extension in $Extensions) {
        $extensionName = $extension.TrimStart('.')
        if ($itemType -match ("(?i)(^|[^a-z]){0}([^a-z]|$)" -f [regex]::Escape($extensionName))) {
            return $extension.ToLowerInvariant()
        }
    }
    return ''
}

function Add-MtpFiles {
    param(
        [object] $Folder,
        [string] $RelativePath,
        [string[]] $Extensions
    )

    $files = New-Object System.Collections.Generic.List[object]
    $items = @($Folder.Items())
    Write-Host "Scanning MTP folder: $RelativePath ($($items.Count) item(s))"
    foreach ($mediaItem in $items) {
        $itemName = [string]$mediaItem.Name
        $itemPath = [string]$mediaItem.Path
        $itemType = ''
        if ($null -ne $mediaItem.PSObject.Properties['Type']) {
            $itemType = [string]$mediaItem.Type
        }
        $itemExtension = Get-MtpItemExtension -Item $mediaItem -Extensions $Extensions
        Write-Host "MTP item: Name=$itemName Path=$itemPath Type=$itemType IsFolder=$($mediaItem.IsFolder) Extension=$itemExtension"
        if ($mediaItem.IsFolder) {
            $childPath = Join-MtpRelativePath $RelativePath $itemName
            Write-Host "Descending into MTP folder: $childPath"
            foreach ($childFile in @(Add-MtpFiles -Folder $mediaItem.GetFolder() -RelativePath $childPath -Extensions $Extensions)) {
                $files.Add($childFile) | Out-Null
            }
        }
        elseif ($Extensions -contains $itemExtension) {
            $relativePath = Join-MtpRelativePath $RelativePath $itemName
            $files.Add([pscustomobject]@{
                Item = $mediaItem
                RelativePath = $relativePath
                Extension = $itemExtension
            }) | Out-Null
            Write-Host "MTP media file accepted: $relativePath"
        }
        else {
            Write-Host "MTP item skipped: unsupported extension $itemExtension"
        }
    }
    return $files.ToArray()
}

function Get-MtpMediaFiles {
    param(
        [string] $DevicePath,
        [string] $MtpName = 'MTP device'
    )

    if ([string]::IsNullOrWhiteSpace($DevicePath)) {
        throw 'MTP device path is required.'
    }

    Write-Host "Scanning MTP device: $MtpName ($DevicePath)"
    $shell = New-Object -ComObject Shell.Application
    try {
        $device = $shell.Namespace($DevicePath)
        if ($null -eq $device) {
            throw "Unable to access MTP device: $DevicePath"
        }

        $files = New-Object System.Collections.Generic.List[object]
        $dcimFolders = @(Get-MtpRootDcimFolders $device)
        Write-Host "MTP DCIM folders found: $($dcimFolders.Count)"
        foreach ($dcim in $dcimFolders) {
            Write-Host "MTP DCIM folder found: $($dcim.RelativePath)"
            foreach ($file in @(Add-MtpFiles -Folder $dcim.Folder -RelativePath $dcim.RelativePath -Extensions $MediaExtensions)) {
                $files.Add($file) | Out-Null
            }
        }

        Write-Host "MTP files detail: $($files | Out-String -Width 4096)"
        return @($files | Sort-Object { $_.RelativePath.ToLowerInvariant() })
    }
    finally {
        if ($null -ne $shell) {
            [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        }
    }
}

function Get-MtpDestinationRecords {
    param([object[]] $Files)

    $records = New-Object System.Collections.Generic.List[object]
    $pairNames = @{}
    $nextIndex = 1
    foreach ($file in $Files) {
        $relativePath = [string]$file.RelativePath
        $pairKey = [IO.Path]::ChangeExtension($relativePath, $null).ToLowerInvariant()
        $extension = ''
        if ($null -ne $file.PSObject.Properties['Extension']) {
            $extension = [string]$file.Extension
        }
        if ([string]::IsNullOrWhiteSpace($extension)) {
            $extension = [IO.Path]::GetExtension($relativePath)
        }
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
            Item = $file.Item
            SourcePath = [string]$file.Item.Path
            RelativeSourcePath = $relativePath
            DestinationName = $destinationName
            SourceLength = 0
            SourceHash = $null
            DestinationHash = $null
            Status = 'Discovered'
        })
    }
    return $records.ToArray()
}

function Copy-MtpItem {
    param(
        [object] $Item,
        [string] $Destination,
        [int] $TimeoutSeconds = 300
    )

    $destinationFolderPath = Split-Path -Parent $Destination
    $destinationName = Split-Path -Leaf $Destination
    $existingFiles = @(
        Get-ChildItem -LiteralPath $destinationFolderPath -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    )
    $shell = New-Object -ComObject Shell.Application
    try {
        $folder = $shell.Namespace($destinationFolderPath)
        if ($null -eq $folder) {
            throw "Unable to access staging directory: $destinationFolderPath"
        }
        try {
            $folder.CopyHere($Item, 20)
        }
        catch {
            Write-Host "Copy-MTP Shell CopyHere failed: $($_.Exception.Message)"
            throw
        }
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $pollCount = 0
        do {
            $pollCount++
            $copied = Join-Path $destinationFolderPath $destinationName
            $exists = Test-Path -LiteralPath $copied -PathType Leaf
            if ($exists) {
                return $copied
            }

            $newFiles = @(Get-ChildItem -LiteralPath $destinationFolderPath -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $existingFiles -notcontains $_.FullName })
            if ($newFiles.Count -gt 0) {
                $copied = $newFiles[0].FullName
                if ($copied -ne $Destination) {
                    Move-Item -LiteralPath $copied -Destination $Destination -Force:$false -ErrorAction Stop
                }
                if (Test-Path -LiteralPath $Destination -PathType Leaf) {
                    return $Destination
                }
            }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $deadline)
        Write-Host "Copy-MTP timeout: Item=$($Item.Name) Destination=$Destination Polls=$pollCount"
        throw "Timed out copying MTP item: $($Item.Name)"
    }
    finally {
        if ($null -ne $shell) {
            [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        }
    }
}

function Remove-MtpItem {
    param(
        [object] $Item,
        [int] $TimeoutSeconds = 60
    )

    $Item.InvokeVerb('Delete')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            if ($null -eq $Item.ParentFolder.ParseName($Item.Name)) { return }
        }
        catch {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "Timed out deleting MTP item: $($Item.Name)"
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

function Eject-UsbDrive {
    param([string] $DriveRoot)

    $source = Normalize-DriveRoot $DriveRoot
    $shell = $null
    $shell = New-Object -ComObject Shell.Application
    try {
        $drive = $shell.Namespace($source)
        if ($null -eq $drive -or $null -eq $drive.Self) {
            throw "Unable to access the USB drive for ejection: $source"
        }
        $drive.Self.InvokeVerb('Eject')
    }
    finally {
        if ($null -ne $shell) {
            [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        }
    }
}

function Invoke-MtpArchive {
    param(
        [string] $MtpPath,
        [string] $MtpName = 'MTP device',
        [string] $ArchiveRoot,
        [switch] $Preview,
        [ref] $Completed
    )

    $archiveRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ArchiveRoot))
    Write-Host "Starting MTP archive: $MtpName"
    $files = @(Get-MtpMediaFiles -DevicePath $MtpPath -MtpName $MtpName)
    if ($files.Count -eq 0) {
        Write-Host "No configured media files found on MTP device $MtpName ($MtpPath)"
        return
    }

    $dateRoot = Join-Path $archiveRoot (Get-Date -Format 'yyyy-MM-dd')
    $runRoot = Join-Path $dateRoot ('Run-' + (Get-Date -Format 'HHmmssfff') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $stagingRoot = Join-Path $runRoot 'staging'
    $manifestPath = Join-Path $runRoot 'manifest.json'
    $records = @(Get-MtpDestinationRecords $files)

    if ($Preview) {
        $records | Select-Object RelativeSourcePath, DestinationName | Format-Table -AutoSize
        return
    }

    try {
        New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
        foreach ($record in $records) {
            $destination = Join-Path $stagingRoot $record.DestinationName
            $copied = Copy-MtpItem -Item $record.Item -Destination $destination
            $record.DestinationHash = (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash
            $record.Status = 'StagedAndVerified'
        }

        foreach ($record in $records) {
            Move-Item -LiteralPath (Join-Path $stagingRoot $record.DestinationName) -Destination (Join-Path $runRoot $record.DestinationName) -Force:$false
            $record.DestinationHash = (Get-FileHash -LiteralPath (Join-Path $runRoot $record.DestinationName) -Algorithm SHA256).Hash
            $record.Status = 'FinalizedAndVerified'
        }
        Remove-Item -LiteralPath $stagingRoot -Force -ErrorAction SilentlyContinue

        foreach ($record in $records) {
            if (-not (Test-Path -LiteralPath (Join-Path $runRoot $record.DestinationName) -PathType Leaf)) {
                throw "Destination disappeared before deletion: $($record.DestinationName)"
            }
        }
        foreach ($record in $records) {
            Remove-MtpItem -Item $record.Item
            $record.Status = 'Deleted'
        }

        [pscustomobject]@{
            SourceRoot = $MtpPath
            ArchiveRun = $runRoot
            CompletedAt = (Get-Date).ToString('o')
            Files = @($records)
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        if ($null -ne $Completed) {
            $Completed.Value = $true
        }
        Write-Host "Archived and deleted $($records.Count) MTP file(s) to $runRoot"
    }
    catch {
        [pscustomobject]@{
            SourceRoot = $MtpPath
            ArchiveRun = $runRoot
            FailedAt = (Get-Date).ToString('o')
            Error = $_.Exception.Message
            Files = @($records)
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction SilentlyContinue
        throw
    }
}

function Invoke-Archive {
    param(
        [string] $SourceRoot,
        [string] $ArchiveRoot,
        [switch] $Preview,
        [ref] $Completed
    )

    $source = Normalize-DriveRoot $SourceRoot
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Source drive is not available: $source"
    }

    Get-UsbDiskForDrive $source | Out-Null
    $archiveRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ArchiveRoot))
    Test-DestinationIsSafe $source $archiveRoot

    $mediaRoot = Get-UsbMediaRoot $source
    if ($null -eq $mediaRoot) {
        Write-Host "No DCIM directory found on $source"
        return
    }

    $files = @(Get-MediaFiles -Root $mediaRoot -Extensions $MediaExtensions)
    if ($files.Count -eq 0) {
        Write-Host "No configured media files found in $mediaRoot"
        return
    }

    $dateRoot = Join-Path $archiveRoot (Get-Date -Format 'yyyy-MM-dd')
    $runRoot = Join-Path $dateRoot ('Run-' + (Get-Date -Format 'HHmmssfff') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $stagingRoot = Join-Path $runRoot 'staging'
    $manifestPath = Join-Path $runRoot 'manifest.json'
    $records = @(Get-DestinationRecords -Root $mediaRoot -Files $files)

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
            SourceRoot = $mediaRoot
            ArchiveRun = $runRoot
            CompletedAt = (Get-Date).ToString('o')
            Files = @($records)
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        if ($null -ne $Completed) {
            $Completed.Value = $true
        }
        Write-Host "Archived and deleted $($records.Count) file(s) to $runRoot"
    }
    catch {
        [pscustomobject]@{
            SourceRoot = $mediaRoot
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
        if ([string]::IsNullOrWhiteSpace($DriveRoot) -and [string]::IsNullOrWhiteSpace($MtpPath)) {
            throw 'DriveRoot or MtpPath is required.'
        }
        $completed = $false
        if (-not [string]::IsNullOrWhiteSpace($MtpPath)) {
            Invoke-MtpArchive -MtpPath $MtpPath -MtpName $MtpName -ArchiveRoot $ArchiveRoot -Preview:$DryRun -Completed ([ref]$completed)
        }
        else {
            try {
                Invoke-Archive -SourceRoot $DriveRoot -ArchiveRoot $ArchiveRoot -Preview:$DryRun -Completed ([ref]$completed)
            }
            finally {
                if ($completed) {
                    Eject-UsbDrive $DriveRoot
                }
            }
        }
        exit 0
    }
    catch {
        Write-Error $_
        exit 1
    }
}
