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

    It 'rejects an archive root on the source volume' {
        { Test-DestinationIsSafe -SourceRoot 'E:\' -ArchiveRoot 'E:\Archive' } | Should Throw
    }
}
