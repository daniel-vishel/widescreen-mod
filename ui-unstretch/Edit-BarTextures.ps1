# ============================================================
#  Dawn of War (Anniversary Edition) - Unstretched UI
#  Выгрузка/загрузка ломтиков фоновых текстур баров для ручной
#  доработки (плавные края вместо жёстких обрезов).
#
#  -Export: режет фоновые текстуры баров из вашего Engine.sga на те
#     же ломтики, что и Install-UnstretchedUI.ps1, и сохраняет их
#     обычными PNG (правильная ориентация, альфа-канал) в
#     ui-unstretch\textures\<раса>\. Ширина холста — с запасом
#     (паддинг до степени двойки): туда можно ДОРИСОВАТЬ плавное
#     окончание — в игре оно продолжит панель вправо.
#  -Import: собирает отредактированные PNG обратно в игровые TGA
#     (перевёрнутый порядок строк DDS, который ждёт движок) и кладёт
#     их в <игра>\Engine\Data\... поверх установленных.
#
#  Порядок работы:
#      .\Install-UnstretchedUI.ps1       # установить мод (создаёт разметку)
#      .\Edit-BarTextures.ps1 -Export    # выгрузить PNG для правки
#      ... правите PNG в редакторе (альфа = прозрачность) ...
#      .\Edit-BarTextures.ps1 -Import    # вернуть правки в игру
#
#  ВАЖНО: повторный запуск Install-UnstretchedUI.ps1 перегенерирует
#  TGA из архива и затрёт ваши правки — после него снова -Import.
#  Не меняйте размеры PNG: ширина должна остаться степенью двойки.
# ============================================================

param(
    [switch]$Export,
    [switch]$Import,
    [string]$GamePath = '',
    [string]$Dir = "$PSScriptRoot\textures"
)

$ErrorActionPreference = 'Stop'

if (-not $Export -and -not $Import) {
    Write-Host "Укажите режим: -Export (выгрузить PNG для правки) или -Import (вернуть правки в игру)." -ForegroundColor Yellow
    exit 1
}

# Разрезы — те же, что в Install-UnstretchedUI.ps1 (держать в синхроне!)
$barSlices = @(
    @{ Base = 'taskbar';      Cuts = @(0.0, 0.278, 0.630, 1.0) },
    @{ Base = 'taskbar_menu'; Cuts = @(0.0, 0.45, 1.0) }
)

# ---------- C#: чтение SGA v2 + декодер DXT ----------
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;

public class SgaEntry2 {
    public string Path;
    public uint CompFlag;
    public long DataOffset;
    public int  CompSize;
    public int  DecompSize;
}

