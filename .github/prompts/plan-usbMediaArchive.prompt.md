## Plan: USB Media Archive Project

Build a Windows PowerShell project that detects USB insertions, archives common media into date-based folders, renames files sequentially, and deletes source files only after hash verification.

**Steps**
1. Create:
   - `Archive-Media.ps1`
   - `UsbWatcher.ps1`
   - `setup.ps1`
   - `README.md`
   - `Tests\`
2. Implement the archive worker:
   - Validate the drive is mounted and USB-backed.
   - Filter configurable image, video, and audio extensions.
   - Store files under `ArchiveRoot\YYYY-MM-DD\<unique-run>\`.
   - Rename files as `000001.jpg`, `000002.mp4`, etc.
   - Copy to staging and record SHA-256 hashes.
   - Verify destination hashes before deletion.
   - Recheck source hashes, then delete source files.
   - Preserve all source files if any step fails.
   - Support dry-run mode.
3. Implement the WMI watcher:
   - Monitor `Win32_VolumeChangeEvent`.
   - Detect arrival events and confirm the volume is USB-backed.
   - Retry until the drive is ready.
   - Deduplicate repeated insertion events.
   - Invoke the archive worker with the detected drive root.
4. Implement `setup.ps1`:
   - Configure the archive destination.
   - Configure the archive destination directly through the setup script.
   - Register a per-user logon scheduled task.
   - Configure restart-on-failure and working directory.
   - Provide status and uninstall options.
5. Add documentation and Pester tests covering filtering, naming, collisions, failed verification, unplugging, non-USB devices, and duplicate events.
6. Validate PowerShell parsing, tests, scheduled-task configuration, dry runs, and a disposable physical USB test.

**Key files**
- `c:\work\usbdown\Archive-Media.ps1`
- `c:\work\usbdown\UsbWatcher.ps1`
- `c:\work\usbdown\setup.ps1`
- `c:\work\usbdown\README.md`
- `c:\work\usbdown\Tests\`

**Decisions**
- Windows PowerShell 5.1 and built-in Windows tools only.
- Archive root supplied directly to the scripts.
- Common media extensions by default.
- Original file extensions preserved.
- Six-digit sequential filenames.
- Per-user logon watcher task.
- No cloud upload, GUI, encryption, or automatic cleanup of previous archives.
- Failed runs retain source files for diagnosis and safe retry.

The plan is saved in `/memories/session/plan.md` and is ready for implementation after approval.