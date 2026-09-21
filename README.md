# USB Media Archive

This Windows PowerShell 5.1 project watches for inserted USB volumes, copies configured media from their `DCIM` directory into a date-based archive, gives each file a sequential name, verifies SHA-256 hashes, deletes the source files only after verification succeeds, and ejects the USB device with a distinct notification sound after a successful copy. USB volumes without a `DCIM` directory, empty media directories, previews, and failed runs are left connected.

## Setup

Run PowerShell as the target Windows user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\setup.ps1 -ArchiveRoot 'c:\vids\raw'
```

Setup registers a per-user logon task named `USB Media Archive Watcher`. The archive root and media extension list are defined directly in the scripts.

The watcher writes timestamped `INFO`, `WARN`, and `ERROR` entries for startup, WMI registration, USB detection, archive success or failure, and notification failures to `<ArchiveRoot>\usbdown.log`:

```powershell
Get-Content "D:\UsbArchive\usbdown.log" -Tail 100 -Wait
```

Useful commands:

```powershell
.\setup.ps1 -Status
.\setup.ps1 -Uninstall
```

After setup, start the task immediately without waiting for the next logon:

```powershell
Start-ScheduledTask -TaskName 'USB Media Archive Watcher'
```

The archive root can be supplied to setup or manual runs with `-ArchiveRoot`. Environment variables such as `%USERPROFILE%` are expanded at runtime. The default is `c:\vids\raw`.

## Archive layout

Each insertion creates a unique run beneath the current date:

```text
D:\UsbArchive\2026-09-19\Run-142501123-a1b2c3d4\
  000001.jpg
  000002.mp4
  manifest.json
```

Files are sorted by their relative source path and renamed with six-digit sequential basenames. Extensions are preserved. `.srt` files are treated as optional sidecars: they are copied only when an `.mp4` with the same basename is in the same directory, and both files receive the same archive basename, such as `000001.mp4` and `000001.srt`. The extension allowlist is defined in `Archive-Media.ps1`.

## Safety behavior

The worker copies files to staging, hashes both source and destination, finalizes the archive, hashes the finalized files again, and rechecks the source hashes immediately before deletion. Any copy, hash, source-change, unplug, or permission failure stops the run and leaves source files in place. The run directory contains a failure manifest for diagnosis.

The archive root must be on a different volume from the inserted USB drive. The watcher checks the disk bus type and ignores non-USB volumes. It does not use `robocopy /MOVE`, `/MOV`, `/MIR`, or `/PURGE`.

A deletion failure after earlier files have already been deleted cannot restore those files; use a disposable test drive before enabling automatic deletion.

## Manual and dry-run operation

A manual preview validates the configured file selection and numbering without copying or deleting:

```powershell
.\Archive-Media.ps1 -DriveRoot 'E:\' -DryRun
```

A real manual run uses the same worker command without `-DryRun`. The source must be a mounted USB disk and the archive destination must not be on that disk.

## Testing

The Pester tests cover deterministic media selection and sequential naming without requiring hardware:

```powershell
Invoke-Pester .\Tests
```

The notification tests include a real Windows toast integration test. Run them from the logged-in desktop session to see the persistent archive reminder and its `Acknowledge` action.

For an integration test, use a disposable USB drive containing a `DCIM` directory with known media and non-media files, plus media outside `DCIM`. Confirm that only `DCIM` media is archived, along with the date/run layout, manifest hashes, sequential names, source deletion, and USB ejection. Also test a drive without `DCIM`; it should be skipped and remain connected. Then test a failure case by removing write permission from the archive destination or disconnecting the drive during a run; source files should remain and the device should not be ejected when verification cannot complete.

To create deterministic fake media on a disposable USB drive, run:

```powershell
.\Tests\New-TestUsbMedia.ps1 -DriveRoot 'E:\' -Count 3
```

The helper creates paired `.mp4` and `.srt` files under `DCIM`. The `.mp4` files are text fixtures, not playable video, and the helper does not archive, delete, or eject the drive.
