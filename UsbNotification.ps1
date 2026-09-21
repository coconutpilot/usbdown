function New-ArchiveNotificationXml {
    param([string] $DriveRoot)

    $safeDriveRoot = [System.Security.SecurityElement]::Escape($DriveRoot)
    return '<toast scenario="reminder"><visual><binding template="ToastText02"><text id="1">USB media archive complete</text><text id="2">Media from {0} was archived successfully.</text></binding></visual><actions><action content="Acknowledge" arguments="acknowledge" activationType="system"/></actions></toast>' -f $safeDriveRoot
}

function Show-ArchiveNotification {
    param(
        [string] $DriveRoot,
        [scriptblock] $NotificationFactory = {
            Add-Type -AssemblyName System.Runtime.WindowsRuntime
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
            [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

            $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            $xml.LoadXml((New-ArchiveNotificationXml $DriveRoot))
            $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
            $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Microsoft.WindowsPowerShell_8wekyb3d8bbwe!WindowsPowerShell')
            return [pscustomobject]@{
                Notifier = $notifier
                Toast = $toast
            }
        }
    )

    try {
        $notification = & $NotificationFactory
        $notification.Notifier.Show($notification.Toast)
        return $true
    }
    catch {
        Write-Log "Unable to display archive notification: $($_.Exception.Message)" 'WARN'
        return $false
    }
}
