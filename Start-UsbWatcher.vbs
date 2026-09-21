Option Explicit

Dim shell, scriptDirectory, archiveRoot, powerShell, watcher, command
Set shell = CreateObject("WScript.Shell")

If WScript.Arguments.Count < 2 Then WScript.Quit 2

scriptDirectory = WScript.Arguments(0)
archiveRoot = WScript.Arguments(1)
powerShell = shell.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
watcher = scriptDirectory & "\UsbWatcher.ps1"
command = Quote(powerShell) & " -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File " & Quote(watcher) & " -ArchiveRoot " & Quote(archiveRoot)
shell.Run command, 0, False

Function Quote(value)
    Quote = Chr(34) & value & Chr(34)
End Function