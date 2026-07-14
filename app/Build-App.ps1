# ============================================================
#  Сборка DoW-ModManager.exe из app\DowModManager.cs
#  Использует системный компилятор .NET Framework 4.x (csc.exe) —
#  установка каких-либо SDK не требуется. Готовый .exe кладётся в
#  КОРЕНЬ репозитория (рядом с DoW-Launcher.ps1 и папками модов).
#
#  Запуск:  powershell -ExecutionPolicy Bypass -File app\Build-App.ps1
# ============================================================
param(
    [switch]$SelfTest   # после сборки прогнать DoW-ModManager.exe --selftest
)

$ErrorActionPreference = 'Stop'
$appDir = $PSScriptRoot
$repo   = Split-Path $appDir -Parent
$src    = Join-Path $appDir 'DowModManager.cs'
$out    = Join-Path $repo   'DoW-ModManager.exe'
$icon   = Join-Path $appDir 'app.ico'

# csc из .NET Framework 4.x (есть на всех Windows 10/11)
$csc = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework64' -Filter csc.exe -Recurse -ErrorAction SilentlyContinue |
       Where-Object { $_.DirectoryName -match 'v4\.' } |
       Sort-Object FullName -Descending | Select-Object -First 1
if (-not $csc) {
    $csc = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework' -Filter csc.exe -Recurse -ErrorAction SilentlyContinue |
           Where-Object { $_.DirectoryName -match 'v4\.' } |
           Sort-Object FullName -Descending | Select-Object -First 1
}
if (-not $csc) {
    Write-Host "Не найден csc.exe (.NET Framework 4.x). Установите .NET Framework 4.x (обычно уже есть в Windows)." -ForegroundColor Red
    exit 1
}
Write-Host "Компилятор: $($csc.FullName)" -ForegroundColor Cyan

$refs = @(
    '/reference:System.dll',
    '/reference:System.Core.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll'
)
$args = @('/nologo', '/target:winexe', "/out:$out") + $refs
if (Test-Path $icon) { $args += "/win32icon:$icon" }
$args += $src

& $csc.FullName @args
if ($LASTEXITCODE -ne 0) {
    Write-Host "Сборка не удалась (код $LASTEXITCODE)." -ForegroundColor Red
    exit $LASTEXITCODE
}
Write-Host "Собрано: $out" -ForegroundColor Green

if ($SelfTest) {
    Write-Host "`n--- Самопроверка ---" -ForegroundColor Cyan
    & $out --selftest
    Write-Host "код выхода: $LASTEXITCODE" -ForegroundColor DarkGray
}

Write-Host @"

Готово. Запуск приложения — двойным кликом по DoW-ModManager.exe
(лежит в корне рядом со скриптами) или:
    .\DoW-ModManager.exe
"@ -ForegroundColor Cyan