public static class SgaV2R2 {
    static ushort U16(byte[] b, long o) { return BitConverter.ToUInt16(b, (int)o); }
    static uint   U32(byte[] b, long o) { return BitConverter.ToUInt32(b, (int)o); }
    static string CStr(byte[] b, long start) {
        long end = start;
        while (end < b.Length && b[end] != 0) end++;
        return Encoding.ASCII.GetString(b, (int)start, (int)(end - start));
    }
    public static List<SgaEntry2> ReadToc(string path) {
        byte[] b = File.ReadAllBytes(path);
        if (Encoding.ASCII.GetString(b, 0, 8) != "_ARCHIVE") throw new Exception("bad magic");
        if (U16(b, 8) != 2) throw new Exception("unsupported SGA version");
        long dataOffset = U32(b, 0xB0);
        const long TOC = 0xB4;
        long vdOff   = TOC + U32(b, TOC + 0);
        long dirOff  = TOC + U32(b, TOC + 6);  int dirCnt  = U16(b, TOC + 10);
        long fileOff = TOC + U32(b, TOC + 12);
        long nameOff = TOC + U32(b, TOC + 18);
        string drivePath = CStr(b, vdOff);
        var result = new List<SgaEntry2>();
        for (int d = 0; d < dirCnt; d++) {
            long e = dirOff + d * 12;
            string dir = CStr(b, nameOff + U32(b, e)).Replace('\\', '/');
            int fs = U16(b, e + 8), fe = U16(b, e + 10);
            for (int f = fs; f < fe; f++) {
                long fe2 = fileOff + f * 20;
                var it = new SgaEntry2();
                string nm = CStr(b, nameOff + U32(b, fe2));
                it.Path = (dir.Length > 0 ? dir + "/" : "") + nm;
                if (drivePath.Length > 0) it.Path = drivePath.ToLowerInvariant() + "/" + it.Path;
                it.CompFlag   = U32(b, fe2 + 4);
                it.DataOffset = dataOffset + U32(b, fe2 + 8);
                it.CompSize   = (int)U32(b, fe2 + 12);
                it.DecompSize = (int)U32(b, fe2 + 16);
                result.Add(it);
            }
        }
        return result;
    }
    public static byte[] ReadFileData(string archivePath, SgaEntry2 e) {
        using (var fs = File.OpenRead(archivePath)) {
            fs.Seek(e.DataOffset, SeekOrigin.Begin);
            byte[] raw = new byte[e.CompSize];
            int got = 0;
            while (got < raw.Length) {
                int r = fs.Read(raw, got, raw.Length - got);
                if (r <= 0) throw new Exception("unexpected EOF");
                got += r;
            }
            if (e.CompFlag == 0) return raw;
            using (var ms = new MemoryStream(raw, 2, raw.Length - 2))
            using (var ds = new DeflateStream(ms, CompressionMode.Decompress))
            using (var outMs = new MemoryStream(e.DecompSize)) {
                ds.CopyTo(outMs);
                return outMs.ToArray();
            }
        }
    }
}

public static class DxtDec2 {
    public static byte[] Decode(byte[] d, int off, int w, int h, string fmt) {
        byte[] outPx = new byte[w * h * 4]; // BGRA, в порядке строк DDS
        int bw = (w + 3) / 4, bh = (h + 3) / 4;
        int blockSize = fmt == "DXT1" ? 8 : 16;
        for (int by = 0; by < bh; by++)
        for (int bx = 0; bx < bw; bx++) {
            int bo = off + (by * bw + bx) * blockSize;
            byte[] alpha = new byte[16];
            for (int i = 0; i < 16; i++) alpha[i] = 255;
            int co = bo;
            if (fmt == "DXT3") {
                for (int i = 0; i < 8; i++) {
                    byte v = d[bo + i];
                    alpha[i*2]   = (byte)((v & 0x0F) * 17);
                    alpha[i*2+1] = (byte)(((v >> 4) & 0x0F) * 17);
                }
                co = bo + 8;
            } else if (fmt == "DXT5") {
                byte a0 = d[bo], a1 = d[bo+1];
                ulong bits = 0;
                for (int i = 0; i < 6; i++) bits |= ((ulong)d[bo+2+i]) << (8*i);
                for (int i = 0; i < 16; i++) {
                    int code = (int)((bits >> (3*i)) & 7);
                    int a;
                    if (code == 0) a = a0;
                    else if (code == 1) a = a1;
                    else if (a0 > a1) a = ((8-code)*a0 + (code-1)*a1) / 7;
                    else if (code == 6) a = 0;
                    else if (code == 7) a = 255;
                    else a = ((6-code)*a0 + (code-1)*a1) / 5;
                    alpha[i] = (byte)a;
                }
                co = bo + 8;
            }
            ushort c0 = (ushort)(d[co] | (d[co+1] << 8));
            ushort c1 = (ushort)(d[co+2] | (d[co+3] << 8));
            uint idx = (uint)(d[co+4] | (d[co+5] << 8) | (d[co+6] << 16) | (d[co+7] << 24));
            byte[][] cols = new byte[4][];
            cols[0] = C565(c0); cols[1] = C565(c1);
            if (c0 > c1 || fmt != "DXT1") {
                cols[2] = Lerp(cols[0], cols[1], 2, 1, 3);
                cols[3] = Lerp(cols[0], cols[1], 1, 2, 3);
            } else {
                cols[2] = Lerp(cols[0], cols[1], 1, 1, 2);
                cols[3] = new byte[] {0,0,0,0};
            }
            for (int py = 0; py < 4; py++)
            for (int px = 0; px < 4; px++) {
                int x = bx*4 + px, y = by*4 + py;
                if (x >= w || y >= h) continue;
                int ci = (int)((idx >> (2*(py*4+px))) & 3);
                int o = (y*w + x)*4;
                outPx[o] = cols[ci][2]; outPx[o+1] = cols[ci][1]; outPx[o+2] = cols[ci][0];
                byte a2 = alpha[py*4+px];
                if (fmt == "DXT1" && ci == 3 && c0 <= c1) a2 = 0;
                outPx[o+3] = a2;
            }
        }
        return outPx;
    }
    static byte[] C565(ushort c) {
        return new byte[] {
            (byte)(((c >> 11) & 31) * 255 / 31),
            (byte)(((c >> 5) & 63) * 255 / 63),
            (byte)((c & 31) * 255 / 31),
            255 };
    }
    static byte[] Lerp(byte[] a, byte[] b, int wa, int wb, int div) {
        return new byte[] {
            (byte)((a[0]*wa + b[0]*wb) / div),
            (byte)((a[1]*wa + b[1]*wb) / div),
            (byte)((a[2]*wa + b[2]*wb) / div),
            255 };
    }
}
"@

