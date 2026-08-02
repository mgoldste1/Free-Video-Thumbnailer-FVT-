param(
    [Parameter(Mandatory=$true)]
    [string]$InputFolder,

    [int]$Concurrency = 8,

    # CONFIG OPTIONS
    [int]$FrameWidth = 480,     # width of each frame
    [int]$GridX = 5,            # frames horizontally
    [int]$GridY = 4,            # frames vertically

    # User-facing JPEG quality (0–100)
    [int]$Quality = 76
)

# Helper to call thumbnails.ps1 for a given directory
function Invoke-Thumbnailer {
    param(
        [string]$Dir
    )
    & "$PSScriptRoot\thumbnails.ps1" -InputFolder $Dir -Concurrency $Concurrency -FrameWidth $FrameWidth -GridX $GridX -GridY $GridY -Quality $Quality
}

# Call for the root directory
Invoke-Thumbnailer -Dir $InputFolder

# Call for all subdirectories recursively
Get-ChildItem -Path $InputFolder -Directory -Recurse | ForEach-Object {
    Invoke-Thumbnailer -Dir $_.FullName
}
