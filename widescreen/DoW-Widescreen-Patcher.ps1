# ============================================================
#  Dawn of War (Anniversary Edition) - Widescreen Patcher
#  Расширяет обзор под любое разрешение (по умолч. 3440x1440)
#  Использование (обычный запуск):
#      .\DoW-Widescreen-Patcher.ps1
#  Другое разрешение:
#      .\DoW-Widescreen-Patcher.ps1 -Width 2560 -Height 1080
#  Режимы патча exe (влияет на мини-карту, см. README):
#      -ExeMode skip        (по умолчанию: exe не трогаем)
#      -ExeMode compromise  (exe -> 1.25, компромисс для мини-карты)
#      -ExeMode full        (exe -> полное соотношение, мир может растянуться)
#  Откат к оригиналу:
#      .\DoW-Widescreen-Patcher.ps1 -Restore
# ============================================================

param(
    [int]$Width  = 3440,
    [int]$Height = 1440,
    [ValidateSet('skip','compromise','full')]
    [string]$ExeMode = 'skip',
    [string]$GamePath = '',
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

# ---------- Быстрый поиск/замена байтов через C# ----------
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
public static class BytePatcher {
    public static int ReplaceAll(byte[] data, byte[] find, byte[] repl) {
        if (find.Length != repl.Length) throw new Exception("len mismatch");
        int count = 0;
        for (int i = 0; i <= data.Length - find.Length; i++) {
            bool match = true;
            for (int j = 0; j < find.Length; j++) {
                if (data[i + j] != find[j]) { match = false; break; }
            }
            if (match) {
                for (int j = 0; j < repl.Length; j++) data[i + j] = repl[j];
                count++;
                i += find.Length - 1;
            }
        }
        return count;
    }
    public static int CountAll(byte[] data, byte[] find) {
        int count = 0;
        for (int i = 0; i <= data.Length - find.Length; i++) {
            bool match = true;
            for (int j = 0; j < find.Length; j++) {
                if (data[i + j] != find[j]) { match = false; break; }
            }
            if (match) { count++; i += find.Length - 1; }
        }
        return count;
    }
}
"@

# ---------- Поиск папки с игрой ----------
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
    # Поиск через реестр Steam -> libraryfolders.vdf
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

$BackupDir = Join-Path $GamePath '_widescreen_backup'
$DllFiles  = @('Platform.dll','spDx9.dll','UserInterface.dll')
$ExeFiles  = @('W40k.exe','W40kWA.exe')
$AllFiles  = $DllFiles + $ExeFiles

# ---------- Режим отката ----------
if ($Restore) {
    if (-not (Test-Path $BackupDir)) {
        Write-Host "Папка с резервными копиями не найдена ($BackupDir)." -ForegroundColor Red
        exit 1
    }
    foreach ($f in $AllFiles + @('Local.ini')) {
        $src = Join-Path $BackupDir $f
        if (Test-Path $src) {
            $dst = Join-Path $GamePath $f
            if (Test-Path $dst) { Set-ItemProperty $dst -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
            Copy-Item $src $dst -Force
            Write-Host "Восстановлен: $f" -ForegroundColor Green
        }
    }
    Write-Host "`nВсе файлы восстановлены из резервной копии. Готово." -ForegroundColor Green
    exit 0
}

# ---------- Вычисление hex-значений ----------
$OrigBytes = [byte[]](0xAB,0xAA,0xAA,0x3F)                          # float 1.3333 (4:3)
$AspectVal = [float]($Width / $Height)
$NewBytes  = [BitConverter]::GetBytes($AspectVal)                    # little-endian
$CompBytes = [BitConverter]::GetBytes([float]1.25)                   # 00 00 A0 3F

$hexNew = ($NewBytes | ForEach-Object { $_.ToString('X2') }) -join ' '
Write-Host ("Разрешение: {0}x{1}  |  соотношение = {2:N4}  |  hex: {3}" -f $Width,$Height,$AspectVal,$hexNew) -ForegroundColor Cyan
Write-Host "Режим exe: $ExeMode`n"

# ---------- Резервные копии (только один раз, оригиналы) ----------
if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir | Out-Null }
foreach ($f in $AllFiles + @('Local.ini')) {
    $src = Join-Path $GamePath $f
    $dst = Join-Path $BackupDir $f
    if ((Test-Path $src) -and -not (Test-Path $dst)) {
        Copy-Item $src $dst
        Write-Host "Резервная копия: $f" -ForegroundColor DarkGray
    }
}

# ---------- Функция патча одного файла ----------
function Patch-File([string]$name, [byte[]]$replBytes) {
    $path = Join-Path $GamePath $name
    if (-not (Test-Path $path)) {
        Write-Host "  [пропуск] $name не найден" -ForegroundColor Yellow
        return
    }
    Set-ItemProperty $path -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    $data = [IO.File]::ReadAllBytes($path)

    $already = [BytePatcher]::CountAll($data, $replBytes)
    $n = [BytePatcher]::ReplaceAll($data, $OrigBytes, $replBytes)

    if ($n -gt 0) {
        [IO.File]::WriteAllBytes($path, $data)
        Write-Host "  [OK] $name — заменено вхождений: $n" -ForegroundColor Green
    } elseif ($already -gt 0) {
        Write-Host "  [--] $name — уже пропатчен ранее ($already вхожд.)" -ForegroundColor DarkYellow
    } else {
        Write-Host "  [!!] $name — шаблон не найден (нестандартная версия файла?)" -ForegroundColor Red
    }
}

# ---------- Восстановление оригиналов из бэкапа перед патчем ----------
# (чтобы повторные запуски с другим разрешением/режимом работали корректно)
foreach ($f in $AllFiles) {
    $src = Join-Path $BackupDir $f
    $dst = Join-Path $GamePath $f
    if ((Test-Path $src) -and (Test-Path $dst)) {
        Set-ItemProperty $dst -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        Copy-Item $src $dst -Force
    }
}

Write-Host "Патчу DLL (3D-обзор):"
foreach ($f in $DllFiles) { Patch-File $f $NewBytes }

switch ($ExeMode) {
    'skip' {
        Write-Host "`nExe-файлы не изменяются (рекомендуемый режим для 21:9)." -ForegroundColor Cyan
    }
    'compromise' {
        Write-Host "`nПатчу exe (компромиссное значение 1.25 для мини-карты):"
        foreach ($f in $ExeFiles) { Patch-File $f $CompBytes }
    }
    'full' {
        Write-Host "`nПатчу exe (полное соотношение — мир может растянуться!):"
        foreach ($f in $ExeFiles) { Patch-File $f $NewBytes }
    }
}

# ---------- Local.ini ----------
$ini = Join-Path $GamePath 'Local.ini'
if (Test-Path $ini) {
    Set-ItemProperty $ini -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    $txt = Get-Content $ini -Raw
    $txt = $txt -replace '(?im)^\s*screenwidth\s*=\s*\d+',  "screenwidth=$Width"
    $txt = $txt -replace '(?im)^\s*screenheight\s*=\s*\d+', "screenheight=$Height"
    if ($txt -notmatch '(?im)^\s*screenwidth')  { $txt += "`r`nscreenwidth=$Width" }
    if ($txt -notmatch '(?im)^\s*screenheight') { $txt += "`r`nscreenheight=$Height" }
    Set-Content -Path $ini -Value $txt -Encoding ASCII
    # Ставим "только чтение", чтобы игра не сбросила разрешение из меню настроек
    Set-ItemProperty $ini -Name IsReadOnly -Value $true
    Write-Host "`nLocal.ini: разрешение ${Width}x${Height} прописано, файл защищён от перезаписи (read-only)." -ForegroundColor Green
} else {
    Write-Host "`n[!] Local.ini не найден в папке игры. Запустите игру один раз, чтобы он создался, затем запустите патчер снова." -ForegroundColor Yellow
}

Write-Host @"

================= ГОТОВО =================
Запустите игру и проверьте:
 1) Появилась ли доп. область по бокам (не растяжение).
 2) Как выглядит мини-карта.
 3) Как выглядит интерфейс.

ВАЖНО: не меняйте разрешение в настройках игры.
Играйте с этим только в одиночном режиме.

Откат:            .\DoW-Widescreen-Patcher.ps1 -Restore
Другой режим exe: .\DoW-Widescreen-Patcher.ps1 -ExeMode compromise
==========================================
"@ -ForegroundColor Cyan