Add-Type -AssemblyName System.Drawing

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

$engineSga = Get-ChildItem -Path $GamePath -Recurse -Filter 'Engine.sga' -ErrorAction SilentlyContinue |
             Select-Object -First 1
if (-not $engineSga) { Write-Host "Engine.sga не найден." -ForegroundColor Red; exit 1 }
$engineDir = Split-Path $engineSga.FullName -Parent

function Get-Pow2([int]$n) { $p = 1; while ($p -lt $n) { $p *= 2 }; return $p }

# BGRA (порядок строк DDS, «вверх ногами») <-> Bitmap (нормальная ориентация)
function Save-PngFlipped([byte[]]$px, [int]$w, [int]$h, [string]$path) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    for ($y = 0; $y -lt $h; $y++) {
        $srcRow = $h - 1 - $y   # переворот: DDS-порядок -> нормальный вид
        [System.Runtime.InteropServices.Marshal]::Copy($px, $srcRow * $w * 4, [IntPtr]($bd.Scan0.ToInt64() + $y * $bd.Stride), $w * 4)
    }
    $bmp.UnlockBits($bd)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
function Load-PngFlipped([string]$path, [ref]$w, [ref]$h) {
    $bmp = New-Object System.Drawing.Bitmap($path)
    $w.Value = $bmp.Width; $h.Value = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
    $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $px = New-Object byte[] ($bmp.Width * $bmp.Height * 4)
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        $dstRow = $bmp.Height - 1 - $y   # переворот: нормальный вид -> DDS-порядок
        [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($bd.Scan0.ToInt64() + $y * $bd.Stride), $px, $dstRow * $bmp.Width * 4, $bmp.Width * 4)
    }
    $bmp.UnlockBits($bd)
    $bmp.Dispose()
    return ,$px
}
function Write-Tga([string]$path, [byte[]]$px, [int]$w, [int]$h) {
    # строки в порядке DDS, origin top-left (0x28) — так ждёт движок
    $hdr = New-Object byte[] 18
    $hdr[2]  = 2
    $hdr[12] = $w -band 0xFF; $hdr[13] = ($w -shr 8) -band 0xFF
    $hdr[14] = $h -band 0xFF; $hdr[15] = ($h -shr 8) -band 0xFF
    $hdr[16] = 32; $hdr[17] = 0x28
    $fs = [IO.File]::Create($path)
    try {
        $fs.Write($hdr, 0, 18)
        for ($y = 0; $y -lt $h; $y++) { $fs.Write($px, $y * $w * 4, $w * 4) }
    } finally { $fs.Close() }
}

