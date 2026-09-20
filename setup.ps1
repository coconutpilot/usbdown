[CmdletBinding()]
param(
    [string] $ArchiveRoot = (Join-Path $env:USERPROFILE 'Pictures\UsbArchive'),
    [string] $ConfigPath,
    [switch] $Uninstall,
    [switch] $Status
)

Set-StrictMode -Version 5.1
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
$taskName = 'USB Media Archive Watcher'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task: $taskName"
    exit 0
}

if ($Status) {
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Get-ScheduledTaskInfo
    exit 0
}

$archiveRoot = [Environment]::ExpandEnvironmentVariables($ArchiveRoot)
New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
$logRoot = Join-Path $env:LOCALAPPDATA 'UsbMediaArchive'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$config = [ordered]@{
    ArchiveRoot = $archiveRoot
    MediaExtensions = @(
        '.jpg', '.jpeg', '.png', '.gif', '.heic', '.tif', '.tiff', '.webp',
        '.mp4', '.srt', '.mov', '.m4v', '.avi', '.mkv', '.mts', '.m2ts',
        '.mp3', '.wav', '.m4a', '.flac', '.aac', '.ogg'
    )
}
$config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

$powerShell = Join-Path $PSHOME 'powershell.exe'
$watcher = Join-Path $PSScriptRoot 'UsbWatcher.ps1'
$logPath = Join-Path $logRoot 'usb-archive.log'
$arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -LogPath "{2}"' -f $watcher, $ConfigPath, $logPath
$action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Archives media from inserted USB drives.' -Force | Out-Null
Write-Host "Configured archive root: $archiveRoot"
Write-Host "Registered per-user logon task: $taskName"
Write-Host "Watcher log: $logPath"
