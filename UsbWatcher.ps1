[CmdletBinding()]
param(
    [string] $ArchiveRoot = 'c:\vids\raw',
    [string] $WorkerPath
)

Set-StrictMode -Version 5.1
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkerPath)) { $WorkerPath = Join-Path $PSScriptRoot 'Archive-Media.ps1' }
$LogPath = Join-Path $ArchiveRoot 'usbdown.log'

function Write-Log {
    param(
        [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO'
    )

    $directory = Split-Path -Parent $LogPath
    Write-Host $Message
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction SilentlyContinue | Out-Null
    Add-Content -LiteralPath $LogPath -Value ('{0} [{1}] {2}' -f (Get-Date -Format 's'), $Level, $Message) -ErrorAction SilentlyContinue
}

. $PSScriptRoot\Archive-Media.ps1

function ConvertTo-DriveRoot {
    param([string] $DriveName)

    if ([string]::IsNullOrWhiteSpace($DriveName)) { return $null }
    $root = $DriveName.Trim()
    if ($root -notmatch '^[A-Za-z]:\\?$') { return $null }
    return ($root.TrimEnd('\') + '\')
}

function Test-UsbDrive {
    param([string] $Root)

    try {
        $letter = ([IO.Path]::GetPathRoot($Root)).TrimEnd(':\')
        $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
        return ([string]$disk.BusType -eq 'USB')
    }
    catch {
        return $false
    }
}

function Wait-ForUsbDrive {
    param(
        [string] $Root,
        [int] $Attempts = 12,
        [int] $DelaySeconds = 2
    )

    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        if ((Test-Path -LiteralPath $Root -PathType Container) -and (Test-UsbDrive $Root)) {
            return $true
        }
        Start-Sleep -Seconds $DelaySeconds
    }
    return $false
}

function Test-MtpDeviceItem {
    param(
        [object] $Folder,
        [int] $Depth = 0
    )

    if ($Depth -gt 3) { return $false }
    foreach ($item in @($Folder.Items())) {
        if (-not $item.IsFolder) { continue }
        if ([string]$item.Name -ieq 'DCIM') { return $true }
        if (Test-MtpDeviceItem $item.GetFolder() ($Depth + 1)) { return $true }
    }
    return $false
}

function Get-MtpDevices {
    $shell = New-Object -ComObject Shell.Application
    try {
        $thisPc = $shell.Namespace(17)
        if ($null -eq $thisPc) { return @() }
        $devices = New-Object System.Collections.Generic.List[object]
        foreach ($item in @($thisPc.Items())) {
            $path = [string]$item.Path
            if ([string]::IsNullOrWhiteSpace($path)) {
                Write-Log "Skipping MTP device with no shell namespace path: $($item.Name)" 'WARN'
                continue
            }
            if (-not $item.IsFolder -or $path -notlike '::{*}') { continue }
            try {
                if (Test-MtpDeviceItem $item.GetFolder()) {
                    $devices.Add([pscustomobject]@{
                        Name = [string]$item.Name
                        Path = $path
                    })
                }
            }
            catch {
                Write-Log "Unable to inspect shell device $($item.Name): $($_.Exception.Message)" 'WARN'
            }
        }
        return $devices.ToArray()
    }
    finally {
        if ($null -ne $shell) {
            [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        }
    }
}

function Invoke-MtpDevice {
    param(
        [object] $Device,
        [string] $ArchiveRoot,
        [string] $WorkerPath
    )

    Write-Log "MTP device detected: $($Device.Name)"
    $workerMessage = "Running archive worker: powershell.exe -File $WorkerPath -MtpPath $($Device.Path) -MtpName $($Device.Name) -ArchiveRoot $ArchiveRoot"
    Write-Log $workerMessage
    & powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $WorkerPath -MtpPath $Device.Path -MtpName $Device.Name -ArchiveRoot $ArchiveRoot 2>&1 |
        ForEach-Object { Write-Log ([string]$_) }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "MTP archive failed for $($Device.Name) with exit code $LASTEXITCODE" 'ERROR'
    }
    else {
        Write-Log "MTP archive completed successfully for $($Device.Name)"
        Show-ArchiveNotification $Device.Name
    }
}

Write-Host "Log: $LogPath"
$query = "SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2"
$sourceIdentifier = 'UsbMediaArchive.VolumeArrival'
$seen = @{}
Write-Log "Starting watcher. ArchiveRoot=$ArchiveRoot Worker=$WorkerPath"
try {
    Register-WmiEvent -Query $query -SourceIdentifier $sourceIdentifier -ErrorAction Stop | Out-Null
    Write-Log 'WMI volume-arrival subscription registered.'
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}

try {
    while ($true) {
        foreach ($device in @(Get-MtpDevices)) {
            $key = ('MTP:' + $device.Path).ToUpperInvariant()
            if ($seen.ContainsKey($key) -and ((Get-Date) - $seen[$key]).TotalMinutes -lt 5) { continue }
            $seen[$key] = Get-Date
            try {
                Invoke-MtpDevice -Device $device -ArchiveRoot $ArchiveRoot -WorkerPath $WorkerPath
            }
            catch {
                Write-Log "MTP event processing failed: $($_.Exception.Message)" 'ERROR'
            }
        }

        $volumeEvent = Wait-Event -SourceIdentifier $sourceIdentifier -Timeout 5
        if ($null -eq $volumeEvent) { continue }

        try {
            $root = ConvertTo-DriveRoot $volumeEvent.SourceEventArgs.NewEvent.DriveName
            if ($null -eq $root) { continue }
            Write-Log "Volume arrival event received: $($volumeEvent.SourceEventArgs.NewEvent.DriveName)"
            $key = $root.ToUpperInvariant()
            if ($seen.ContainsKey($key) -and ((Get-Date) - $seen[$key]).TotalMinutes -lt 5) { continue }
            $seen[$key] = Get-Date

            if (-not (Wait-ForUsbDrive $root)) {
                Write-Log "USB drive was not ready: $root" 'WARN'
                continue
            }

            Write-Log "USB drive detected: $root"
            $workerMessage = "Running archive worker: powershell.exe -File $WorkerPath -DriveRoot $root -ArchiveRoot $ArchiveRoot"
            Write-Log $workerMessage
            & powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $WorkerPath -DriveRoot $root -ArchiveRoot $ArchiveRoot 2>&1 |
                ForEach-Object { Write-Log ([string]$_) }
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Archive failed for $root with exit code $LASTEXITCODE" 'ERROR'
            }
            else {
                Write-Log "Archive completed successfully for $root"
                Show-ArchiveNotification $root
            }
        }
        catch {
            Write-Log "USB event processing failed: $($_.Exception.Message)" 'ERROR'
        }
        finally {
            Remove-Event -EventIdentifier $volumeEvent.EventIdentifier -ErrorAction SilentlyContinue
        }
    }
}
finally {
    Unregister-Event -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue
    Get-Event -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
}