# ---------- Export ----------
if ($Export) {
    $entries = [SgaV2R2]::ReadToc($engineSga.FullName)
    $count = 0
    foreach ($spec in $barSlices) {
        $base = $spec.Base; $cuts = $spec.Cuts
        $srcs = @($entries | Where-Object { $_.Path -match "textures/taskbar/[^/]+/$base\.dds$" })
        foreach ($src in $srcs) {
            $d = [SgaV2R2]::ReadFileData($engineSga.FullName, $src)
            if ([Text.Encoding]::ASCII.GetString($d, 0, 4) -ne 'DDS ') { continue }
            $th = [BitConverter]::ToInt32($d, 12); $tw = [BitConverter]::ToInt32($d, 16)
            $fourcc = [Text.Encoding]::ASCII.GetString($d, 84, 4)
            if ($fourcc -notmatch 'DXT[135]') { continue }
            $px = [DxtDec2]::Decode($d, 128, $tw, $th, $fourcc)
            $folder = ($src.Path -split '/')[-2]
            $outDir = Join-Path $Dir $folder
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
            for ($i = 0; $i -lt $cuts.Count - 1; $i++) {
                $x0 = [int][Math]::Round($cuts[$i] * $tw); $x1 = [int][Math]::Round($cuts[$i+1] * $tw)
                $cw = $x1 - $x0; $P = Get-Pow2 $cw
                $buf = New-Object byte[] ($P * $th * 4)
                for ($y = 0; $y -lt $th; $y++) {
                    [Array]::Copy($px, ($y * $tw + $x0) * 4, $buf, $y * $P * 4, $cw * 4)
                }
                $f = Join-Path $outDir ("{0}_ws{1}.png" -f $base, ($i + 1))
                Save-PngFlipped $buf $P $th $f
                $count++
                Write-Host ("  [OK] {0}\{1}_ws{2}.png  (контент {3}px из {4}px холста)" -f $folder, $base, ($i+1), $cw, $P) -ForegroundColor Green
            }
        }
    }
    Write-Host @"

Выгружено PNG: $count -> $Dir
Правьте в любом редакторе с альфа-каналом (прозрачность = дыра в панели).
Запас холста справа от контента виден в игре как продолжение панели —
туда можно дорисовать плавное окончание. Размеры файлов НЕ менять.
Вернуть в игру: .\Edit-BarTextures.ps1 -Import
"@ -ForegroundColor Cyan
    exit 0
}

# ---------- Import ----------
if ($Import) {
    if (-not (Test-Path $Dir)) {
        Write-Host "Папка $Dir не найдена — сначала выгрузите PNG: -Export" -ForegroundColor Red
        exit 1
    }
    $count = 0
    foreach ($png in Get-ChildItem $Dir -Recurse -Filter '*_ws*.png') {
        $folder = Split-Path (Split-Path $png.FullName -Parent) -Leaf
        $w = 0; $h = 0
        $px = Load-PngFlipped $png.FullName ([ref]$w) ([ref]$h)
        if ((Get-Pow2 $w) -ne $w) {
            Write-Host "  [!!] $($png.Name): ширина $w не степень двойки — файл пропущен (не меняйте размер холста)" -ForegroundColor Red
            continue
        }
        $outDir = Join-Path $engineDir "Data\art\ui\textures\taskbar\$folder"
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        $tga = Join-Path $outDir ($png.BaseName + '.tga')
        Write-Tga $tga $px $w $h
        $count++
        Write-Host "  [OK] $folder\$($png.BaseName).tga" -ForegroundColor Green
    }
    Write-Host @"

Собрано TGA: $count -> $engineDir\Data\art\ui\textures\taskbar\
Перезапустите игру, чтобы увидеть правки.
ВАЖНО: Install-UnstretchedUI.ps1 при переустановке перегенерирует TGA
из архива — после него запустите -Import ещё раз.
"@ -ForegroundColor Cyan
}
