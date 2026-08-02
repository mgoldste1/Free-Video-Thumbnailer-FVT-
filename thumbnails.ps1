param(
    [Parameter(Mandatory=$true)]
    [string]$InputFolder,

    [int]$Concurrency = 8,

    # CONFIG OPTIONS
    [int]$FrameWidth = 480,     # width of each frame
    [int]$GridX = 5,            # frames horizontally
    [int]$GridY = 10,            # frames vertically

    # User-facing JPEG quality (0–100)
    [int]$Quality = 76,

    [bool]$MovePics = $true,

    # OUTPUT NAMING
    # $true  -> 1.mp4.grid.jpg
    # $false -> 1.mp4.jpg
    [bool]$UseGridSuffix = $true,

    # HEADER TEXT SCALING
    [double]$HeaderFontScale = 0.010,    # pointsize as a fraction of the grid's height
    [int]$HeaderFontMin = 14,            # floor, unless one long unbreakable word forces smaller
    [double]$HeaderMaxHeightPct = 0.08   # header may not exceed this share of the grid's height
)

# Move pictures to 'pics' subdirectory if flag is set
if ($MovePics) {
    $picExts = @('jpg','jpeg','png','gif','bmp','tiff','tif','webp','heic','avif')
    $picRegex = ($picExts -join '|')
    $pics = Get-ChildItem -Path $InputFolder -File | Where-Object { $_.Extension -match "(?i)^\.($picRegex)$" }
    if ($pics.Count -gt 0) {
        $picsDir = Join-Path $InputFolder 'pics'
        if (-not (Test-Path $picsDir)) {
            New-Item -ItemType Directory -Path $picsDir | Out-Null
        }
        foreach ($pic in $pics) {
            Move-Item -Path $pic.FullName -Destination $picsDir
        }
    }
}

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

# --- Video file extensions supported by ffmpeg (common set) ---
$videoExts = @(
    '3g2','3gp','amv','asf','avi','divx','drc','f4v','flv','gxf','m2ts','m2v','m4v','mkv','mov','mp4','mpe','mpeg','mpg','mpv','mts','mxf','nsv','ogg','ogv','qt','rm','rmvb','roq','svi','ts','vob','webm','wmv','yuv'
)
$videoRegex = ($videoExts -join '|')

# Reliable video detection (all ffmpeg-supported extensions)
$videos = Get-ChildItem -Path $InputFolder -File |
    Where-Object { $_.Extension -match "(?i)^\.($videoRegex)$" }

if ($videos.Count -eq 0) {
    throw "No video files found in '$InputFolder'."
}

Write-Host "Found $($videos.Count) videos."

# Total frames needed
$TotalFrames = $GridX * $GridY

# Process videos in parallel
$videos | ForEach-Object -Parallel {

    $video = $_

    # Output name: [fullFileNameWithExtension](.grid).jpg
    $suffix  = if ($using:UseGridSuffix) { '.grid' } else { '' }
    $outGrid = Join-Path $video.Directory ("$($video.Name)$suffix.jpg")

    $temp = $null

    try {

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

        # Two-line header: full filename on top, everything else on one line below
        $headerLine1 = $video.Name
        $headerLine2 = @(
            "$($stream.width)x$($stream.height)"
            "$($stream.codec_name)"
            "$([math]::Round($format.bit_rate / 1000)) kbps"
            "$([math]::Round($video.Length / 1MB, 2)) MB"
            "$durationFormatted"
        ) -join "  |  "

        $headerText = "$headerLine1`n$headerLine2"

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

        # Read montage dimensions dynamically
        $montageDims   = (magick identify -format "%w %h" $montageTemp) -split '\s+'
        $montageWidth  = [int]$montageDims[0]
        $montageHeight = [int]$montageDims[1]

        # --- Header sizing ------------------------------------------------
        # Font tracks the sheet's HEIGHT, so text stays readable once the whole
        # sheet is zoomed down to fit a screen. Lines too wide for the sheet are
        # wrapped by ImageMagick's caption:, so width no longer caps the font --
        # except for a single unbreakable word (a long filename), which can't wrap.

        # caption:/label: expand % escapes, so double up any percent in the text
        $headerEscaped = $headerText.Replace('%', '%%')

        $pointSize = [int][math]::Round($montageHeight * $using:HeaderFontScale)
        if ($pointSize -lt $using:HeaderFontMin) { $pointSize = $using:HeaderFontMin }

        # Cap by the longest unbreakable word, measured for real at a reference size
        $longestWord = $headerEscaped -split '\s+' |
            Sort-Object { $_.Length } -Descending | Select-Object -First 1

        if ($longestWord) {
            $refSize  = 100
            $refWidth = [int](magick -pointsize $refSize label:"$longestWord" -format "%w" info:)
            if ($refWidth -gt 0) {
                # needed width = pointSize * (refWidth/refSize), plus 0.6*pointSize padding each side
                $maxByWord = [int][math]::Floor($montageWidth / (($refWidth / $refSize) + 1.2))
                if ($maxByWord -lt 6) { $maxByWord = 6 }
                if ($pointSize -gt $maxByWord) { $pointSize = $maxByWord }
            }
        }

        # Render, shrinking if wrapping makes the header eat too much of the sheet
        $maxHeaderHeight = [int]($montageHeight * $using:HeaderMaxHeightPct)
        $header = Join-Path $temp "header.jpg"

        for ($attempt = 0; $attempt -lt 12; $attempt++) {

            $pad       = [int][math]::Ceiling($pointSize * 0.6)
            $textWidth = $montageWidth - (2 * $pad)

            magick -background black -fill white -pointsize $pointSize `
                -size "${textWidth}x" caption:"$headerEscaped" `
                -bordercolor black -border ${pad}x${pad} `
                $header

            $headerHeight = [int](magick identify -format "%h" $header)

            if ($headerHeight -le $maxHeaderHeight -or $pointSize -le $using:HeaderFontMin) { break }

            $next = [int][math]::Floor($pointSize * 0.85)
            if ($next -lt $using:HeaderFontMin) { $next = $using:HeaderFontMin }
            $pointSize = $next
        }

        # Stack header + montage
        magick $header $montageTemp -append $outGrid

        Write-Host "Created: $outGrid"

    } catch {
        $errMsg = $_ | Out-String
        Write-Host $errMsg -ForegroundColor Red
        $errorFile = [System.IO.Path]::ChangeExtension($outGrid, 'txt')
        $errMsg | Set-Content -Encoding UTF8 $errorFile
    } finally {
        # CLEANUP TEMP DIRECTORY
        if ($temp -and (Test-Path $temp)) {
            Remove-Item -Recurse -Force $temp
        }
    }

} -ThrottleLimit $Concurrency
