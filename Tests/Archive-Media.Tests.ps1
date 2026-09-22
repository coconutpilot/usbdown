. $PSScriptRoot\..\Archive-Media.ps1

Describe 'Archive media helpers' {
    It 'limits media selection to the DCIM directory' {
        $root = Join-Path $TestDrive 'dcim-source'
        New-Item -ItemType Directory -Path (Join-Path $root 'DCIM') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'outside.mp4') -Value 'ignore'
        Set-Content -LiteralPath (Join-Path $root 'DCIM\inside.mp4') -Value 'archive'

        $mediaRoot = Get-UsbMediaRoot $root

        $mediaRoot | Should Be (Normalize-DriveRoot (Join-Path $root 'DCIM'))
        @(Get-MediaFiles -Root $mediaRoot -Extensions @('.mp4')).Count | Should Be 1
        (Get-MediaFiles -Root $mediaRoot -Extensions @('.mp4')).Name | Should Be 'inside.mp4'
    }

    It 'does nothing when DCIM is missing' {
        Get-UsbMediaRoot (Join-Path $TestDrive 'missing-source') | Should Be $null
    }

    It 'rejects an empty MTP device path' {
        { Get-MtpMediaFiles '' } | Should Throw 'MTP device path is required.'
    }

    It 'joins MTP paths when the relative root is empty' {
        Join-MtpRelativePath '' 'DCIM' | Should Be 'DCIM'
        Join-MtpRelativePath '100MEDIA' 'clip.mp4' | Should Be '100MEDIA\clip.mp4'
    }

    It 'finds DCIM under each MTP root item' {
        $internalDcim = [pscustomobject]@{ Name = 'DCIM'; IsFolder = $true }
        Add-Member -InputObject $internalDcim -MemberType ScriptMethod -Name GetFolder -Value { return 'internal-dcim' }
        $internalStorage = [pscustomobject]@{ Name = 'Internal storage'; IsFolder = $true; Children = @($internalDcim) }
        Add-Member -InputObject $internalStorage -MemberType ScriptMethod -Name GetFolder -Value { return $this }
        Add-Member -InputObject $internalStorage -MemberType ScriptMethod -Name Items -Value { return $this.Children }

        $sdDcim = [pscustomobject]@{ Name = 'DCIM'; IsFolder = $true }
        Add-Member -InputObject $sdDcim -MemberType ScriptMethod -Name GetFolder -Value { return 'sd-dcim' }
        $sdCard = [pscustomobject]@{ Name = 'SD card'; IsFolder = $true; Children = @($sdDcim) }
        Add-Member -InputObject $sdCard -MemberType ScriptMethod -Name GetFolder -Value { return $this }
        Add-Member -InputObject $sdCard -MemberType ScriptMethod -Name Items -Value { return $this.Children }

        $deviceRoot = [pscustomobject]@{ Children = @($internalStorage, $sdCard) }
        Add-Member -InputObject $deviceRoot -MemberType ScriptMethod -Name Items -Value { return $this.Children }

        $folders = @(Get-MtpRootDcimFolders $deviceRoot)

        $folders.Count | Should Be 2
        $folders[0].RelativePath | Should Be 'Internal storage\DCIM'
        $folders[0].Folder | Should Be 'internal-dcim'
        $folders[1].RelativePath | Should Be 'SD card\DCIM'
        $folders[1].Folder | Should Be 'sd-dcim'
    }

    It 'returns discovered files from Add-MtpFiles' {
        $mediaItem = [pscustomobject]@{ Name = 'clip.mp4'; IsFolder = $false; Path = 'mtp:\clip.mp4' }
        $folder = [pscustomobject]@{ Children = @($mediaItem) }
        Add-Member -InputObject $folder -MemberType ScriptMethod -Name Items -Value { return $this.Children }

        $files = @(Add-MtpFiles -Folder $folder -RelativePath 'DCIM' -Extensions @('.mp4'))

        $files.Count | Should Be 1
        $files[0].RelativePath | Should Be 'DCIM\clip.mp4'
        $files[0].Item | Should Be $mediaItem
        $files[0].Extension | Should Be '.mp4'
    }

    It 'preserves a detected MTP extension when the display name has none' {
        $mediaItem = [pscustomobject]@{ Name = 'DJI_clip'; Path = 'mtp:\clip'; Type = 'MP4 Video'; IsFolder = $false }
        $folder = [pscustomobject]@{ Children = @($mediaItem) }
        Add-Member -InputObject $folder -MemberType ScriptMethod -Name Items -Value { return $this.Children }

        $files = @(Add-MtpFiles -Folder $folder -RelativePath 'DCIM' -Extensions @('.mp4'))
        $records = @(Get-MtpDestinationRecords $files)

        $records[0].DestinationName | Should Be '000001.mp4'
    }

    It 'gets an MTP extension from the item path when the name has none' {
        $mediaItem = [pscustomobject]@{ Name = 'clip'; Path = 'mtp:\clip.mp4' }

        Get-MtpItemExtension -Item $mediaItem -Extensions @('.mp4') | Should Be '.mp4'
    }

    It 'gets an MTP extension from the item type when name and path have none' {
        $mediaItem = [pscustomobject]@{ Name = 'DJI_20260913124600_0003_D'; Path = 'mtp:\clip'; Type = 'MP4 Video' }

        Get-MtpItemExtension -Item $mediaItem -Extensions @('.mp4') | Should Be '.mp4'
    }

    It 'gets an MTP extension from Shell extended properties' {
        $mediaItem = [pscustomobject]@{ Name = 'DJI_20260913124600_0003_D'; Path = 'mtp:\clip' }
        Add-Member -InputObject $mediaItem -MemberType ScriptMethod -Name ExtendedProperty -Value {
            param([string] $PropertyName)
            if ($PropertyName -eq 'System.Video.FileExtension') { return '.MP4' }
            return $null
        }

        Get-MtpItemExtension -Item $mediaItem -Extensions @('.mp4') | Should Be '.mp4'
    }

    It 'normalizes extensions and filters media deterministically' {
        $root = Join-Path $TestDrive 'source'
        New-Item -ItemType Directory -Path (Join-Path $root 'nested') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'z.txt') -Value 'ignore'
        Set-Content -LiteralPath (Join-Path $root 'nested\b.JPG') -Value 'second'
        Set-Content -LiteralPath (Join-Path $root 'a.mp4') -Value 'first'
        Set-Content -LiteralPath (Join-Path $root 'a.srt') -Value 'subtitle'
        Set-Content -LiteralPath (Join-Path $root 'orphan.srt') -Value 'ignore'

        $files = @(Get-MediaFiles -Root (Normalize-DriveRoot $root) -Extensions @('.jpg', '.mp4', '.srt'))

        $files.Count | Should Be 3
        $files[0].Name | Should Be 'a.mp4'
        $files[1].Name | Should Be 'a.srt'
        $files[2].Name | Should Be 'b.JPG'

        $records = @(Get-DestinationRecords -Root (Normalize-DriveRoot $root) -Files $files)
        [IO.Path]::GetFileNameWithoutExtension($records[0].DestinationName) | Should Be '000001'
        [IO.Path]::GetFileNameWithoutExtension($records[1].DestinationName) | Should Be '000001'
        $records[0].DestinationName | Should Be '000001.mp4'
        $records[1].DestinationName | Should Be '000001.srt'
    }

    It 'creates sequential names while preserving extensions' {
        Get-SequentialName -Index 1 -Extension '.jpg' | Should Be '000001.jpg'
        Get-SequentialName -Index 27 -Extension '.MP4' | Should Be '000027.MP4'
    }

    It 'creates paired destination names for MTP items' {
        $files = @(
            [pscustomobject]@{ Item = [pscustomobject]@{ Name = 'clip.mp4'; Path = 'mtp:\clip.mp4' }; RelativePath = 'DCIM\100MSDCF\clip.mp4' },
            [pscustomobject]@{ Item = [pscustomobject]@{ Name = 'clip.srt'; Path = 'mtp:\clip.srt' }; RelativePath = 'DCIM\100MSDCF\clip.srt' }
        )

        $records = @(Get-MtpDestinationRecords $files)

        $records[0].DestinationName | Should Be '000001.mp4'
        $records[1].DestinationName | Should Be '000001.srt'
    }

    It 'rejects an archive root on the source volume' {
        { Test-DestinationIsSafe -SourceRoot 'E:\' -ArchiveRoot 'E:\Archive' } | Should Throw
    }
}
