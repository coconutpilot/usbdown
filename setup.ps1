[CmdletBinding()]
param(
    [string] $ArchiveRoot = (Join-Path $env:USERPROFILE 'Pictures\UsbArchive'),
    [switch] $Uninstall,
    [switch] $Status
)

Set-StrictMode -Version 5.1
$ErrorActionPreference = 'Stop'
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
$launcher = Join-Path $PSScriptRoot 'Start-UsbWatcher.vbs'
$arguments = '"{0}" "{1}"' -f $PSScriptRoot, $archiveRoot
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}" {1}' -f $launcher, $arguments) -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -Hidden -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Archives media from inserted USB drives.' -Force | Out-Null
Write-Host "Configured archive root: $archiveRoot"
Write-Host "Registered per-user logon task: $taskName"
Write-Host "Watcher log: $(Join-Path $archiveRoot 'usbdown.log')"
