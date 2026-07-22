# ============================================================
#  Dawn of War (Anniversary Edition) - Mod Backend
#  Backend for the graphical manager (DoW-ModManager.exe) and for
#  console use. Settings live in launcher-settings.json.
#
#  IMPORTANT: widescreen is applied as an ON-DISK patch (game files are
#  edited, with a full backup in <game>\_widescreen_backup). That is what
#  lets the game start the ORDINARY way from Steam after Apply - no
#  launcher is needed at play time.
#
#  Features:
#   - game folder selection (auto-detected or manual);
#   - widescreen for a chosen resolution plus the unstretched UI;
#   - bar textures: repainted (textures-custom) or hard-cut;
#   - extended camera zoom (DistMax);
#   - Russian language (install the pack from an archive + [lang:russian]);
#   - detection of what is already installed (-Status);
#   - full rollback.
#
#  Modes:
#    .\DoW-Launcher.ps1 -Status       - JSON with the current game state
#    .\DoW-Launcher.ps1 -Apply        - apply the settings
#    .\DoW-Launcher.ps1 -Launch       - apply the settings and start the game
#    .\DoW-Launcher.ps1 -LaunchOnly   - just start the game, applying nothing
#    .\DoW-Launcher.ps1 -RestoreAll   - full rollback
# ============================================================

