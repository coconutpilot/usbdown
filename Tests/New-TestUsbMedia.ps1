[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $DriveRoot,

    [ValidateRange(1, 100000)]
    [int] $Count = 3
)

Set-StrictMode -Version 5.1
$ErrorActionPreference = 'Stop'

function Normalize-DriveRoot {
    param([string] $Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.EndsWith('\')) {
        $resolved += '\'
    }
    return $resolved
}

$root = Normalize-DriveRoot $DriveRoot
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Drive root is not available: $root"
}

$driveLetter = ([IO.Path]::GetPathRoot($root)).TrimEnd(':\')
$partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
$disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
if ([string]$disk.BusType -ne 'USB') {
    throw "The target drive is not USB-backed: $root (BusType=$($disk.BusType))"
}

$dcimRoot = Join-Path $root 'DCIM'
New-Item -ItemType Directory -Path $dcimRoot -Force | Out-Null

for ($index = 1; $index -le $Count; $index++) {
    $name = 'TEST-{0:D3}' -f $index
    $videoPath = Join-Path $dcimRoot ($name + '.mp4')
    $subtitlePath = Join-Path $dcimRoot ($name + '.srt')

    @(
        'This is fake MP4 test data.'
        "File: $name.mp4"
        "Created: $((Get-Date).ToString('o'))"
    ) | Set-Content -LiteralPath $videoPath -Encoding UTF8

    @(
        '1'
        '00:00:00,000 --> 00:00:02,000'
        "Test subtitle for $name"
    ) | Set-Content -LiteralPath $subtitlePath -Encoding UTF8
}

Write-Host "Created $Count fake MP4/SRT pair(s) in $dcimRoot"
Write-Host 'The files are test data and are not playable video files.'
Write-Host 'No archive or eject operation was performed.'
