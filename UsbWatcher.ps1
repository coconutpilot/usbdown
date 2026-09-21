[CmdletBinding()]
param(
    [string] $ArchiveRoot = 'c:\vids\raw',
    [string] $WorkerPath,
    [string] $LogPath
)

Set-StrictMode -Version 5.1
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($WorkerPath)) { $WorkerPath = Join-Path $PSScriptRoot 'Archive-Media.ps1' }
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $ArchiveRoot, 'usbdown.log' }

function Write-Log {
    param(
        [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO'
    )

    $directory = Split-Path -Parent $LogPath
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction SilentlyContinue | Out-Null
    Add-Content -LiteralPath $LogPath -Value ('{0} [{1}] {2}' -f (Get-Date -Format 's'), $Level, $Message) -ErrorAction SilentlyContinue
}

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
Write-Host "USB media watcher is running. Log: $LogPath"

try {
    while ($true) {
        $event = Wait-Event -SourceIdentifier $sourceIdentifier -Timeout 5
        if ($null -eq $event) { continue }

        try {
            $root = ConvertTo-DriveRoot $event.SourceEventArgs.NewEvent.DriveName
            if ($null -eq $root) { continue }
            Write-Log "Volume arrival event received: $($event.SourceEventArgs.NewEvent.DriveName)"
            $key = $root.ToUpperInvariant()
            if ($seen.ContainsKey($key) -and ((Get-Date) - $seen[$key]).TotalMinutes -lt 5) { continue }
            $seen[$key] = Get-Date

            if (-not (Wait-ForUsbDrive $root)) {
                Write-Log "USB drive was not ready: $root" 'WARN'
                continue
            }

            Write-Log "USB drive detected: $root"
            Write-Host "USB drive detected: $root"
            $workerOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $WorkerPath -DriveRoot $root -ArchiveRoot $ArchiveRoot 2>&1)
            foreach ($line in $workerOutput) {
                Write-Log ([string]$line)
            }
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Archive failed for $root with exit code $LASTEXITCODE" 'ERROR'
            }
        }
        catch {
            Write-Log "USB event processing failed: $($_.Exception.Message)" 'ERROR'
        }
        finally {
            Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
        }
    }
}
finally {
    Unregister-Event -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue
    Get-Event -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
}
