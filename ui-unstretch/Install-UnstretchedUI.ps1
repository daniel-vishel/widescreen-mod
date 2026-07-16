# ============================================================
#  Dawn of War (Anniversary Edition) - Unstretched UI
#  Нерастянутый интерфейс для широких экранов (21:9 и др.).
#
#  Принцип: разметка интерфейса лежит в Engine.sga ->
#  data/art/ui/screens/*.screen (Lua-таблицы, координаты в долях
#  экрана). Скрипт извлекает разметку ИЗ ВАШЕГО архива, сжимает
#  панели HUD по горизонтали с коэффициентом k = (4/3)/(ширина/высота)
#  (пропорции как на 4:3, мини-карта не искажена) и разносит их по
#  углам: левые панели — к левому краю, правые — к правому, центр —
#  по центру. Фоновые текстуры баров (одна картинка на всю ширину)
#  режутся на ломтики по границам зон и разъезжаются вместе со своими
#  кнопками. 3D-мир (ctmSimVis) растягивается на весь экран (в
#  оригинале он рендерится только над панелью задач — верхние ~80%
#  высоты).
#
#  Оригинальные файлы игры НЕ изменяются: результат кладётся
#  loose-файлом в <игра>\Engine\Data поверх архива.
#  Откат: -Restore (удаляет установленные файлы по манифесту).
#
#  Использование:
#      .\Install-UnstretchedUI.ps1                    # 3440x1440, только игровой HUD
#      .\Install-UnstretchedUI.ps1 -Width 2560 -Height 1080
#      .\Install-UnstretchedUI.ps1 -AllScreens        # + все меню (экспериментально)
#      .\Install-UnstretchedUI.ps1 -Restore           # откат
# ============================================================

