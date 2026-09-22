class TestNotificationIcon {
    [bool] $Shown

    [void] Show([object] $Toast) {
        $this.Shown = $true
    }
}

Describe 'Archive notification' {
    BeforeEach {
        $script:notificationIcon = [TestNotificationIcon]::new()
        $script:loggedMessage = $null
        function Write-Log {
            param([string] $Message, [string] $Level)
            $script:loggedMessage = "$Level $Message"
        }
        . $PSScriptRoot\..\Archive-Media.ps1
    }

    It 'submits a success toast notification' {
        $toastXml = New-ArchiveNotificationXml 'E:\'
        $toastXml | Should Match '<toast scenario="default">'
        $toastXml | Should Match 'content="Acknowledge"'
        $toastXml | Should Match 'arguments="acknowledge"'

        Show-ArchiveNotification -DriveRoot 'E:\' -NotificationFactory {
            return [pscustomobject]@{
                Notifier = $script:notificationIcon
                Toast = 'success toast'
            }
        }

        $script:notificationIcon.Shown | Should Be $true
        $script:loggedMessage | Should Be $null
    }

    It 'creates a reminder toast for an archive in progress' {
        $toastXml = New-ArchiveProgressNotificationXml 'DJI RC 2'

        $toastXml | Should Match '<toast scenario="reminder" duration="long">'
        $toastXml | Should Match 'duration="long"'
        $toastXml | Should Match 'Archiving media from DJI RC 2.'
        $toastXml | Should Match 'content="Dismiss"'
    }

    It 'creates a real Windows toast notification' {
        $created = Show-ArchiveNotification -DriveRoot 'E:\'

        $created | Should Be $true
    }
}