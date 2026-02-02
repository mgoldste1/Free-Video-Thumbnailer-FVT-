# Free-Video-Thumbnailer-FVT-
Powershell 7 Wrapper for ffmpeg/ImageMagick that creates thumbnails without watermarks.


# Requirements for this to run:



| Program              | Source Repo | Description                                                                                       | WinGet Install Command                                          | Chocolatey Install Command     |
|----------------------|-------------|---------------------------------------------------------------------------------------------------|------------------------------------------------------------------|--------------------------------|
| **PowerShell 7**     | [Repo](https://github.com/PowerShell/PowerShell) | Cross‑platform PowerShell built on .NET; not included by default in Windows                       | `winget install --id Microsoft.Powershell`       | `choco install powershell-core` |
| **FFmpeg/FFprobe** | [Repo](https://github.com/FFmpeg/FFmpeg)        | Command‑line tools for video/audio processing, conversion, and general media manipulation         | `winget install --id=Gyan.FFmpeg -e`                                          | `choco install ffmpeg-full`     |
| **ImageMagick**      | [Repo](https://github.com/ImageMagick/ImageMagick) | Image processing suite used for thumbnails, conversions, and general image manipulation           | `winget install --id=ImageMagick.ImageMagick -e`                 | `choco install imagemagick`      |


If you want to add powershell 7 command prompts to your context menu in windows explorer, download the reg file in this repo and run it.
