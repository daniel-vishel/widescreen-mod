# ============================================================
#  Готовит иконку приложения (app\app.ico) и картинку шапки
#  (app\header.png) из вашего изображения.
#
#  Использование:
#      .\app\Make-Icon.ps1 -Source "C:\путь\картинка.png"
#      .\app\Make-Icon.ps1 -Source "..." -HeaderOnly    # только шапка
#      .\app\Make-Icon.ps1 -Source "..." -IconOnly      # только иконка
#
#  После этого пересоберите приложение:
#      powershell -File app\Build-App.ps1
#  Иконка попадёт в .exe, шапка подхватится при запуске.
# ============================================================
param(
    [Parameter(Mandatory=$true)][string]$Source,
    [switch]$IconOnly,
    [switch]$HeaderOnly,
    # какую часть картинки по вертикали ставить в центр полосы шапки:
    # 0 — верх, 0.5 — середина, 1 — низ (для портрета ~0.45 = глаза)
    [double]$HeaderFocus = 0.45
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path $Source)) { Write-Host "Файл не найден: $Source" -ForegroundColor Red; exit 1 }
$appDir = $PSScriptRoot
$src = [System.Drawing.Image]::FromFile((Resolve-Path $Source).Path)
Write-Host ("Исходник: {0}x{1}" -f $src.Width, $src.Height) -ForegroundColor Cyan

function New-Square([System.Drawing.Image]$img, [int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    # обрезаем по центру в квадрат, затем масштабируем
    $side = [Math]::Min($img.Width, $img.Height)
    $sx = [int](($img.Width  - $side) / 2)
    $sy = [int](($img.Height - $side) / 2)
    $srcRect  = New-Object System.Drawing.Rectangle($sx, $sy, $side, $side)
    $destRect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
    $g.DrawImage($img, $destRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    return $bmp
}

# ---------- app.ico (многоразмерная иконка) ----------
if (-not $HeaderOnly) {
    $sizes = @(16, 32, 48, 64, 128, 256)
    $pngs = @()
    foreach ($s in $sizes) {
        $bmp = New-Square $src $s
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngs += ,($ms.ToArray())
        $bmp.Dispose(); $ms.Close()
    }
    $ico = Join-Path $appDir 'app.ico'
    $fs = [IO.File]::Create($ico)
    $bw = New-Object IO.BinaryWriter($fs)
    try {
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)   # ICONDIR
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $s = $sizes[$i]
            $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))   # ширина (0 = 256)
            $bw.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))   # высота
            $bw.Write([byte]0); $bw.Write([byte]0)                  # палитра, reserved
            $bw.Write([uint16]1); $bw.Write([uint16]32)             # плоскости, бит на пиксель
            $bw.Write([uint32]$pngs[$i].Length)
            $bw.Write([uint32]$offset)
            $offset += $pngs[$i].Length
        }
        foreach ($p in $pngs) { $bw.Write($p) }
    } finally { $bw.Close(); $fs.Close() }
    Write-Host "Иконка: $ico  (размеры: $($sizes -join ', '))" -ForegroundColor Green
}

# ---------- header.png (широкая картинка шапки) ----------
if (-not $IconOnly) {
    $hw = 688; $hh = 84
    $bmp = New-Object System.Drawing.Bitmap($hw, $hh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    # вырезаем из исходника полосу с пропорциями шапки, центрируя её на -HeaderFocus
    $ratio = $hw / $hh
    $cw = $src.Width; $ch = [int]($src.Width / $ratio)
    if ($ch -gt $src.Height) { $ch = $src.Height; $cw = [int]($src.Height * $ratio) }
    $sx = [int](($src.Width - $cw) / 2)
    $sy = [int]($src.Height * $HeaderFocus - $ch / 2)
    if ($sy -lt 0) { $sy = 0 }
    if ($sy + $ch -gt $src.Height) { $sy = $src.Height - $ch }
    $srcRect  = New-Object System.Drawing.Rectangle($sx, $sy, $cw, $ch)
    $destRect = New-Object System.Drawing.Rectangle(0, 0, $hw, $hh)
    $g.DrawImage($src, $destRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $hdr = Join-Path $appDir 'header.png'
    $bmp.Save($hdr, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "Шапка: $hdr  (${hw}x${hh})" -ForegroundColor Green
}

$src.Dispose()
Write-Host "`nГотово. Пересоберите приложение: powershell -File app\Build-App.ps1" -ForegroundColor Cyan
