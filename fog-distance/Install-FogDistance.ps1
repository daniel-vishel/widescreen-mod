# ============================================================
#  Dawn of War (Anniversary Edition) - Increased Fog Distance
#  Fog distance and sky radius for the campaign maps.
#
#  WHY. A map's distance fog is calibrated for the stock camera
#  distance (DistMax = 38). Zoomed out further (camera-zoom), objects
#  fall past fog end and wash out into haze, which makes the high view
#  useless. This fix pushes the fog back WITHOUT disabling it: the
#  atmosphere stays, but units and buildings remain visible.
#
#  WHERE. Campaign maps live in <game>\W40k\...\scenarios\sp\*.sgb,
#  in the Relic Chunky format. Under FOLD SCEN > FOLD WSTC > FOLD TERR:
#    DATA EFFC - atmosphere: two colours, two zeroes, then the fog
#                distance float at offset +40, then the fog colour
#                and a water block;
#    DATA HRZN - sky: uint32 nameLen | name (WH_SKY_01) | sky radius
#                float | byte.
#  Both edits overwrite a float IN PLACE, so chunk sizes never change.
#
#  ORIGINALS ARE NOT MODIFIED: maps are read from your own .sga,
#  patched in memory and written as loose files into <game>\W40k\Data\scenarios\sp\.
#  The engine reads loose files over the archive, the same trick
#  camera-zoom uses. Rollback (-Restore) deletes the loose files listed
#  in the manifest, bringing the vanilla maps from the archive back.
#
#  IMPORTANT, SAVES. A campaign save references map data, so with the
#  fix active older saves may refuse to load - the authors of similar
#  mods warn about the same thing. Here it is REVERSIBLE: -Restore
#  brings the vanilla maps back and the old saves open again. The
#  recommendation still stands: enable it on a fresh campaign.
#
#  Usage:
#      .\Install-FogDistance.ps1                        # 1000 / 512
#      .\Install-FogDistance.ps1 -FogDistance 1500 -SkyRadius 700
#      .\Install-FogDistance.ps1 -Restore               # rollback
# ============================================================

