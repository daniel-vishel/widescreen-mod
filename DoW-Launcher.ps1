# ============================================================
#  Dawn of War (Anniversary Edition) - Mod Launcher
#  Одно окно для всех модов репозитория: включение/выключение без
#  запуска отдельных скриптов. Настройки хранятся в
#  launcher-settings.json рядом со скриптом.
#
#  Возможности:
#   - выбор папки с игрой (автопоиск или вручную);
#   - widescreen-отрисовка под заданное разрешение; нерастянутый UI
#     ставится В КОМПЛЕКТЕ (отключается только вместе с отрисовкой);
#   - переключение текстур баров: дорисованные (textures-custom) /
#     жёсткая обрезка (стандартная нарезка из архива);
#   - улучшенный зум (отвод камеры, DistMax);
#   - русский язык ([lang:russian] в W40k.ini);
#   - WASD-камера (перехват клавиш, режим по Scroll Lock);
#   - полный откат всех модов.
#
#  Запуск:  .\DoW-Launcher.ps1              — окно настроек
#  Без GUI: .\DoW-Launcher.ps1 -Apply       — применить сохранённые настройки
#           .\DoW-Launcher.ps1 -Launch      — применить и запустить игру
#           .\DoW-Launcher.ps1 -RestoreAll  — полный откат
# ============================================================