param(
    [switch]$Apply,
    [switch]$Launch,
    [switch]$LaunchOnly,           # just start the game, without applying settings
    [switch]$RestoreAll,
    [switch]$Status,
    [switch]$LocaleInfo,           # diagnostics: which locales are really installed
    [string]$GamePath = '',
    [string]$RussianArchive = ''   # localisation archive (zip/rar/7z) to install
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$cfgPath = Join-Path $root 'launcher-settings.json'

# ---------- Settings ----------
$S = [ordered]@{
    GamePath       = ''
    Game           = 'W40k'   # W40k | WA
    Width          = 3440
    Height         = 1440
    Widescreen     = $true    # rendering patch + UI, installed as one bundle
    TexturesCustom = $true    # true = repainted art, false = hard-cut slices
    Zoom           = $true
    DistMax        = 76
    Russian        = $false
    ExeMode        = 'skip'
}
if (Test-Path $cfgPath) {
    try {
        $j = Get-Content $cfgPath -Raw | ConvertFrom-Json
        foreach ($k in @($S.Keys)) {
            if ($null -ne $j.$k) { $S[$k] = $j.$k }
        }
    } catch { Write-Host "launcher-settings.json повреждён — использую значения по умолчанию." -ForegroundColor Yellow }
}
if ($GamePath) { $S.GamePath = $GamePath }

function Save-Settings {
    $S | ConvertTo-Json | Set-Content -Path $cfgPath -Encoding UTF8
}

function Write-Log([string]$msg, [string]$color = 'Gray') {
    foreach ($line in ($msg -split "`r?`n")) {
        if ($line.Trim() -eq '') { continue }
        Write-Host $line -ForegroundColor $color
    }
}

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
    # Join-Path raises when a candidate's drive does not exist, and with
    # ErrorActionPreference='Stop' that aborted the whole script on machines
    # without an E: drive. Concatenate strings instead.
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath ($c.TrimEnd('\') + '\W40k.exe')) { return $c }
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

function Resolve-GamePath {
    if ($S.GamePath -and (Test-Path (Join-Path $S.GamePath 'W40k.exe'))) { return $S.GamePath }
    $auto = Find-GamePath
    if ($auto) { $S.GamePath = $auto; return $auto }
    return $null
}

function Get-EngineDir([string]$gp) {
    $sga = Get-ChildItem -Path $gp -Recurse -Filter 'Engine.sga' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sga) { return (Split-Path $sga.FullName -Parent) }
    return (Join-Path $gp 'Engine')
}

# ---------- Locales ----------
# Returns a hash: locale name -> @{ Name; Paths; Ucs; Sga; Files }.
# Locales live in <game>\<module>\Locale\<Language>\ (W40k, WXP, DXP2,
# Engine) and/or in <game>\Locale\<Language>\. Only those places are
# scanned: recursing over the whole game folder was slow and inaccurate.
function Get-LocaleState([string]$gp) {
    $res = @{}
    if (-not $gp -or -not (Test-Path $gp)) { return $res }
    $localeDirs = New-Object System.Collections.Generic.List[string]
    $rootLoc = Join-Path $gp 'Locale'
    if (Test-Path $rootLoc) { $localeDirs.Add($rootLoc) }
    foreach ($d in Get-ChildItem -Path $gp -Directory -ErrorAction SilentlyContinue) {
        $p = Join-Path $d.FullName 'Locale'
        if (Test-Path $p) { $localeDirs.Add($p) }
    }
    foreach ($ld in $localeDirs) {
        foreach ($lang in Get-ChildItem -Path $ld -Directory -ErrorAction SilentlyContinue) {
            $name = $lang.Name
            $files = @(Get-ChildItem $lang.FullName -Recurse -File -ErrorAction SilentlyContinue)
            if (-not $res.ContainsKey($name)) {
                $res[$name] = @{ Name = $name; Paths = @(); Ucs = 0; Sga = 0; Files = 0 }
            }
            $res[$name].Paths += $lang.FullName
            $res[$name].Ucs   += @($files | Where-Object { $_.Extension -ieq '.ucs' }).Count
            $res[$name].Sga   += @($files | Where-Object { $_.Extension -ieq '.sga' }).Count
            $res[$name].Files += $files.Count
        }
    }
    return $res
}

# A locale counts as usable only when it actually holds content (.ucs text
# files and/or .sga). An empty Locale\Russian folder is not an installed
# localisation: pointing the language at one of those is exactly what made
# the game crash.
function Get-UsableLocales($localeState) {
    $out = @()
    foreach ($k in $localeState.Keys) {
        $v = $localeState[$k]
        if (($v.Ucs + $v.Sga) -gt 0) { $out += $v.Name }
    }
    return ($out | Sort-Object)
}

# ---------- Detect the current game state ----------
# Reads the facts off disk rather than trusting our own config, so a mod
# (or a localisation) installed earlier or by hand still shows up.
function Get-Status([string]$gp) {
    $st = [ordered]@{
        GamePath          = $gp
        WidescreenPatched = $false
        Width             = 0
        Height            = 0
        UiInstalled       = $false
        TexturesCustom    = $false
        ZoomInstalled     = $false
        DistMax           = 0
        LocaleRussian     = $false   # localisation files are really present in the game
        LocaleEnglish     = $false   # English locale present (needed to switch back)
        LocalesFound      = ''       # comma-separated list of the locales found
        LangRussian       = $false   # W40k.ini carries [lang:russian]
        BackupExists      = $false
    }
    if (-not $gp -or -not (Test-Path (Join-Path $gp 'W40k.exe'))) { return $st }
    $engineDir = Get-EngineDir $gp

    # widescreen: a patched Platform.dll no longer holds the 4:3 constant
    $plat = Join-Path $gp 'Platform.dll'
    if (Test-Path $plat) {
        try {
            $bytes = [IO.File]::ReadAllBytes($plat)
            $found = $false
            for ($i = 0; $i -le $bytes.Length - 4; $i++) {
                if ($bytes[$i] -eq 0xAB -and $bytes[$i+1] -eq 0xAA -and $bytes[$i+2] -eq 0xAA -and $bytes[$i+3] -eq 0x3F) { $found = $true; break }
            }
            $st.WidescreenPatched = -not $found
        } catch {}
    }
    $st.BackupExists = Test-Path (Join-Path $gp '_widescreen_backup')

    # resolution comes from Local.ini
    $ini = Join-Path $gp 'Local.ini'
    if (Test-Path $ini) {
        $txt = Get-Content $ini -Raw
        if ($txt -match '(?im)^\s*screenwidth\s*=\s*(\d+)')  { $st.Width  = [int]$Matches[1] }
        if ($txt -match '(?im)^\s*screenheight\s*=\s*(\d+)') { $st.Height = [int]$Matches[1] }
    }

    # UI mod: detected by its install manifest
    $st.UiInstalled = Test-Path (Join-Path $engineDir 'Data\ui-unstretch-manifest.txt')
    # which texture set is installed: by the marker Apply writes
    $st.TexturesCustom = Test-Path (Join-Path $engineDir 'Data\ui-textures-custom.marker')

    # zoom: by the loose camera file
    $cam = Join-Path $engineDir 'Data\camera_high.lua'
    if (Test-Path $cam) {
        $st.ZoomInstalled = $true
        $ct = Get-Content $cam -Raw
        if ($ct -match '(?im)^\s*DistMax\s*=\s*([\d\.]+)') { $st.DistMax = [double]$Matches[1] }
    }

    # localisation: which locales are REALLY installed (with content)
    $loc = Get-LocaleState $gp
    $usable = @(Get-UsableLocales $loc)
    $st.LocalesFound  = ($usable -join ', ')
    $st.LocaleRussian = [bool](@($usable | Where-Object { $_ -ieq 'Russian' }).Count)
    $st.LocaleEnglish = [bool](@($usable | Where-Object { $_ -ieq 'English' }).Count)

    $wini = Join-Path $gp 'W40k.ini'
    if (Test-Path $wini) {
        $wt = Get-Content $wini -Raw
        $st.LangRussian = $wt -match '(?i)\[lang:\s*russian\s*\]'
    }
    return $st
}

# ---------- Child scripts ----------
function Invoke-Child([string]$script, [hashtable]$scriptArgs) {
    $path = Join-Path $root $script
    if (-not (Test-Path $path)) { Write-Log "[!] Не найден $script" 'Red'; return }
    try {
        $out = & $path @scriptArgs *>&1 | Out-String
        Write-Log $out 'Gray'
    } catch {
        Write-Log "[!] ${script}: $($_.Exception.Message)" 'Red'
    }
}

# ---------- Localisation ----------
# Finds an extractor: 7-Zip (registry, PATH, usual folders), then WinRAR.
# 7-Zip handles everything (zip/rar/7z); WinRAR is the fallback.
function Find-Extractor {
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($rk in @('HKLM:\SOFTWARE\7-Zip','HKLM:\SOFTWARE\WOW6432Node\7-Zip','HKCU:\SOFTWARE\7-Zip')) {
        try {
            $p = (Get-ItemProperty $rk -ErrorAction Stop).Path
            if ($p) { $cands.Add((Join-Path $p '7z.exe')) }
        } catch {}
    }
    $cands.Add("$env:ProgramFiles\7-Zip\7z.exe")
    $cands.Add("${env:ProgramFiles(x86)}\7-Zip\7z.exe")
    try { $c = (Get-Command 7z.exe -ErrorAction Stop).Source; if ($c) { $cands.Add($c) } } catch {}
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return @{ Exe = $c; Kind = '7z' } } }

    $rar = New-Object System.Collections.Generic.List[string]
    foreach ($rk in @('HKLM:\SOFTWARE\WinRAR','HKLM:\SOFTWARE\WOW6432Node\WinRAR','HKCU:\SOFTWARE\WinRAR')) {
        try {
            $p = (Get-ItemProperty $rk -ErrorAction Stop).exe64
            if ($p) { $rar.Add($p) }
        } catch {}
    }
    $rar.Add("$env:ProgramFiles\WinRAR\WinRAR.exe")
    $rar.Add("${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe")
    $rar.Add("$env:ProgramFiles\WinRAR\UnRAR.exe")
    foreach ($c in $rar) { if ($c -and (Test-Path $c)) { return @{ Exe = $c; Kind = 'rar' } } }
    return $null
}

