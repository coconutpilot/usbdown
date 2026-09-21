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
        . $PSScriptRoot\..\UsbNotification.ps1
    }

    It 'submits a success toast notification' {
        $toastXml = New-ArchiveNotificationXml 'E:\'
        $toastXml | Should Match '<toast scenario="reminder">'
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

    It 'creates a real Windows toast notification' {
        $created = Show-ArchiveNotification -DriveRoot 'E:\'

        $created | Should Be $true
    }
}