param(
    [int]$Width  = 3440,
    [int]$Height = 1440,
    [string]$GamePath = '',
    [switch]$AllScreens,   # преобразовать все *.screen (меню), а не только игровой HUD
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------- C#: чтение SGA v2 + парсер/трансформер .screen ----------
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Text;

public class SgaEntry {
    public string Path;
    public uint CompFlag;
    public long DataOffset;
    public int  CompSize;
    public int  DecompSize;
}

public static class SgaV2R {
    static ushort U16(byte[] b, long o) { return BitConverter.ToUInt16(b, (int)o); }
    static uint   U32(byte[] b, long o) { return BitConverter.ToUInt32(b, (int)o); }
    static string CStr(byte[] b, long start) {
        long end = start;
        while (end < b.Length && b[end] != 0) end++;
        return Encoding.ASCII.GetString(b, (int)start, (int)(end - start));
    }
    public static List<SgaEntry> ReadToc(string path) {
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
        var result = new List<SgaEntry>();
        for (int d = 0; d < dirCnt; d++) {
            long e = dirOff + d * 12;
            string dir = CStr(b, nameOff + U32(b, e)).Replace('\\', '/');
            int fs = U16(b, e + 8), fe = U16(b, e + 10);
            for (int f = fs; f < fe; f++) {
                long fe2 = fileOff + f * 20;
                var it = new SgaEntry();
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
    public static byte[] ReadFileData(string archivePath, SgaEntry e) {
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

// ----- Парсер Lua-таблиц формата .screen -----
public class LNode {
    public string Key;                 // null для безымянных элементов
    public bool IsTable;
    public string Scalar;              // сырой скаляр: "строка", число, true/false
    public List<LNode> Items = new List<LNode>();
    public LNode Get(string key) {
        foreach (var n in Items) if (n.Key == key) return n;
        return null;
    }
    public string GetStr(string key) {
        var n = Get(key);
        if (n == null || n.Scalar == null) return null;
        return n.Scalar.Trim('"');
    }
}

public static class ScreenFile {
    static string _s; static int _p;
    public static int Patched;

    public static LNode Parse(string text) {
        _s = text; _p = 0;
        var root = new LNode { IsTable = true };
        SkipWs();
        while (_p < _s.Length) {
            string id = ReadIdent();
            SkipWs(); Expect('='); SkipWs();
            var v = ReadValue(); v.Key = id;
            root.Items.Add(v);
            SkipWs();
        }
        return root;
    }

    static void SkipWs() {
        while (_p < _s.Length) {
            char c = _s[_p];
            if (char.IsWhiteSpace(c)) { _p++; continue; }
            if (c == '-' && _p + 1 < _s.Length && _s[_p + 1] == '-') {
                while (_p < _s.Length && _s[_p] != '\n') _p++;
                continue;
            }
            break;
        }
    }
    static string ReadIdent() {
        int st = _p;
        while (_p < _s.Length && (char.IsLetterOrDigit(_s[_p]) || _s[_p] == '_')) _p++;
        if (st == _p) throw new Exception("identifier expected at offset " + _p);
        return _s.Substring(st, _p - st);
    }
    static void Expect(char c) {
        if (_p >= _s.Length || _s[_p] != c) throw new Exception(c + " expected at offset " + _p);
        _p++;
    }
    static LNode ReadValue() {
        SkipWs();
        char c = _s[_p];
        if (c == '{') {
            _p++;
            var t = new LNode { IsTable = true };
            SkipWs();
            while (_s[_p] != '}') {
                LNode item;
                int save = _p;
                if (char.IsLetter(_s[_p]) || _s[_p] == '_') {
                    string id = ReadIdent(); SkipWs();
                    if (_p < _s.Length && _s[_p] == '=') {
                        _p++;
                        item = ReadValue();
                        item.Key = id;
                    } else { _p = save; item = ReadValue(); }
                } else item = ReadValue();
                t.Items.Add(item);
                SkipWs();
                if (_p < _s.Length && _s[_p] == ',') { _p++; SkipWs(); }
            }
            _p++;
            return t;
        }
        if (c == '"') {
            int st = _p; _p++;
            while (_s[_p] != '"') { if (_s[_p] == '\\') _p++; _p++; }
            _p++;
            return new LNode { Scalar = _s.Substring(st, _p - st) };
        }
        {
            int st = _p;
            while (_p < _s.Length && !char.IsWhiteSpace(_s[_p]) && _s[_p] != ',' && _s[_p] != '}') _p++;
            return new LNode { Scalar = _s.Substring(st, _p - st) };
        }
    }

    public static string Serialize(LNode root) {
        var sb = new StringBuilder();
        foreach (var n in root.Items) {
            sb.Append(n.Key).Append(" = ");
            WriteVal(sb, n, 0);
            sb.Append("\n");
        }
        return sb.ToString();
    }
    static void WriteVal(StringBuilder sb, LNode n, int ind) {
        if (!n.IsTable) { sb.Append(n.Scalar); return; }
        sb.Append("\n");
        Indent(sb, ind); sb.Append("{\n");
        foreach (var it in n.Items) {
            Indent(sb, ind + 1);
            if (it.Key != null) sb.Append(it.Key).Append(" = ");
            WriteVal(sb, it, ind + 1);
            sb.Append(",\n");
        }
        Indent(sb, ind); sb.Append("}");
    }
    static void Indent(StringBuilder sb, int n) { for (int i = 0; i < n; i++) sb.Append('\t'); }

    // ----- Преобразование под широкий экран -----
    // Боксы виджетов заданы в долях экрана, позиция — смещение от
    // родителя. Примитивы (Graphic/Text/HitArea) — в долях родителя,
    // их не трогаем.
    //
    // Полноширинные контейнеры (ширина ~1, x ~0: grpBackground,
    // grpTaskbar, grpMenubar, grpWarnings) не сжимаются — обходим их
    // детей. Остальные панели сжимаются по x с коэффициентом k и
    // якорятся по положению своего центра на 4:3:
    //   центр < 1/3  -> к левому краю   (x' = x*k)
    //   центр > 2/3  -> к правому краю  (x' = x*k + 1-k)
    //   иначе        -> по центру       (x' = x*k + (1-k)/2)
    // Вложенные виджеты — чистое масштабирование x*k.
    //
    // Expand — растянуть на весь экран (3D-мир ctmSimVis: в оригинале
    // рендерится только над панелью задач, верхние ~80% высоты).
    // Keep — не трогать. Force* — ручное переопределение стороны для
    // пограничных случаев.
    public static string[] Keep        = new string[0];
    public static string[] Expand      = new string[0];
    public static string[] ForceLeft   = new string[0];
    public static string[] ForceCenter = new string[0];
    public static string[] ForceRight  = new string[0];
    // Жёсткое переопределение экранной x-позиции виджета (доля экрана).
    // Для случаев, когда автосжатие ставит виджет не туда (напр. кнопки
    // «след. юнит»/overwatch, наезжающие на ромб мини-карты). Размер
    // всё равно масштабируется на k (чтобы кнопки остались квадратными).
    public static System.Collections.Generic.Dictionary<string,double> ForcePosX =
        new System.Collections.Generic.Dictionary<string,double>(StringComparer.OrdinalIgnoreCase);

    public static void Transform(LNode fileRoot, double k) {
        Patched = 0;
        foreach (var asg in fileRoot.Items) {
            if (!asg.IsTable) continue;
            foreach (var sub in asg.Items) {
                if (sub.IsTable && (sub.Key == "Widgets" || sub.Key == "TooltipWidgets")) {
                    TransformChildren(sub, k, true);
                }
            }
        }
    }
    static void TransformChildren(LNode widget, double k, bool anchorMode) {
        var children = widget.Get("Children");
        if (children == null || !children.IsTable) return;
        foreach (var ch in children.Items) {
            if (!ch.IsTable) continue;
            TransformWidget(ch, k, anchorMode);
        }
    }
    static bool In(string[] arr, string name) {
        if (name == null) return false;
        foreach (var s in arr) if (string.Equals(s, name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }
    static double GetX(LNode t, double dflt) {
        if (t == null || !t.IsTable || t.Items.Count < 1) return dflt;
        double v;
        if (t.Items[0].Scalar != null &&
            double.TryParse(t.Items[0].Scalar, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return v;
        return dflt;
    }
    static void TransformWidget(LNode w, double k, bool anchorMode) {
        string name = w.GetStr("name");
        if (In(Expand, name)) { SetFullScreen(w); return; }
        if (In(Keep, name)) { TransformChildren(w, k, anchorMode); return; }
        if (name != null && ForcePosX.ContainsKey(name)) {
            var pp = w.Get("position");
            if (pp != null && pp.IsTable && pp.Items.Count >= 1)
                pp.Items[0].Scalar = ForcePosX[name].ToString("0.#####", CultureInfo.InvariantCulture);
            ScaleX(w.Get("size"), k, 0.0);
            Patched++;
            TransformChildren(w, k, false);
            return;
        }
        double x  = GetX(w.Get("position"), 0.0);
        double sx = GetX(w.Get("size"), double.NaN);
        if (anchorMode && !double.IsNaN(sx) && sx >= 0.95 && Math.Abs(x) <= 0.02) {
            TransformChildren(w, k, true);   // полноширинный контейнер: бокс не трогаем
            return;
        }
        double add = 0.0;
        if (anchorMode) {
            double c = x + (double.IsNaN(sx) ? 0.0 : sx * 0.5);
            if      (In(ForceLeft, name))   add = 0.0;
            else if (In(ForceCenter, name)) add = (1.0 - k) * 0.5;
            else if (In(ForceRight, name))  add = 1.0 - k;
            else if (c < 1.0 / 3.0)         add = 0.0;
            else if (c > 2.0 / 3.0)         add = 1.0 - k;
            else                            add = (1.0 - k) * 0.5;
        }
        ScaleX(w.Get("position"), k, add);
        ScaleX(w.Get("size"), k, 0.0);
        Patched++;
        TransformChildren(w, k, false);
    }
    static void SetFullScreen(LNode w) {
        var p = w.Get("position");
        if (p != null && p.IsTable && p.Items.Count >= 2) {
            p.Items[0].Scalar = "0"; p.Items[1].Scalar = "0";
        }
        var s = w.Get("size");
        if (s != null && s.IsTable && s.Items.Count >= 2) {
            s.Items[0].Scalar = "1"; s.Items[1].Scalar = "1";
        }
    }
    static void ScaleX(LNode t, double k, double add) {
        if (t == null || !t.IsTable || t.Items.Count < 1) return;
        var x = t.Items[0];
        double v;
        if (x.Scalar != null &&
            double.TryParse(x.Scalar, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) {
            x.Scalar = (v * k + add).ToString("0.#####", CultureInfo.InvariantCulture);
        }
    }

    // ----- Служебное -----
    public static LNode Clone(LNode n) {
        var c = new LNode { Key = n.Key, IsTable = n.IsTable, Scalar = n.Scalar };
        foreach (var it in n.Items) c.Items.Add(Clone(it));
        return c;
    }

    // У части кнопок (CommandIcon01, Reinforce, Upgrade01, btnPlayback*)
    // в разметке нет ключа size — движок берёт размер из стиля, и наше
    // сжатие на них не действует: кнопки остаются широкими и наезжают
    // на соседей. Копируем size у соседа с тем же типом и тем же стилем.
    public static int InjectSizes(LNode root) {
        int c = 0;
        InjectRec(root, ref c);
        return c;
    }
    static void InjectRec(LNode n, ref int c) {
        if (!n.IsTable) return;
        if (n.Key == "Children") TryInjectList(n, ref c);
        foreach (var it in n.Items) InjectRec(it, ref c);
    }
    static bool HasNumSize(LNode w) {
        var s = w.Get("size");
        if (s == null || !s.IsTable || s.Items.Count < 2) return false;
        double v;
        return s.Items[0].Scalar != null &&
               double.TryParse(s.Items[0].Scalar, NumberStyles.Float, CultureInfo.InvariantCulture, out v);
    }
    static string StyleSig(LNode w) {
        var st = w.Get("style");
        if (st == null || !st.IsTable) return "";
        var sb = new StringBuilder();
        foreach (var it in st.Items) sb.Append(it.Scalar).Append('/');
        return sb.ToString();
    }
    static void TryInjectList(LNode children, ref int c) {
        foreach (var ch in children.Items) {
            if (!ch.IsTable || ch.GetStr("type") == null) continue;
            if (ch.Get("position") == null) continue;
            if (HasNumSize(ch)) continue;
            string type = ch.GetStr("type");
            string sig  = StyleSig(ch);
            if (sig.Length == 0) continue;
            LNode donor = null;
            foreach (var sib in children.Items) {
                if (ReferenceEquals(sib, ch) || !sib.IsTable || !HasNumSize(sib)) continue;
                if (sib.GetStr("type") == type && StyleSig(sib) == sig) { donor = sib; break; }
            }
            if (donor == null) continue;
            var old = ch.Get("size");
            if (old != null) ch.Items.Remove(old);
            ch.Items.Add(Clone(donor.Get("size")));
            c++;
        }
    }
}

// ----- Декодер DXT1/3/5 (для нарезки фоновых текстур баров) -----
public static class DxtDec {
    public static byte[] Decode(byte[] d, int off, int w, int h, string fmt) {
        byte[] outPx = new byte[w * h * 4]; // BGRA, сверху вниз
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

# ---------- Engine.sga и папка установки ----------
$engineSga = Get-ChildItem -Path $GamePath -Recurse -Filter 'Engine.sga' -ErrorAction SilentlyContinue |
             Select-Object -First 1
if (-not $engineSga) {
    Write-Host "Engine.sga не найден в папке игры." -ForegroundColor Red
    exit 1
}
$engineDir  = Split-Path $engineSga.FullName -Parent
$installDir = Join-Path $engineDir 'Data\art\ui\screens'
$manifest   = Join-Path $engineDir 'Data\ui-unstretch-manifest.txt'

# ---------- Откат ----------
if ($Restore) {
    if (Test-Path $manifest) {
        foreach ($f in Get-Content $manifest) {
            if ($f -and (Test-Path $f)) {
                Remove-Item $f -Force
                Write-Host "Удалён: $f" -ForegroundColor Green
            }
        }
        Remove-Item $manifest -Force
        Write-Host "UI вернулся к оригиналу (разметка снова читается из Engine.sga). Готово." -ForegroundColor Green
    } else {
        Write-Host "Манифест не найден — мод не установлен, откатывать нечего." -ForegroundColor Yellow
    }
    exit 0
}

# ---------- Преобразование ----------
$aspect = $Width / $Height
$k = (4.0 / 3.0) / $aspect
if ($k -ge 0.999) {
    Write-Host "Соотношение $Width x $Height не шире 4:3 — преобразование не требуется." -ForegroundColor Yellow
    exit 0
}
Write-Host ("Разрешение: {0}x{1} | k = {2}" -f $Width, $Height, $k.ToString('0.####', $inv)) -ForegroundColor Cyan

$entries = [SgaV2R]::ReadToc($engineSga.FullName)
$screens = @($entries | Where-Object { $_.Path -like '*art/ui/screens/*.screen' })
if (-not $AllScreens) {
    $screens = @($screens | Where-Object { $_.Path -like '*gamescreen.screen' })
}
if ($screens.Count -eq 0) {
    Write-Host "В Engine.sga не найдено файлов разметки (*.screen) — нестандартная версия игры?" -ForegroundColor Red
    exit 1
}
Write-Host "Файлов разметки к преобразованию: $($screens.Count)"

# ---------- Конфигурация якорения ----------
[ScreenFile]::Keep        = @('testBackground')          # не трогать
[ScreenFile]::Expand      = @('ctmSimVis')               # 3D-мир — на весь экран
[ScreenFile]::ForceLeft   = @()
# Пограничные случаи (центр виджета у порога 1/3 или 2/3):
[ScreenFile]::ForceRight  = @(
    'btnToggleTeamUI',        # парная к btnChatHistory (уходит вправо)
    # Панель выбора (центр нижнего бара) приклеивается к командной
    # карте справа — единый блок в правом углу, без обреза на стыке:
    'artTaskbar_ws2',         # центральный ломтик фона
    'grpStructureSelection', 'grpSingleSquadSelection', 'grpMultiSquadSelection',
    'grpSquadHold', 'grpAddOns', 'grpMultipage',
    'txtPlayerName', 'txtForceName', 'btnHideTaskbar'
)
[ScreenFile]::ForceCenter = @('txtChatTeam','txtChatAll') # подписи прилегают к полю ввода чата

# Кнопки «след. юнит» и overwatch в стоке стоят справа от широкой
# мини-карты. После сжатия HUD они наезжают на ромб — пришпиливаем их
# правее правого угла ромба (ромб занимает x 0..~0.155), компактным
# столбцом на кромке. Значения — экранная x-доля (подбор по макету).
[ScreenFile]::ForcePosX['btnNextResearch']  = 0.163
[ScreenFile]::ForcePosX['btnNextBuilder']   = 0.163
[ScreenFile]::ForcePosX['btnNextMilitary']  = 0.185
[ScreenFile]::ForcePosX['btnOverwatchPause'] = 0.207
[ScreenFile]::ForcePosX['btnOverwatchStop']  = 0.207

# Разрезы фоновых текстур баров: границы функциональных зон (доли ширины).
# Нижний бар: гнездо мини-карты | панель отряда | сетка команд.
# Верхний бар: плашки ресурсов | (пусто) | полоса кнопок меню.
$barSlices = @(
    @{ Art = 'artTaskbar'; Cuts = @(0.0, 0.278, 0.630, 1.0) },
    @{ Art = 'artMenubar'; Cuts = @(0.0, 0.45, 1.0) }
)

# ---------- Вспомогательные функции нарезки ----------
function Get-Pow2([int]$n) { $p = 1; while ($p -lt $n) { $p *= 2 }; return $p }

function Write-Tga([string]$path, [byte[]]$px, [int]$w, [int]$h) {
    # $px — BGRA построчно в том же порядке, что и в исходном DDS.
    # Строки пишем КАК ЕСТЬ (top-down, флаг origin=top-left): порядок
    # строк в файле совпадает с DDS, и движок (который сэмплирует
    # текстуры с V-флипом, как и оригинальные DDS) рисует ломтик
    # так же, как рисовал цельный фон. Запись снизу-вверх давала
    # вертикально зеркальную картинку.
    $hdr = New-Object byte[] 18
    $hdr[2]  = 2                                     # несжатый truecolor
    $hdr[12] = $w -band 0xFF; $hdr[13] = ($w -shr 8) -band 0xFF
    $hdr[14] = $h -band 0xFF; $hdr[15] = ($h -shr 8) -band 0xFF
    $hdr[16] = 32; $hdr[17] = 0x28                   # 32bpp, 8 бит альфы, origin top-left
    $fs = [IO.File]::Create($path)
    try {
        $fs.Write($hdr, 0, 18)
        for ($y = 0; $y -lt $h; $y++) { $fs.Write($px, $y * $w * 4, $w * 4) }
    } finally { $fs.Close() }
}

function Find-WidgetInList($listNode, [string]$name) {
    for ($i = 0; $i -lt $listNode.Items.Count; $i++) {
        $ch = $listNode.Items[$i]
        if (-not $ch.IsTable) { continue }
        if ($ch.GetStr('name') -eq $name) { return @{ List = $listNode; Index = $i; Node = $ch } }
        $kids = $ch.Get('Children')
        if ($kids -and $kids.IsTable) {
            $r = Find-WidgetInList $kids $name
            if ($r) { return $r }
        }
    }
    return $null
}
function Find-Widget($tree, [string]$name) {
    foreach ($asg in $tree.Items) {
        if (-not $asg.IsTable) { continue }
        foreach ($sub in $asg.Items) {
            if ($sub.IsTable -and ($sub.Key -eq 'Widgets' -or $sub.Key -eq 'TooltipWidgets')) {
                $kids = $sub.Get('Children')
                if ($kids -and $kids.IsTable) {
                    $r = Find-WidgetInList $kids $name
                    if ($r) { return $r }
                }
            }
        }
    }
    return $null
}
function Ensure-Table($w, [string]$key) {
    $t = $w.Get($key)
    if (-not $t) {
        $t = New-Object LNode; $t.Key = $key; $t.IsTable = $true
        $w.Items.Add($t)
    }
    return $t
}
function Set-X($t, [string]$x) {
    while ($t.Items.Count -lt 2) { $n = New-Object LNode; $n.Scalar = '0'; $t.Items.Add($n) }
    $t.Items[0].Scalar = $x
}

# Нарезка фоновой текстуры бара. Фон нарисован одной картинкой на всю
# ширину, поэтому просто разнести виджеты по углам нельзя — фон остался
# бы единым куском. Режем текстуру по границам зон на ломтики (для всех
# рас: chaos/eldar/orks/taskbar_share), кладём loose-файлами, а виджет
# фона заменяем на ломтики-виджеты, которые разъезжаются по углам вместе
# со своими кнопками. Паддинг до степени двойки компенсируется шириной
# отрисовки (P/cw), прозрачный хвост свисает за боксом — не виден.
function Split-BarArt($tree, $entries, [string]$sgaPath, [string]$engineDir, [double[]]$cuts, [string]$artName) {
    $found = Find-Widget $tree $artName
    if (-not $found) { return ,@() }
    $w = $found.Node
    $pres = $w.Get('Presentation'); $art = $null
    if ($pres) { $art = $pres.Get('Art') }
    if (-not $art -or $art.Items.Count -ne 1) {
        Write-Host "  [..] $artName — нестандартный блок Art, нарезка пропущена" -ForegroundColor Yellow
        return ,@()
    }
    $g = $art.Items[0]
    $texPath = $g.GetStr('texture')                       # art/ui/textures/taskbar/taskbar_share/<base>.tga
    $base = [IO.Path]::GetFileNameWithoutExtension($texPath)
    $texRefDir = $texPath -replace '/[^/]+$', ''
    $origId = 0; [void][int]::TryParse($g.GetStr('ID'), [ref]$origId)

    $srcs = @($entries | Where-Object { $_.Path -match "textures/taskbar/[^/]+/$base\.dds$" })
    if ($srcs.Count -eq 0) {
        Write-Host "  [..] $base.dds не найден в архиве, нарезка пропущена" -ForegroundColor Yellow
        return ,@()
    }

    # метрики ломтиков — по share-текстуре (или первой найденной)
    $metaSrc = $srcs | Where-Object { $_.Path -like '*taskbar_share*' } | Select-Object -First 1
    if (-not $metaSrc) { $metaSrc = $srcs[0] }
    $d0 = [SgaV2R]::ReadFileData($sgaPath, $metaSrc)
    $metaW = [BitConverter]::ToInt32($d0, 16)
    $sliceMeta = @()
    for ($i = 0; $i -lt $cuts.Count - 1; $i++) {
        $x0 = [int][Math]::Round($cuts[$i] * $metaW); $x1 = [int][Math]::Round($cuts[$i+1] * $metaW)
        $cw = $x1 - $x0
        $sliceMeta += @{ x0 = $x0; cw = $cw; P = (Get-Pow2 $cw) }
    }

    # генерация текстур-ломтиков для каждой расы
    $written = @()
    foreach ($src in $srcs) {
        $d = [SgaV2R]::ReadFileData($sgaPath, $src)
        if ([Text.Encoding]::ASCII.GetString($d, 0, 4) -ne 'DDS ') { continue }
        $th = [BitConverter]::ToInt32($d, 12); $tw = [BitConverter]::ToInt32($d, 16)
        $fourcc = [Text.Encoding]::ASCII.GetString($d, 84, 4)
        if ($fourcc -notmatch 'DXT[135]') {
            Write-Host "  [..] $($src.Path): формат $fourcc не поддержан, пропуск" -ForegroundColor Yellow
            continue
        }
        if ($tw -ne $metaW) {
            Write-Host "  [..] $($src.Path): ширина $tw != $metaW, пропуск" -ForegroundColor Yellow
            continue
        }
        $px = [DxtDec]::Decode($d, 128, $tw, $th, $fourcc)
        $folder = ($src.Path -split '/')[-2]
        $outDir = Join-Path $engineDir "Data\art\ui\textures\taskbar\$folder"
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        for ($i = 0; $i -lt $sliceMeta.Count; $i++) {
            $m = $sliceMeta[$i]
            $buf = New-Object byte[] ($m.P * $th * 4)
            for ($y = 0; $y -lt $th; $y++) {
                [Array]::Copy($px, ($y * $tw + $m.x0) * 4, $buf, $y * $m.P * 4, $m.cw * 4)
            }
            $f = Join-Path $outDir ("{0}_ws{1}.tga" -f $base, ($i + 1))
            Write-Tga $f $buf $m.P $th
            $written += $f
        }
    }

    # замена виджета фона на ломтики (z-порядок сохраняется)
    $parentList = $found.List
    $parentList.Items.RemoveAt($found.Index)
    for ($i = $sliceMeta.Count - 1; $i -ge 0; $i--) {
        $a = $cuts[$i]; $b = $cuts[$i + 1]; $m = $sliceMeta[$i]
        $cl = [ScreenFile]::Clone($w)
        $cl.Get('name').Scalar = '"{0}_ws{1}"' -f $artName, ($i + 1)
        Set-X (Ensure-Table $cl 'position') $a.ToString('0.#####', $inv)
        Set-X (Ensure-Table $cl 'size') ($b - $a).ToString('0.#####', $inv)
        $cg = $cl.Get('Presentation').Get('Art').Items[0]
        $cg.Get('texture').Scalar = '"{0}/{1}_ws{2}.tga"' -f $texRefDir, $base, ($i + 1)
        Set-X (Ensure-Table $cg 'position') '0'
        Set-X (Ensure-Table $cg 'size') ($m.P / $m.cw).ToString('0.#####', $inv)
        $idn = $cg.Get('ID')
        if ($idn -and $origId -gt 0) { $idn.Scalar = [string]($origId * 10 + $i + 1) }
        $parentList.Items.Insert($found.Index, $cl)
    }
    return ,$written
}

New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$installed = @()
$failed = 0
foreach ($e in $screens) {
    $name = Split-Path ($e.Path -replace '/', '\') -Leaf
    try {
        $text = [Text.Encoding]::ASCII.GetString([SgaV2R]::ReadFileData($engineSga.FullName, $e))
        $tree = [ScreenFile]::Parse($text)
        $texFiles = @()
        if ($name -eq 'gamescreen.screen') {
            foreach ($bs in $barSlices) {
                $texFiles += Split-BarArt $tree $entries $engineSga.FullName $engineDir $bs.Cuts $bs.Art
            }
        }
        $injected = [ScreenFile]::InjectSizes($tree)
        [ScreenFile]::Transform($tree, $k)
        $out  = [ScreenFile]::Serialize($tree)
        [ScreenFile]::Parse($out) | Out-Null   # самопроверка: результат снова парсится
        $dest = Join-Path $installDir $name
        [IO.File]::WriteAllText($dest, $out, [Text.Encoding]::ASCII)
        $installed += $dest
        $installed += $texFiles
        Write-Host ("  [OK] {0} — виджетов: {1}, размеров добавлено: {2}, текстур нарезано: {3}" -f `
            $name, [ScreenFile]::Patched, $injected, $texFiles.Count) -ForegroundColor Green
    } catch {
        $failed++
        Write-Host "  [!!] $name — $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($installed.Count -gt 0) {
    $installed | Set-Content -Path $manifest -Encoding ASCII
}

Write-Host @"

================= ГОТОВО =================
Установлено файлов: $($installed.Count) (ошибок: $failed)
Куда: $installDir
Оригинальные архивы игры не изменялись.

Проверьте в игре (скирмиш):
 1) Панели HUD разнесены по углам: мини-карта и ресурсы слева;
    панель выбора, команды и кнопки меню — единым блоком справа.
 2) Пропорции панелей 4:3 (не растянуты), мини-карта не искажена.
 3) 3D-мир — во весь экран, между панелями виден мир.
 4) Клики по кнопкам попадают точно, командные кнопки не наезжают
    на соседние панели.

Откат:      .\Install-UnstretchedUI.ps1 -Restore
Все меню:   .\Install-UnstretchedUI.ps1 -AllScreens
==========================================
"@ -ForegroundColor Cyan