param(
    [switch]$Apply,
    [switch]$Launch,
    [switch]$RestoreAll,
    [string]$GamePath = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$cfgPath = Join-Path $root 'launcher-settings.json'
$IsCli = $Apply -or $Launch -or $RestoreAll

# ---------- Настройки ----------
$S = [ordered]@{
    GamePath       = ''
    Game           = 'W40k'   # W40k | WA
    Width          = 3440
    Height         = 1440
    Widescreen     = $true    # отрисовка + UI (единый комплект)
    TexturesCustom = $true    # true = дорисованные, false = жёсткая обрезка
    Zoom           = $true
    DistMax        = 76
    Russian        = $false
    Wasd           = $false
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

# ---------- Лог (GUI + консоль) ----------
$script:LogBox = $null
function Write-Log([string]$msg, [string]$color = 'Gray') {
    foreach ($line in ($msg -split "`r?`n")) {
        if ($line.Trim() -eq '') { continue }
        if ($script:LogBox) {
            $script:LogBox.AppendText($line + "`r`n")
            $script:LogBox.ScrollToCaret()
        }
        Write-Host $line -ForegroundColor $color
    }
    if ($script:LogBox) { [System.Windows.Forms.Application]::DoEvents() }
}

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

# ---------- Дочерние скрипты ----------
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

# ---------- Русский язык (W40k.ini, строка [lang:...]) ----------
function Set-GameLanguage([string]$gp, [bool]$russian) {
    $ini = Join-Path $gp 'W40k.ini'
    $target = if ($russian) { 'russian' } else { 'english' }
    if (-not (Test-Path $ini)) {
        Write-Log "[!] W40k.ini не найден в папке игры — язык не изменён (файл создаётся после первого запуска)." 'Yellow'
        return
    }
    if ($russian) {
        $loc = @(Get-ChildItem -Path $gp -Recurse -Directory -Filter 'Russian' -ErrorAction SilentlyContinue |
                 Where-Object { $_.Parent.Name -ieq 'Locale' })
        if ($loc.Count -eq 0) {
            Write-Log "[!] Папка Locale\Russian не найдена — похоже, русская локализация не установлена. Прописываю язык всё равно (проверьте свойства игры в Steam: язык -> русский)." 'Yellow'
        }
    }
    $bak = "$ini.wsbak"
    if (-not (Test-Path $bak)) { Copy-Item $ini $bak }
    Set-ItemProperty $ini -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    $txt = Get-Content $ini -Raw
    if ($txt -match '\[lang:[^\]]*\]') {
        $txt = $txt -replace '\[lang:[^\]]*\]', "[lang:$target]"
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

# ---------- Применение настроек ----------
function Apply-Settings {
    $gp = Resolve-GamePath
    if (-not $gp) { Write-Log "[!] Папка игры не найдена — укажите её и повторите." 'Red'; return $false }
    Save-Settings
    Write-Log "=== Применяю настройки (игра: $gp) ===" 'Cyan'

    if ($S.Widescreen) {
        Write-Log "-- Widescreen UI (разрешение $($S.Width)x$($S.Height))..." 'Cyan'
        Invoke-Child 'ui-unstretch\Install-UnstretchedUI.ps1' @{ Width = [int]$S.Width; Height = [int]$S.Height; GamePath = $gp }
        if ($S.TexturesCustom) {
            Write-Log "-- Текстуры: дорисованные (textures-custom)..." 'Cyan'
            Invoke-Child 'ui-unstretch\Edit-BarTextures.ps1' @{ Import = $true; GamePath = $gp }
        } else {
            Write-Log "-- Текстуры: жёсткая обрезка (стандартная нарезка уже установлена)." 'Cyan'
        }
    } else {
        Write-Log "-- Widescreen выключен: убираю UI-мод (и текстуры вместе с ним)..." 'Cyan'
        Invoke-Child 'ui-unstretch\Install-UnstretchedUI.ps1' @{ Restore = $true; GamePath = $gp }
    }

    if ($S.Zoom) {
        Write-Log "-- Улучшенный зум (DistMax $($S.DistMax))..." 'Cyan'
        Invoke-Child 'camera-zoom\Install-CameraZoom.ps1' @{ DistMax = [double]$S.DistMax; GamePath = $gp }
    } else {
        Write-Log "-- Зум выключен: возвращаю стандартную камеру..." 'Cyan'
        Invoke-Child 'camera-zoom\Install-CameraZoom.ps1' @{ Restore = $true; GamePath = $gp }
    }

    Set-GameLanguage $gp $S.Russian
    if ($S.Wasd) {
        Write-Log "WASD-камера: будет включена при запуске игры через лаунчер (Scroll Lock — переключатель)." 'Cyan'
    }
    Write-Log "=== Настройки применены ===" 'Green'
    return $true
}

function Launch-Game {
    $gp = Resolve-GamePath
    if (-not $gp) { Write-Log "[!] Папка игры не найдена." 'Red'; return }
    if ($S.Widescreen) {
        Write-Log "Запускаю игру через widescreen-лаунчер (патч в памяти)..." 'Cyan'
        $wargs = @('-ExecutionPolicy','Bypass','-File', (Join-Path $root 'widescreen\Start-DoWWidescreen.ps1'),
                   '-Width', $S.Width, '-Height', $S.Height, '-ExeMode', $S.ExeMode,
                   '-Game', $S.Game, '-GamePath', $gp)
        Start-Process powershell -ArgumentList $wargs
    } else {
        $exe = if ($S.Game -eq 'WA') { 'W40kWA.exe' } else { 'W40k.exe' }
        Write-Log "Запускаю $exe без патча (widescreen выключен)..." 'Cyan'
        Start-Process (Join-Path $gp $exe) -WorkingDirectory $gp
    }
    if ($S.Wasd) {
        Write-Log "Включаю WASD-камеру (Scroll Lock ВКЛ = камера, ВЫКЛ = хоткеи)..." 'Cyan'
        Start-Process powershell -WindowStyle Minimized -ArgumentList @(
            '-ExecutionPolicy','Bypass','-File', (Join-Path $root 'tools\WasdCamera.ps1'))
    }
}

function Restore-Everything {
    $gp = Resolve-GamePath
    if (-not $gp) { Write-Log "[!] Папка игры не найдена." 'Red'; return }
    Write-Log "=== Полный откат всех модов ===" 'Cyan'
    Invoke-Child 'ui-unstretch\Install-UnstretchedUI.ps1' @{ Restore = $true; GamePath = $gp }
    Invoke-Child 'camera-zoom\Install-CameraZoom.ps1' @{ Restore = $true; GamePath = $gp }
    Invoke-Child 'widescreen\Start-DoWWidescreen.ps1' @{ RestoreIni = $true; GamePath = $gp }
    Restore-GameLanguage $gp
    # добираем TGA, добавленные -Import мимо манифеста (папку пишут только наши моды)
    $engineSga = Get-ChildItem -Path $gp -Recurse -Filter 'Engine.sga' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($engineSga) {
        $engineDir = Split-Path $engineSga.FullName -Parent
        foreach ($sub in @('Data\art\ui\textures\taskbar', 'Data\art\ui\screens')) {
            $p = Join-Path $engineDir $sub
            if (Test-Path $p) {
                Remove-Item $p -Recurse -Force
                Write-Log "Удалена папка мода: $p" 'Green'
            }
        }
    }
    Write-Log "=== Откат завершён. Widescreen-патч не требует отката: без лаунчера игра оригинальна. ===" 'Green'
}

# ---------- CLI-режимы ----------
if ($IsCli) {
    if ($RestoreAll) { Restore-Everything; exit 0 }
    $ok = Apply-Settings
    if ($Launch -and $ok) { Launch-Game }
    exit 0
}

# ---------- GUI ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Dawn of War — Mod Launcher'
$form.Size = New-Object System.Drawing.Size(600, 756)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'

function New-Label($text, $x, $y, $w = 120) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, 20)
    $l
}

# --- Группа: игра ---
$grpGame = New-Object System.Windows.Forms.GroupBox
$grpGame.Text = 'Игра'
$grpGame.Location = New-Object System.Drawing.Point(12, 10)
$grpGame.Size = New-Object System.Drawing.Size(560, 80)

$txtPath = New-Object System.Windows.Forms.TextBox
$txtPath.Location = New-Object System.Drawing.Point(12, 22)
$txtPath.Size = New-Object System.Drawing.Size(430, 22)
$txtPath.Text = $S.GamePath

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Обзор...'
$btnBrowse.Location = New-Object System.Drawing.Point(450, 20)
$btnBrowse.Size = New-Object System.Drawing.Size(98, 25)
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Папка с игрой (где лежит W40k.exe)'
    if ($dlg.ShowDialog() -eq 'OK') { $txtPath.Text = $dlg.SelectedPath }
})

