# ============================================================
#  Dawn of War (Anniversary Edition) - Camera Zoom Mod
#  Raises the maximum camera distance (mouse wheel zoom-out).
#
#  Mechanism: the engine reads loose files from <game>\Engine\Data
#  OVER the Engine.sga archive, so dropping our own camera_high.lua
#  there leaves every original game file untouched.
#  Rollback = delete that one file (-Restore).
#
#  Campaign compatibility: camera parameters are not stored in saves
#  and are not part of the campaign module data (W40k/WXP), so the mod
#  also applies to campaigns that are already in progress.
#
#  Usage:
#      .\Install-CameraZoom.ps1                    # DistMax = 76 (2x stock)
#      .\Install-CameraZoom.ps1 -DistMax 100       # custom distance
#      .\Install-CameraZoom.ps1 -WheelSpeed 2.0    # faster wheel zoom
#      .\Install-CameraZoom.ps1 -Restore           # full rollback
#
#  IMPORTANT: Full 3D Camera must be ENABLED in the game graphics
#  settings, otherwise camera_low is used and the mod has no effect.
# ============================================================

param(
    [double]$DistMax = 76.0,       # max camera distance (stock: 38.0)
    [double]$WheelSpeed = 0,       # wheel zoom-out speed, 0 = leave as is (stock: 1.45)
    [string]$GamePath = '',
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------- Locate the game folder ----------
function Find-GamePath {
    $candidates = @(
        "C:\Program Files (x86)\Steam\steamapps\common\Dawn of War Gold",
        "C:\Program Files (x86)\Steam\steamapps\common\Dawn of War Anniversary Edition",
        "C:\Program Files\Steam\steamapps\common\Dawn of War Gold",
        "D:\Steam\steamapps\common\Dawn of War Gold",
        "D:\SteamLibrary\steamapps\common\Dawn of War Gold",
        "E:\Steam\steamapps\common\Dawn of War Gold",
        "E:\SteamLibrary\steamapps\common\Dawn of War Gold"
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'W40k.exe')) { return $c }
    }
    try {
        $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
        if ($steam) {
            $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
            if (Test-Path $vdf) {
                $libs = Select-String -Path $vdf -Pattern '"path"\s+"(.+?)"' -AllMatches |
                        ForEach-Object { $_.Matches } |
                        ForEach-Object { $_.Groups[1].Value -replace '\\\\','\' }
                foreach ($lib in $libs) {
                    foreach ($name in @('Dawn of War Gold','Dawn of War Anniversary Edition','Dawn of War')) {
                        $p = Join-Path $lib "steamapps\common\$name"
                        if (Test-Path (Join-Path $p 'W40k.exe')) { return $p }
                    }
                }
            }
        }
    } catch {}
    return $null
}

if (-not $GamePath) { $GamePath = Find-GamePath }
if (-not $GamePath -or -not (Test-Path (Join-Path $GamePath 'W40k.exe'))) {
    Write-Host "Не нашёл папку с игрой автоматически." -ForegroundColor Yellow
    $GamePath = Read-Host "Вставьте полный путь к папке игры (где лежит W40k.exe)"
    if (-not (Test-Path (Join-Path $GamePath 'W40k.exe'))) {
        Write-Host "W40k.exe не найден по этому пути. Выход." -ForegroundColor Red
        exit 1
    }
}
Write-Host "Папка игры: $GamePath" -ForegroundColor Cyan

$EngineData = Join-Path $GamePath 'Engine\Data'
$TargetFile = Join-Path $EngineData 'camera_high.lua'

# ---------- Rollback ----------
if ($Restore) {
    if (Test-Path $TargetFile) {
        Remove-Item $TargetFile -Force
        Write-Host "Удалён: $TargetFile" -ForegroundColor Green
        Write-Host "Камера вернулась к оригиналу (файл читается из Engine.sga). Готово." -ForegroundColor Green
    } else {
        Write-Host "Мод не установлен ($TargetFile отсутствует) — откатывать нечего." -ForegroundColor Yellow
    }
    exit 0
}

# ---------- Parameter sanity checks ----------
if ($DistMax -lt 38) {
    Write-Host "[!] DistMax=$DistMax меньше оригинала (38) — камера станет БЛИЖЕ, а не дальше." -ForegroundColor Yellow
}
if ($DistMax -gt 300) {
    Write-Host "[!] DistMax=$DistMax очень большой: на дальнем отводе карта тонет в тумане." -ForegroundColor Yellow
}

# ---------- Generate the file from the template ----------
$Template = Join-Path $PSScriptRoot 'template\camera_high.lua'
if (-not (Test-Path $Template)) {
    Write-Host "Не найден шаблон $Template — запускайте скрипт из папки camera-zoom репозитория." -ForegroundColor Red
    exit 1
}
$txt = Get-Content $Template -Raw

$distStr = $DistMax.ToString('0.0##', $inv)
$txt = $txt -replace '(?m)^DistMax\s*=\s*[\d\.]+', "DistMax = $distStr"

if ($WheelSpeed -gt 0) {
    $wheelStr = $WheelSpeed.ToString('0.0##', $inv)
    $txt = $txt -replace '(?m)^DistRateWheelZoomOut\s*=\s*[\d\.]+', "DistRateWheelZoomOut = $wheelStr"
}

if (-not (Test-Path $EngineData)) {
    New-Item -ItemType Directory -Path $EngineData -Force | Out-Null
    Write-Host "Создана папка: $EngineData" -ForegroundColor DarkGray
}

Set-Content -Path $TargetFile -Value $txt -Encoding ASCII -NoNewline
Write-Host "Установлен: $TargetFile" -ForegroundColor Green
Write-Host ("  DistMax = {0}  (оригинал 38.0)" -f $distStr)
if ($WheelSpeed -gt 0) { Write-Host ("  DistRateWheelZoomOut = {0}  (оригинал 1.45)" -f $wheelStr) }

Write-Host @"

================= ГОТОВО =================
Оригинальные файлы игры НЕ изменялись — файл лежит поверх
архива Engine.sga и просто перекрывает его.

Проверьте в игре:
 1) Настройки -> графика: Full 3D Camera должна быть ВКЛЮЧЕНА.
 2) Колёсико мыши — камера отводится заметно дальше.
 3) Текущие кампании/сейвы загружаются как обычно.

Откат:             .\Install-CameraZoom.ps1 -Restore
Другая дальность:  .\Install-CameraZoom.ps1 -DistMax 100
==========================================
"@ -ForegroundColor Cyan