param(
    [double]$FogDistance = 1000.0,   # fog distance (stock value differs per map)
    [double]$SkyRadius   = 512.0,    # sky dome radius
    [string]$GamePath    = '',
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------- C#: SGA v2 reader + Relic Chunky parser ----------
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;

public class SgaEntry3 {
    public string Path;
    public uint CompFlag;
    public long DataOffset;
    public int  CompSize;
    public int  DecompSize;
}

public static class SgaV2R3 {
    static ushort U16(byte[] b, long o) { return BitConverter.ToUInt16(b, (int)o); }
    static uint   U32(byte[] b, long o) { return BitConverter.ToUInt32(b, (int)o); }
    static string CStr(byte[] b, long start) {
        long end = start;
        while (end < b.Length && b[end] != 0) end++;
        return Encoding.ASCII.GetString(b, (int)start, (int)(end - start));
    }
    public static List<SgaEntry3> ReadToc(string path) {
        byte[] b = File.ReadAllBytes(path);
        if (b.Length < 0xB4) throw new Exception("too small");
        if (Encoding.ASCII.GetString(b, 0, 8) != "_ARCHIVE") throw new Exception("bad magic");
        if (U16(b, 8) != 2) throw new Exception("unsupported SGA version");
        long dataOffset = U32(b, 0xB0);
        const long TOC = 0xB4;
        long vdOff   = TOC + U32(b, TOC + 0);
        long dirOff  = TOC + U32(b, TOC + 6);  int dirCnt  = U16(b, TOC + 10);
        long fileOff = TOC + U32(b, TOC + 12);
        long nameOff = TOC + U32(b, TOC + 18);
        string drivePath = CStr(b, vdOff);
        var result = new List<SgaEntry3>();
        for (int d = 0; d < dirCnt; d++) {
            long e = dirOff + d * 12;
            string dir = CStr(b, nameOff + U32(b, e)).Replace('\\', '/');
            int fs = U16(b, e + 8), fe = U16(b, e + 10);
            for (int f = fs; f < fe; f++) {
                long fe2 = fileOff + f * 20;
                var it = new SgaEntry3();
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
    public static byte[] ReadFileData(string archivePath, SgaEntry3 e) {
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

// ----- Relic Chunky: locate DATA chunks -----
// File header: "Relic Chunky\r\n\x1a\x00" (16 b) + version + platform (8 b),
// so chunks start at 0x18. Chunk header:
//   char[4] kind (FOLD|DATA) | char[4] type | u32 version | u32 size | u32 nameLen | char[nameLen] name
public static class Chunky {
    public static int Find(byte[] d, string type) {
        return Scan(d, 0x18, d.Length, type);
    }
    static int Scan(byte[] d, int off, int end, string type) {
        while (off + 20 <= end && off + 20 <= d.Length) {
            string kind = Encoding.ASCII.GetString(d, off, 4);
            if (kind != "FOLD" && kind != "DATA") return -1;
            string typ  = Encoding.ASCII.GetString(d, off + 4, 4);
            uint size    = BitConverter.ToUInt32(d, off + 12);
            uint nameLen = BitConverter.ToUInt32(d, off + 16);
            int body = off + 20 + (int)nameLen;
            if (body < 0 || body > d.Length) return -1;
            if (kind == "DATA" && typ == type) return body;
            if (kind == "FOLD") {
                int r = Scan(d, body, body + (int)size, type);
                if (r >= 0) return r;
            }
            off = body + (int)size;
        }
        return -1;
    }
}
"@

# ---------- Locate the game folder ----------
function Find-GamePath {
    $candidates = @(
        "C:\Program Files (x86)\Steam\steamapps\common\Dawn of War Gold",
        "C:\Program Files (x86)\Steam\steamapps\common\Dawn of War Anniversary Edition",
        "C:\Program Files\Steam\steamapps\common\Dawn of War Gold",
        "D:\Steam\steamapps\common\Dawn of War Gold",
        "D:\SteamLibrary\steamapps\common\Dawn of War Gold"
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

$moduleDir = Join-Path $GamePath 'W40k'
if (-not (Test-Path $moduleDir)) {
    Write-Host "Папка модуля W40k не найдена ($moduleDir)." -ForegroundColor Red
    exit 1
}
$installDir = Join-Path $moduleDir 'Data\scenarios\sp'
$manifest   = Join-Path $moduleDir 'Data\fog-distance-manifest.txt'

# ---------- Rollback ----------
if ($Restore) {
    if (Test-Path $manifest) {
        $n = 0
        foreach ($f in Get-Content $manifest) {
            if ($f -and (Test-Path $f)) { Remove-Item $f -Force; $n++ }
        }
        Remove-Item $manifest -Force
        Write-Host "Удалено loose-карт: $n. Вернулись ванильные карты из архива." -ForegroundColor Green
        Write-Host "Старые сохранения кампании снова должны открываться." -ForegroundColor Green
    } else {
        Write-Host "Манифест не найден — фикс не установлен, откатывать нечего." -ForegroundColor Yellow
    }
    exit 0
}

# ---------- Patch ----------
Write-Host ("Дистанция тумана: {0} | радиус неба: {1}" -f `
    $FogDistance.ToString('0.#', $inv), $SkyRadius.ToString('0.#', $inv)) -ForegroundColor Cyan

# Patches a map buffer in place. Returns a report string, or $null if chunks are missing.
function Patch-MapBuffer([byte[]]$d, [string]$label) {
    $effc = [Chunky]::Find($d, 'EFFC')
    $hrzn = [Chunky]::Find($d, 'HRZN')
    if ($effc -lt 0 -or $hrzn -lt 0) {
        Write-Host "  [..] $label — нет EFFC/HRZN, пропуск" -ForegroundColor Yellow
        return $null
    }
    # EFFC: fog distance float at +40
    $fogOff = $effc + 40
    if ($fogOff + 4 -gt $d.Length) { Write-Host "  [!!] $label — EFFC обрезан" -ForegroundColor Red; return $null }
    $oldFog = [BitConverter]::ToSingle($d, $fogOff)
    [Array]::Copy([BitConverter]::GetBytes([float]$FogDistance), 0, $d, $fogOff, 4)

    # HRZN: uint32 nameLen | name | sky radius float
    $nameLen = [BitConverter]::ToUInt32($d, $hrzn)
    if ($nameLen -gt 256) { Write-Host "  [!!] $label — подозрительная длина имени неба ($nameLen)" -ForegroundColor Red; return $null }
    $skyName = [Text.Encoding]::ASCII.GetString($d, $hrzn + 4, [int]$nameLen)
    $skyOff  = $hrzn + 4 + [int]$nameLen
    if ($skyOff + 4 -gt $d.Length) { Write-Host "  [!!] $label — HRZN обрезан" -ForegroundColor Red; return $null }
    $oldSky = [BitConverter]::ToSingle($d, $skyOff)
    [Array]::Copy([BitConverter]::GetBytes([float]$SkyRadius), 0, $d, $skyOff, 4)

    return ("туман {0} -> {1} | небо '{2}' {3} -> {4}" -f `
        $oldFog.ToString('0.#', $inv), $FogDistance.ToString('0.#', $inv),
        $skyName, $oldSky.ToString('0.#', $inv), $SkyRadius.ToString('0.#', $inv))
}

# Map source: the .sga archives inside the W40k module
$maps = @()   # @{ Name; Data }
$sgas = @(Get-ChildItem -Path $moduleDir -Filter '*.sga' -Recurse -ErrorAction SilentlyContinue)
foreach ($sga in $sgas) {
    try { $entries = [SgaV2R3]::ReadToc($sga.FullName) } catch { continue }
    foreach ($e in $entries) {
        if ($e.Path -notmatch '(?i)scenarios/sp/[^/]+\.sgb$') { continue }
        $nm = Split-Path ($e.Path -replace '/', '\') -Leaf
        if ($maps | Where-Object { $_.Name -eq $nm }) { continue }
        $maps += @{ Name = $nm; Data = [SgaV2R3]::ReadFileData($sga.FullName, $e); From = $sga.Name }
    }
}
if ($maps.Count -eq 0) {
    Write-Host "В архивах модуля W40k не найдено карт scenarios/sp/*.sgb." -ForegroundColor Yellow
    Write-Host "Проверьте, что это Anniversary Edition с оригинальной кампанией." -ForegroundColor Yellow
    exit 1
}
Write-Host "Найдено карт кампании: $($maps.Count)" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$written = @()
foreach ($m in $maps) {
    $rep = Patch-MapBuffer $m.Data $m.Name
    if (-not $rep) { continue }
    $out = Join-Path $installDir $m.Name
    [IO.File]::WriteAllBytes($out, $m.Data)
    $written += $out
    Write-Host ("  [OK] {0}: {1}" -f $m.Name, $rep) -ForegroundColor Green
}

if ($written.Count -eq 0) {
    Write-Host "Ни одна карта не пропатчена." -ForegroundColor Red
    exit 1
}
New-Item -ItemType Directory -Force -Path (Split-Path $manifest -Parent) | Out-Null
Set-Content -Path $manifest -Value $written -Encoding ASCII

Write-Host @"

Готово: пропатчено карт $($written.Count) -> $installDir
Оригинальные архивы не изменены (loose-файлы поверх архива).
Откат: .\Install-FogDistance.ps1 -Restore

ВНИМАНИЕ: сейвы текущей кампании при активном фиксе могут не открываться.
Это обратимо — сделайте -Restore, и старые сохранения снова заработают.
Рекомендуется включать фикс на новой кампании.
"@ -ForegroundColor Cyan