$btnAuto = New-Object System.Windows.Forms.Button
$btnAuto.Text = 'Найти автоматически'
$btnAuto.Location = New-Object System.Drawing.Point(12, 50)
$btnAuto.Size = New-Object System.Drawing.Size(150, 24)
$btnAuto.Add_Click({
    $p = Find-GamePath
    if ($p) { $txtPath.Text = $p } else { Write-Log "[!] Автопоиск не нашёл игру — укажите папку вручную." 'Yellow' }
})

$cmbGame = New-Object System.Windows.Forms.ComboBox
$cmbGame.DropDownStyle = 'DropDownList'
[void]$cmbGame.Items.AddRange(@('W40k (базовая игра)', 'WA (Winter Assault)'))
$cmbGame.SelectedIndex = if ($S.Game -eq 'WA') { 1 } else { 0 }
$cmbGame.Location = New-Object System.Drawing.Point(380, 50)
$cmbGame.Size = New-Object System.Drawing.Size(168, 24)
$grpGame.Controls.AddRange(@($txtPath, $btnBrowse, $btnAuto, $cmbGame))

# --- Группа: widescreen + UI ---
$tip = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay = 20000; $tip.InitialDelay = 350; $tip.ReshowDelay = 100; $tip.ShowAlways = $true

$grpWs = New-Object System.Windows.Forms.GroupBox
$grpWs.Text = 'Widescreen-отрисовка + нерастянутый UI (единый комплект)'
$grpWs.Location = New-Object System.Drawing.Point(12, 96)
$grpWs.Size = New-Object System.Drawing.Size(560, 176)