# Unpacks a localisation archive and lays it out over the game folder.
# Such archives are often wrapped in a redundant top directory, so the
# archive is extracted to a temporary folder first, the level holding the
# game module folders (W40k/Engine/Locale/...) is located, and only then is
# the content copied from there.
function Install-RussianArchive([string]$gp, [string]$archive) {
    if (-not (Test-Path $archive)) { Write-Log "[!] Архив русификатора не найден: $archive" 'Red'; return $false }
    Write-Log "Устанавливаю русификатор из архива: $archive" 'Cyan'
    $ext = [IO.Path]::GetExtension($archive).ToLowerInvariant()
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dow-rus-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $ex = Find-Extractor
        $done = $false
        if ($ex) {
            if ($ex.Kind -eq '7z') {
                & $ex.Exe x $archive "-o$tmp" -y 2>&1 | Out-Null
            } else {
                & $ex.Exe x -y $archive "$tmp\" 2>&1 | Out-Null
            }
            $done = (@(Get-ChildItem $tmp -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0)
            if ($done) { Write-Log "Распаковано через $(Split-Path $ex.Exe -Leaf)." 'DarkGray' }
        }
        if (-not $done -and $ext -eq '.zip') {
            Expand-Archive -Path $archive -DestinationPath $tmp -Force
            $done = $true
            Write-Log "Распаковано встроенным Expand-Archive." 'DarkGray'
        }
        if (-not $done) {
            Write-Log "[!] Не нашёл, чем распаковать $ext. Установите 7-Zip (https://www.7-zip.org)" 'Red'
            Write-Log "    или распакуйте архив в папку игры вручную." 'Red'
            return $false
        }

        # find the level holding the game folders, stripping the wrapper
        $src = $tmp
        for ($i = 0; $i -lt 4; $i++) {
            $hasGameDirs = @(Get-ChildItem $src -Directory -ErrorAction SilentlyContinue |
                             Where-Object { $_.Name -imatch '^(W40k|WXP|DXP2|DXP3|Engine|Locale)$' }).Count -gt 0
            if ($hasGameDirs) { break }
            $kids = @(Get-ChildItem $src -Directory -ErrorAction SilentlyContinue)
            $files = @(Get-ChildItem $src -File -ErrorAction SilentlyContinue)
            if ($kids.Count -eq 1 -and $files.Count -eq 0) { $src = $kids[0].FullName } else { break }
        }
        if ($src -ne $tmp) { Write-Log "Снята лишняя папка-обёртка внутри архива." 'DarkGray' }

        Copy-Item -Path (Join-Path $src '*') -Destination $gp -Recurse -Force
        $n = @(Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue).Count
        Write-Log "Файлы русификатора скопированы в папку игры (файлов: $n)." 'Green'

        $after = @(Get-UsableLocales (Get-LocaleState $gp))
        Write-Log "Локали в игре после установки: $($after -join ', ')" 'Green'
        return $true
    } catch {
        Write-Log "[!] Не удалось распаковать архив: $($_.Exception.Message)" 'Red'
        return $false
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Set-GameLanguage([string]$gp, [bool]$russian) {
    $ini = Join-Path $gp 'W40k.ini'
    $target = if ($russian) { 'russian' } else { 'english' }
    if (-not (Test-Path $ini)) {
        Write-Log "[!] W40k.ini не найден — язык не изменён (файл создаётся после первого запуска игры)." 'Yellow'
        return
    }

    # CRASH GUARD. The engine dies at startup when [lang:X] points at a
    # locale the game does not have. The classic case: the localisation
    # replaced the English locale, the language was later set back to
    # english, and the game crashed. So switch only to a locale that is
    # really present and has content.
    $usable = @(Get-UsableLocales (Get-LocaleState $gp))
    if ($usable.Count -eq 0) {
        Write-Log "[!] В игре не найдено ни одной локали с содержимым — язык не трогаю (иначе игра вылетит)." 'Red'
        return
    }
    if (-not (@($usable | Where-Object { $_ -ieq $target }).Count)) {
        Write-Log "[!] Локаль '$target' в игре отсутствует (есть: $($usable -join ', '))." 'Red'
        Write-Log "    Язык НЕ переключён — с несуществующей локалью игра вылетает при запуске." 'Red'
        if ($target -eq 'english') {
            Write-Log "    Похоже, русификатор заменил английскую локаль. Чтобы вернуть английский," 'Yellow'
            Write-Log "    проверьте целостность файлов игры в Steam (Свойства -> Локальные файлы)." 'Yellow'
        } else {
            Write-Log "    Установите русификатор (архив) — тогда язык переключится." 'Yellow'
        }
        return
    }
    $bak = "$ini.wsbak"
    if (-not (Test-Path $bak)) { Copy-Item $ini $bak }
    Set-ItemProperty $ini -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    $txt = Get-Content $ini -Raw
    if ($txt -match '(?i)\[lang:[^\]]*\]') {
        $txt = $txt -replace '(?i)\[lang:[^\]]*\]', "[lang:$target]"
    } else {
        $txt = $txt.TrimEnd() + "`r`n[lang:$target]`r`n"
    }
    Set-Content -Path $ini -Value $txt -Encoding ASCII
    Write-Log "Язык игры: [lang:$target] прописан в W40k.ini." 'Green'
}

function Restore-GameLanguage([string]$gp) {
    $ini = Join-Path $gp 'W40k.ini'
    $bak = "$ini.wsbak"
    if (Test-Path $bak) {
        Set-ItemProperty $ini -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        Copy-Item $bak $ini -Force
        Remove-Item $bak -Force
        Write-Log "W40k.ini восстановлен из копии." 'Green'
    }
}

# ---------- Apply the settings ----------
function Apply-Settings {
    $gp = Resolve-GamePath
    if (-not $gp) { Write-Log "[!] Папка игры не найдена — укажите её и повторите." 'Red'; return $false }
    Save-Settings
    Write-Log "=== Применяю настройки (игра: $gp) ===" 'Cyan'
    $engineDir = Get-EngineDir $gp
    $marker = Join-Path $engineDir 'Data\ui-textures-custom.marker'

    if ($S.Widescreen) {
        # On-disk patch: afterwards the game starts from Steam as usual
        Write-Log "-- Widescreen: патчу файлы игры на диске ($($S.Width)x$($S.Height), exe: $($S.ExeMode))..." 'Cyan'
        Invoke-Child 'widescreen\DoW-Widescreen-Patcher.ps1' @{ Width = [int]$S.Width; Height = [int]$S.Height; ExeMode = [string]$S.ExeMode; GamePath = $gp }

        Write-Log "-- Нерастянутый UI..." 'Cyan'
        Invoke-Child 'ui-unstretch\Install-UnstretchedUI.ps1' @{ Width = [int]$S.Width; Height = [int]$S.Height; GamePath = $gp }

        if ($S.TexturesCustom) {
            Write-Log "-- Текстуры: дорисованные (textures-custom)..." 'Cyan'
            Invoke-Child 'ui-unstretch\Edit-BarTextures.ps1' @{ Import = $true; GamePath = $gp }
            New-Item -ItemType Directory -Force -Path (Split-Path $marker -Parent) | Out-Null
            Set-Content -Path $marker -Value 'custom' -Encoding ASCII
        } else {
            Write-Log "-- Текстуры: жёсткая обрезка (стандартная нарезка)." 'Cyan'
            if (Test-Path $marker) { Remove-Item $marker -Force }
        }
    } else {
        Write-Log "-- Widescreen выключен: возвращаю оригинальные файлы игры и убираю UI-мод..." 'Cyan'
        Invoke-Child 'widescreen\DoW-Widescreen-Patcher.ps1' @{ Restore = $true; GamePath = $gp }
        Invoke-Child 'ui-unstretch\Install-UnstretchedUI.ps1' @{ Restore = $true; GamePath = $gp }
        if (Test-Path $marker) { Remove-Item $marker -Force }
    }

    if ($S.Zoom) {
        Write-Log "-- Улучшенный зум (DistMax $($S.DistMax))..." 'Cyan'
        Invoke-Child 'camera-zoom\Install-CameraZoom.ps1' @{ DistMax = [double]$S.DistMax; GamePath = $gp }
    } else {
        Write-Log "-- Зум выключен: возвращаю стандартную камеру..." 'Cyan'
        Invoke-Child 'camera-zoom\Install-CameraZoom.ps1' @{ Restore = $true; GamePath = $gp }
    }

    if ($S.Russian) {
        $st = Get-Status $gp
        if (-not $st.LocaleRussian) {
            if ($RussianArchive) {
                [void](Install-RussianArchive $gp $RussianArchive)
            } else {
                Write-Log "[!] Файлы русификатора в игре не найдены. Скачайте архив (см. README) и укажите его в менеджере — тогда он будет распакован в папку игры." 'Yellow'
            }
        } else {
            Write-Log "Файлы русификатора уже в игре — переустановка не нужна." 'Green'
        }
    }
    Set-GameLanguage $gp ([bool]$S.Russian)

    Write-Log "=== Настройки применены. Игру можно запускать обычным способом из Steam. ===" 'Green'
    return $true
}

function Launch-Game {
    $gp = Resolve-GamePath
    if (-not $gp) { Write-Log "[!] Папка игры не найдена." 'Red'; return }
    $exe = if ($S.Game -eq 'WA') { 'W40kWA.exe' } else { 'W40k.exe' }
    Write-Log "Запускаю $exe..." 'Cyan'
    Start-Process (Join-Path $gp $exe) -WorkingDirectory $gp
}

function Restore-Everything {
    $gp = Resolve-GamePath
    if (-not $gp) { Write-Log "[!] Папка игры не найдена." 'Red'; return }
    Write-Log "=== Полный откат всех модов ===" 'Cyan'
    Invoke-Child 'widescreen\DoW-Widescreen-Patcher.ps1' @{ Restore = $true; GamePath = $gp }
    Invoke-Child 'ui-unstretch\Install-UnstretchedUI.ps1' @{ Restore = $true; GamePath = $gp }
    Invoke-Child 'camera-zoom\Install-CameraZoom.ps1' @{ Restore = $true; GamePath = $gp }
    Restore-GameLanguage $gp
    # sweep files added outside the manifest (only our mods write these folders)
    $engineDir = Get-EngineDir $gp
    foreach ($sub in @('Data\art\ui\textures\taskbar', 'Data\art\ui\screens')) {
        $p = Join-Path $engineDir $sub
        if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Log "Удалена папка мода: $p" 'Green' }
    }
    $marker = Join-Path $engineDir 'Data\ui-textures-custom.marker'
    if (Test-Path $marker) { Remove-Item $marker -Force }
    Write-Log "=== Откат завершён. Файлы игры возвращены к оригиналу. ===" 'Green'
    Write-Log "Примечание: файлы русификатора (если ставились) не удаляются — только язык в W40k.ini возвращён на английский." 'DarkGray'
}

# ---------- Entry point ----------
if ($Status) {
    $gp = Resolve-GamePath
    Get-Status $gp | ConvertTo-Json -Compress
    exit 0
}
if ($LocaleInfo) {
    $gp = Resolve-GamePath
    if (-not $gp) { Write-Host "Папка игры не найдена." -ForegroundColor Red; exit 1 }
    Write-Host "Игра: $gp" -ForegroundColor Cyan
    $ls = Get-LocaleState $gp
    if ($ls.Keys.Count -eq 0) {
        Write-Host "Локалей не найдено вообще (<игра>\<модуль>\Locale\<Язык>)." -ForegroundColor Red
    } else {
        foreach ($k in ($ls.Keys | Sort-Object)) {
            $v = $ls[$k]
            $mark = if (($v.Ucs + $v.Sga) -gt 0) { 'OK ' } else { 'ПУСТО' }
            Write-Host ("[{0}] {1}: файлов={2}, .ucs={3}, .sga={4}" -f $mark, $v.Name, $v.Files, $v.Ucs, $v.Sga) -ForegroundColor Green
            foreach ($p in $v.Paths) { Write-Host "        $p" -ForegroundColor DarkGray }
        }
    }
    Write-Host "Пригодные локали: $((Get-UsableLocales $ls) -join ', ')" -ForegroundColor Cyan
    $wini = Join-Path $gp 'W40k.ini'
    if (Test-Path $wini) {
        $m = [regex]::Match((Get-Content $wini -Raw), '(?i)\[lang:\s*([^\]\s]+)\s*\]')
        Write-Host ("W40k.ini: " + $(if ($m.Success) { "[lang:$($m.Groups[1].Value)]" } else { "строки [lang:...] нет" })) -ForegroundColor Cyan
    } else { Write-Host "W40k.ini не найден (создаётся после первого запуска игры)." -ForegroundColor Yellow }
    $ex = Find-Extractor
    Write-Host ("Распаковщик архивов: " + $(if ($ex) { $ex.Exe } else { "НЕ НАЙДЕН (нужен 7-Zip для .rar/.7z)" })) -ForegroundColor Cyan
    exit 0
}
if ($RestoreAll) { Restore-Everything; exit 0 }
if ($LaunchOnly) { Launch-Game; exit 0 }   # start the game without applying settings
if ($Apply -or $Launch) {
    $ok = Apply-Settings
    if ($Launch -and $ok) { Launch-Game }
    exit 0
}

Write-Host @"
Бэкенд модов Dawn of War. Графический менеджер: DoW-ModManager.exe
(соберите: powershell -File app\Build-App.ps1)

Консольные режимы:
  -Status       текущее состояние игры (JSON)
  -LocaleInfo   какие локали реально стоят в игре (диагностика русификатора)
  -Apply        применить настройки из launcher-settings.json
  -Launch       применить и запустить игру
  -RestoreAll   полный откат
"@ -ForegroundColor Cyan
