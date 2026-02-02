param(
    [Parameter(Mandatory=$true)]
    [string]$InputFolder,

    [int]$Concurrency = 16,

    # CONFIG OPTIONS
    [int]$FrameWidth = 480,     # width of each frame
    [int]$GridX = 5,            # frames horizontally
    [int]$GridY = 7,            # frames vertically

    # User-facing JPEG quality (0–100)
    [int]$Quality = 90
)

# Map user quality (0–100) to ffmpeg JPEG q:v scale (1–5)
# 1 = best, 5 = decent, 9+ = trash
if ($Quality -ge 95) { $JpegQ = 1 }
elseif ($Quality -ge 85) { $JpegQ = 2 }
elseif ($Quality -ge 70) { $JpegQ = 3 }
elseif ($Quality -ge 50) { $JpegQ = 4 }
else { $JpegQ = 5 }

# Ensure tools exist
foreach ($tool in @("ffmpeg", "magick", "ffprobe")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required tool '$tool' not found in PATH."
    }
}

# Reliable video detection
$videos = Get-ChildItem -Path $InputFolder -File |
          Where-Object { $_.Extension.ToLower() -match 'mp4|mkv|mov|avi|wmv' }

if ($videos.Count -eq 0) {
    throw "No video files found in '$InputFolder'."
}

Write-Host "Found $($videos.Count) videos."

# Total frames needed
$TotalFrames = $GridX * $GridY

# Process videos in parallel
$videos | ForEach-Object -Parallel {

    try {

        $video = $_
        $base = [IO.Path]::GetFileNameWithoutExtension($video.Name)
        $outGrid = Join-Path $video.Directory "$base-grid.jpg"

        # Create temp folder
        $temp = Join-Path $env:TEMP ("thumbs_" + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $temp | Out-Null

        # Get metadata
        $ffprobeJson = ffprobe -v quiet -print_format json -show_format -show_streams $video.FullName
        $ffprobe = $ffprobeJson | ConvertFrom-Json

        $format = $ffprobe.format
        $stream = $ffprobe.streams | Where-Object { $_.codec_type -eq "video" }

        # Clean duration formatting (HH:MM:SS.s)
        $rawSeconds = [double]$format.duration
        $ts = [TimeSpan]::FromSeconds($rawSeconds)
        $durationFormatted = "{0:00}:{1:00}:{2:00}.{3}" -f `
            $ts.Hours, $ts.Minutes, $ts.Seconds, ([math]::Round($ts.Milliseconds / 100, 0))

        # Two-column metadata
        $leftCol = @(
            "File: $($video.Name)"
            "Size: $([math]::Round($video.Length / 1MB, 2)) MB"
            "Resolution: $($stream.width)x$($stream.height)"
        ) -join "`n"

        $rightCol = @(
            "Codec: $($stream.codec_name)"
            "Bitrate: $([math]::Round($format.bit_rate / 1000)) kbps"
            "Duration: $durationFormatted"
        ) -join "`n"

        # Extract evenly spaced frames
        $duration = [double]$format.duration
        $step = $duration / ($using:TotalFrames + 1)

        $frameList = @()

        for ($i = 0; $i -lt $using:TotalFrames; $i++) {

            $timestamp = ($i + 1) * $step
            $frameOut = Join-Path $temp ("frame_{0:D2}.jpg" -f $i)

            # Timestamp label
            $ts2 = [TimeSpan]::FromSeconds($timestamp)
            $tsLabel = "{0:00}:{1:00}:{2:00}" -f $ts2.Hours, $ts2.Minutes, $ts2.Seconds
            $safeLabel = $tsLabel.Replace(":", "\:")

            # Extract frame (fast seek)
            ffmpeg -y -ss $timestamp -noaccurate_seek -i $video.FullName `
                -vf "scale='min($using:FrameWidth,iw)':-1,
                     drawtext=text='$safeLabel':x=w-tw-10:y=h-th-10:
                     fontcolor=white:fontsize=18:
                     box=1:boxcolor=0x000000AA:boxborderw=5" `
                -q:v $using:JpegQ `
                -frames:v 1 $frameOut 2>$null

            # Retry once if needed
            if (-not (Test-Path $frameOut)) {
                ffmpeg -y -ss $timestamp -noaccurate_seek -i $video.FullName `
                    -vf "scale='min($using:FrameWidth,iw)':-1" `
                    -q:v $using:JpegQ `
                    -frames:v 1 $frameOut 2>$null
            }

            if (Test-Path $frameOut) {
                $frameList += $frameOut
            }
        }

        if ($frameList.Count -lt 1) {
            Write-Host "Skipping $($video.Name) — no frames extracted."
            return
        }

        # Build tile string safely
        $tile = "$using:GridX" + "x" + "$using:GridY"

        # Build montage
        $montageTemp = Join-Path $temp "montage_temp.jpg"

        magick montage @($frameList) `
            -tile $tile -geometry +2+2 `
            $montageTemp

        # Read montage width dynamically
        $montageWidth = [int](magick identify -format "%w" $montageTemp)

        # Right column alignment
        $rightX = $montageWidth - 10 - 300

        # Create compact header
        $header = Join-Path $temp "header.jpg"

        magick -size ${montageWidth}x60 canvas:none `
            -fill "rgba(0,0,0,0.65)" -draw "rectangle 0,0,$montageWidth,60" `
            -gravity northwest -fill white -pointsize 14 `
            -annotate +10+10 "$leftCol" `
            -annotate +${rightX}+10 "$rightCol" `
            $header

        # Stack header + montage
        magick $header $montageTemp -append $outGrid

        Write-Host "Created: $outGrid"

    }
    finally {
        # CLEANUP TEMP DIRECTORY
        if (Test-Path $temp) {
            Remove-Item -Recurse -Force $temp
        }
    }

} -ThrottleLimit $Concurrency