$chkWs = New-Object System.Windows.Forms.CheckBox
$chkWs.Text = 'Включить отрисовку под разрешение (UI ставится автоматически)'
$chkWs.Location = New-Object System.Drawing.Point(12, 22)
$chkWs.Size = New-Object System.Drawing.Size(540, 20)
$chkWs.Checked = [bool]$S.Widescreen
$tip.SetToolTip($chkWs, @"
Расширяет обзор под ваш экран (честный FOV, не растяжение) и ставит нерастянутый UI.
Панели HUD не тянутся на всю ширину, а делятся и разъезжаются по углам экрана:
  - мини-карта и ресурсы -> левый нижний угол;
  - панель выбора отряда, команды и кнопки меню -> правый нижний угол;
  - центр экрана открыт, там виден 3D-мир.
Отрисовка и UI работают только вместе: выключение снимает и UI-мод.
"@)

$lblRes = New-Label 'Разрешение:' 12 52 90
$cmbRes = New-Object System.Windows.Forms.ComboBox
$cmbRes.DropDownStyle = 'DropDownList'
[void]$cmbRes.Items.AddRange(@('3440x1440', '2560x1080', '3840x1600', '5120x1440', '2560x1440', '1920x1080', 'другое'))
$cmbRes.Location = New-Object System.Drawing.Point(108, 48)
$cmbRes.Size = New-Object System.Drawing.Size(120, 24)

$numW = New-Object System.Windows.Forms.NumericUpDown
$numW.Minimum = 640; $numW.Maximum = 10000; $numW.Value = [int]$S.Width
$numW.Location = New-Object System.Drawing.Point(240, 48)
$numW.Size = New-Object System.Drawing.Size(70, 24)
$lblX = New-Label 'x' 314 52 12
$numH = New-Object System.Windows.Forms.NumericUpDown
$numH.Minimum = 480; $numH.Maximum = 5000; $numH.Value = [int]$S.Height
$numH.Location = New-Object System.Drawing.Point(330, 48)
$numH.Size = New-Object System.Drawing.Size(70, 24)

$preset = "$($S.Width)x$($S.Height)"
if ($cmbRes.Items.Contains($preset)) { $cmbRes.SelectedItem = $preset } else { $cmbRes.SelectedItem = 'другое' }
$cmbRes.Add_SelectedIndexChanged({
    if ($cmbRes.SelectedItem -ne 'другое' -and $cmbRes.SelectedItem -match '^(\d+)x(\d+)$') {
        $numW.Value = [int]$Matches[1]; $numH.Value = [int]$Matches[2]
    }
})

$lblTex = New-Label 'Текстуры баров:' 12 84 110
$radTexCustom = New-Object System.Windows.Forms.RadioButton
$radTexCustom.Text = 'дорисованные (textures-custom)'
$radTexCustom.Location = New-Object System.Drawing.Point(128, 82)
$radTexCustom.Size = New-Object System.Drawing.Size(230, 20)
$radTexHard = New-Object System.Windows.Forms.RadioButton
$radTexHard.Text = 'жёсткая обрезка (стандарт)'
$radTexHard.Location = New-Object System.Drawing.Point(360, 82)
$radTexHard.Size = New-Object System.Drawing.Size(195, 20)
if ($S.TexturesCustom) { $radTexCustom.Checked = $true } else { $radTexHard.Checked = $true }
$tip.SetToolTip($radTexCustom, @"
Фоны панелей берутся из ui-unstretch\textures-custom (ваш перерисованный арт
с плавными/аккуратными краями) и подгоняются под гнёзда кнопок. Мягкий стык.
"@)
$tip.SetToolTip($radTexHard, @"
Стандартная текстура из архива режется по границам зон и раздвигается.
Быстро и без ручной работы, но на местах разреза виден резкий обрыв картинки.
"@)

$lblWsNote1 = New-Label 'UI-панели делятся и разъезжаются по углам: мини-карта - слева, команды и меню - справа, в центре - 3D-мир.' 12 110 545
$lblWsNote1.Size = New-Object System.Drawing.Size(545, 30)
$lblWsNote1.ForeColor = [System.Drawing.Color]::DimGray
$lblWsNote2 = New-Label '«Дорисованные» - ваш арт с плавным краем; «жёсткая обрезка» - резкий обрыв на стыке. Выкл. отрисовку - UI-мод снимается.' 12 142 545
$lblWsNote2.Size = New-Object System.Drawing.Size(545, 30)
$lblWsNote2.ForeColor = [System.Drawing.Color]::DimGray

$grpWs.Controls.AddRange(@($chkWs, $lblRes, $cmbRes, $numW, $lblX, $numH, $lblTex, $radTexCustom, $radTexHard, $lblWsNote1, $lblWsNote2))

$chkWs.Add_CheckedChanged({
    foreach ($c in @($cmbRes, $numW, $numH, $radTexCustom, $radTexHard)) { $c.Enabled = $chkWs.Checked }
})
foreach ($c in @($cmbRes, $numW, $numH, $radTexCustom, $radTexHard)) { $c.Enabled = $chkWs.Checked }

# --- Группа: камера ---
$grpCam = New-Object System.Windows.Forms.GroupBox
$grpCam.Text = 'Камера'
$grpCam.Location = New-Object System.Drawing.Point(12, 278)
$grpCam.Size = New-Object System.Drawing.Size(560, 84)

$chkZoom = New-Object System.Windows.Forms.CheckBox
$chkZoom.Text = 'Улучшенный зум (отвод колёсиком дальше), DistMax:'
$chkZoom.Location = New-Object System.Drawing.Point(12, 22)
$chkZoom.Size = New-Object System.Drawing.Size(330, 20)
$chkZoom.Checked = [bool]$S.Zoom

$numDist = New-Object System.Windows.Forms.NumericUpDown
$numDist.Minimum = 38; $numDist.Maximum = 300; $numDist.Value = [int]$S.DistMax
$numDist.Location = New-Object System.Drawing.Point(350, 20)
$numDist.Size = New-Object System.Drawing.Size(70, 24)

$chkWasd = New-Object System.Windows.Forms.CheckBox
$chkWasd.Text = 'WASD-камера (Scroll Lock ВКЛ = камера, ВЫКЛ = обычные хоткеи)'
$chkWasd.Location = New-Object System.Drawing.Point(12, 50)
$chkWasd.Size = New-Object System.Drawing.Size(540, 20)
$chkWasd.Checked = [bool]$S.Wasd
$tip.SetToolTip($chkZoom, @"
Отодвигает максимальный отвод камеры колёсиком (DistMax; оригинал 38).
Требует включённой «Full 3D Camera» в настройках графики игры.
"@)
$tip.SetToolTip($chkWasd, @"
В движке DoW1 клавиши камеры не переназначаются, поэтому включается перехватчик:
Scroll Lock ВКЛ - W/A/S/D двигают камеру (лампочка на клавиатуре = режим включён);
Scroll Lock ВЫКЛ - те же клавиши работают как обычные хоткеи (A = attack-move и т.д.).
Действует только в окне игры, закрывается вместе с ней.
"@)

$grpCam.Controls.AddRange(@($chkZoom, $numDist, $chkWasd))

# --- Группа: язык ---
$grpLang = New-Object System.Windows.Forms.GroupBox
$grpLang.Text = 'Язык'
$grpLang.Location = New-Object System.Drawing.Point(12, 368)
$grpLang.Size = New-Object System.Drawing.Size(560, 52)

$chkRus = New-Object System.Windows.Forms.CheckBox
$chkRus.Text = 'Русский язык ([lang:russian] в W40k.ini; локализация должна быть установлена)'
$chkRus.Location = New-Object System.Drawing.Point(12, 20)
$chkRus.Size = New-Object System.Drawing.Size(540, 20)
$chkRus.Checked = [bool]$S.Russian
$tip.SetToolTip($chkRus, @"
Прописывает строку [lang:russian] в W40k.ini (с резервной копией).
Сами русские файлы должны быть в игре (Locale\Russian) - иначе выберите
русский язык в свойствах игры в Steam, чтобы Steam их докачал.
"@)
$grpLang.Controls.Add($chkRus)

# --- Кнопки ---
function Sync-SettingsFromForm {
    $S.GamePath       = $txtPath.Text.Trim()
    $S.Game           = if ($cmbGame.SelectedIndex -eq 1) { 'WA' } else { 'W40k' }
    $S.Width          = [int]$numW.Value
    $S.Height         = [int]$numH.Value
    $S.Widescreen     = $chkWs.Checked
    $S.TexturesCustom = $radTexCustom.Checked
    $S.Zoom           = $chkZoom.Checked
    $S.DistMax        = [int]$numDist.Value
    $S.Russian        = $chkRus.Checked
    $S.Wasd           = $chkWasd.Checked
}

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = 'Применить'
$btnApply.Location = New-Object System.Drawing.Point(12, 428)
$btnApply.Size = New-Object System.Drawing.Size(140, 32)
$btnApply.Add_Click({ Sync-SettingsFromForm; [void](Apply-Settings) })

$btnPlay = New-Object System.Windows.Forms.Button
$btnPlay.Text = 'Применить и играть'
$btnPlay.Location = New-Object System.Drawing.Point(160, 428)
$btnPlay.Size = New-Object System.Drawing.Size(170, 32)
$btnPlay.Font = New-Object System.Drawing.Font($btnPlay.Font, [System.Drawing.FontStyle]::Bold)
$btnPlay.Add_Click({ Sync-SettingsFromForm; if (Apply-Settings) { Launch-Game } })

$btnRestore = New-Object System.Windows.Forms.Button
$btnRestore.Text = 'Полный откат'
$btnRestore.Location = New-Object System.Drawing.Point(432, 428)
$btnRestore.Size = New-Object System.Drawing.Size(140, 32)
$btnRestore.Add_Click({ Sync-SettingsFromForm; Save-Settings; Restore-Everything })

# --- Лог ---
$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'
$log.Location = New-Object System.Drawing.Point(12, 470)
$log.Size = New-Object System.Drawing.Size(560, 210)
$log.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$script:LogBox = $log

$form.Controls.AddRange(@($grpGame, $grpWs, $grpCam, $grpLang, $btnApply, $btnPlay, $btnRestore, $log))

if (-not $S.GamePath) {
    $auto = Find-GamePath
    if ($auto) { $txtPath.Text = $auto; $S.GamePath = $auto }
}
Write-Log "Готов. Настройте и нажмите «Применить и играть»." 'Cyan'
if (-not (Test-Path (Join-Path $root 'ui-unstretch\textures-custom'))) {
    $radTexCustom.Enabled = $false; $radTexHard.Checked = $true
    Write-Log "textures-custom не найдены — доступна только жёсткая обрезка." 'Yellow'
}

[void]$form.ShowDialog()
