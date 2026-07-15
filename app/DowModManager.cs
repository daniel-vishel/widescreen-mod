// ============================================================
//  Dawn of War — Mod Manager (WinForms, .NET Framework 4.8)
//  Графический менеджер модов. Вся тяжёлая логика (патч файлов,
//  распаковка SGA, нарезка/подгонка текстур, трансформ UI) живёт
//  в PowerShell-скриптах; приложение собирает настройки, читает
//  реальное состояние игры и вызывает DoW-Launcher.ps1.
//
//  Сборка: powershell -File app\Build-App.ps1
//  Самопроверка без окна: DoW-ModManager.exe --selftest
// ============================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DowModManager
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--selftest") { SelfTest.Run(); return; }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    // ---------- Тема оформления (берётся из системы) ----------
    class Theme
    {
        public bool Dark;
        public Color Bg, Fg, GroupFg, Muted, PanelBg, InputBg, InputFg, Accent, AccentFg, LogBg, LogFg, Border;

        public static Theme FromSystem()
        {
            bool dark = false;
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                {
                    if (k != null)
                    {
                        object v = k.GetValue("AppsUseLightTheme");
                        if (v is int) dark = ((int)v) == 0;
                    }
                }
            }
            catch { }
            return dark ? DarkTheme() : LightTheme();
        }

        static Theme LightTheme()
        {
            return new Theme
            {
                Dark = false,
                Bg = Color.FromArgb(245, 246, 248),
                Fg = Color.FromArgb(20, 22, 26),
                GroupFg = Color.FromArgb(40, 44, 52),
                Muted = Color.DimGray,
                PanelBg = Color.FromArgb(28, 32, 38),
                InputBg = Color.White,
                InputFg = Color.FromArgb(20, 22, 26),
                Accent = Color.FromArgb(52, 120, 200),
                AccentFg = Color.White,
                LogBg = Color.FromArgb(24, 26, 30),
                LogFg = Color.Gainsboro,
                Border = Color.FromArgb(200, 204, 210),
            };
        }

        static Theme DarkTheme()
        {
            return new Theme
            {
                Dark = true,
                Bg = Color.FromArgb(32, 34, 38),
                Fg = Color.FromArgb(232, 234, 238),
                GroupFg = Color.FromArgb(210, 214, 220),
                Muted = Color.FromArgb(150, 154, 160),
                PanelBg = Color.FromArgb(20, 22, 26),
                InputBg = Color.FromArgb(45, 48, 54),
                InputFg = Color.FromArgb(232, 234, 238),
                Accent = Color.FromArgb(58, 130, 214),
                AccentFg = Color.White,
                LogBg = Color.FromArgb(18, 20, 24),
                LogFg = Color.Gainsboro,
                Border = Color.FromArgb(70, 74, 80),
            };
        }
    }

    // ---------- Кружок со знаком вопроса; описание — во всплывающей подсказке ----------
    class HelpDot : Control
    {
        Theme th;
        bool hover;

        public HelpDot(Theme theme, ToolTip tip, string text)
        {
            th = theme;
            Size = new Size(18, 18);
            Cursor = Cursors.Help;
            SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint |
                     ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
            BackColor = Color.Transparent;
            tip.SetToolTip(this, text);
            MouseEnter += (s, e) => { hover = true; Invalidate(); };
            MouseLeave += (s, e) => { hover = false; Invalidate(); };
        }

        public void SetTheme(Theme theme) { th = theme; Invalidate(); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            Color ring = hover ? th.Accent : th.Muted;
            using (var b = new SolidBrush(hover ? Color.FromArgb(40, th.Accent) : Color.Transparent))
                g.FillEllipse(b, r);
            using (var p = new Pen(ring, 1.4f))
                g.DrawEllipse(p, r);
            using (var f = new Font("Segoe UI", 9f, FontStyle.Bold))
            using (var b = new SolidBrush(ring))
            {
                var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString("?", f, b, new RectangleF(0, 0, Width, Height + 1), sf);
            }
        }
    }

    // ---------- Настройки (совпадают с $S в DoW-Launcher.ps1) ----------
    class Settings
    {
        public string GamePath = "";
        public string Game = "W40k";          // W40k | WA
        public int Width = 3440;
        public int Height = 1440;
        public bool Widescreen = true;         // патч отрисовки + UI (единый комплект)
        public bool TexturesCustom = true;     // true = дорисованные, false = жёсткая обрезка
        public bool Zoom = true;
        public int DistMax = 76;
        public bool Russian = false;
        public string ExeMode = "skip";        // skip | compromise | full

        public Settings Clone() { return (Settings)MemberwiseClone(); }

        // Сравнение без GamePath: важно, изменил ли пользователь набор модов
        public bool SameAs(Settings o)
        {
            return Widescreen == o.Widescreen && Width == o.Width && Height == o.Height
                && TexturesCustom == o.TexturesCustom && Zoom == o.Zoom && DistMax == o.DistMax
                && Russian == o.Russian && ExeMode == o.ExeMode;
        }

        public static Settings Load(string path)
        {
            var s = new Settings();
            if (!File.Exists(path)) return s;
            try
            {
                string t = File.ReadAllText(path, Encoding.UTF8);
                s.GamePath       = JStr(t, "GamePath", s.GamePath);
                s.Game           = JStr(t, "Game", s.Game);
                s.Width          = JInt(t, "Width", s.Width);
                s.Height         = JInt(t, "Height", s.Height);
                s.Widescreen     = JBool(t, "Widescreen", s.Widescreen);
                s.TexturesCustom = JBool(t, "TexturesCustom", s.TexturesCustom);
                s.Zoom           = JBool(t, "Zoom", s.Zoom);
                s.DistMax        = JInt(t, "DistMax", s.DistMax);
                s.Russian        = JBool(t, "Russian", s.Russian);
                s.ExeMode        = JStr(t, "ExeMode", s.ExeMode);
            }
            catch { }
            return s;
        }

        public void Save(string path)
        {
            var sb = new StringBuilder();
            sb.Append("{\r\n");
            sb.AppendFormat("  \"GamePath\": \"{0}\",\r\n", Esc(GamePath));
            sb.AppendFormat("  \"Game\": \"{0}\",\r\n", Esc(Game));
            sb.AppendFormat("  \"Width\": {0},\r\n", Width);
            sb.AppendFormat("  \"Height\": {0},\r\n", Height);
            sb.AppendFormat("  \"Widescreen\": {0},\r\n", B(Widescreen));
            sb.AppendFormat("  \"TexturesCustom\": {0},\r\n", B(TexturesCustom));
            sb.AppendFormat("  \"Zoom\": {0},\r\n", B(Zoom));
            sb.AppendFormat("  \"DistMax\": {0},\r\n", DistMax);
            sb.AppendFormat("  \"Russian\": {0},\r\n", B(Russian));
            sb.AppendFormat("  \"ExeMode\": \"{0}\"\r\n", Esc(ExeMode));
            sb.Append("}\r\n");
            File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
        }

        static string B(bool v) { return v ? "true" : "false"; }
        static string Esc(string s) { return (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\""); }
        public static string JStr(string t, string key, string def)
        {
            var m = Regex.Match(t, "\"" + key + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
            if (!m.Success) return def;
            return m.Groups[1].Value.Replace("\\\\", "\\").Replace("\\\"", "\"");
        }
        public static int JInt(string t, string key, int def)
        {
            var m = Regex.Match(t, "\"" + key + "\"\\s*:\\s*(-?\\d+)");
            int v; return (m.Success && int.TryParse(m.Groups[1].Value, out v)) ? v : def;
        }
        public static bool JBool(string t, string key, bool def)
        {
            var m = Regex.Match(t, "\"" + key + "\"\\s*:\\s*(true|false)", RegexOptions.IgnoreCase);
            return m.Success ? m.Groups[1].Value.ToLowerInvariant() == "true" : def;
        }
    }

    // ---------- Реальное состояние игры (из DoW-Launcher.ps1 -Status) ----------
    class GameStatus
    {
        public bool WidescreenPatched, UiInstalled, TexturesCustom, ZoomInstalled, LocaleRussian, LangRussian;
        public int Width, Height, DistMax;
        public bool Known;   // удалось ли прочитать состояние

        public static GameStatus Parse(string json)
        {
            var s = new GameStatus();
            if (string.IsNullOrWhiteSpace(json) || !json.Contains("{")) return s;
            s.WidescreenPatched = Settings.JBool(json, "WidescreenPatched", false);
            s.UiInstalled       = Settings.JBool(json, "UiInstalled", false);
            s.TexturesCustom    = Settings.JBool(json, "TexturesCustom", false);
            s.ZoomInstalled     = Settings.JBool(json, "ZoomInstalled", false);
            s.LocaleRussian     = Settings.JBool(json, "LocaleRussian", false);
            s.LangRussian       = Settings.JBool(json, "LangRussian", false);
            s.Width             = Settings.JInt(json, "Width", 0);
            s.Height            = Settings.JInt(json, "Height", 0);
            s.DistMax           = Settings.JInt(json, "DistMax", 0);
            s.Known = true;
            return s;
        }
    }

    // ---------- Автопоиск папки игры ----------
    static class GameFinder
    {
        public static string Find()
        {
            string[] candidates =
            {
                @"C:\Program Files (x86)\Steam\steamapps\common\Dawn of War Gold",
                @"C:\Program Files (x86)\Steam\steamapps\common\Dawn of War Anniversary Edition",
                @"C:\Program Files\Steam\steamapps\common\Dawn of War Gold",
                @"D:\Steam\steamapps\common\Dawn of War Gold",
                @"D:\SteamLibrary\steamapps\common\Dawn of War Gold",
                @"E:\Steam\steamapps\common\Dawn of War Gold",
                @"E:\SteamLibrary\steamapps\common\Dawn of War Gold",
            };
            foreach (var c in candidates)
                if (File.Exists(Path.Combine(c, "W40k.exe"))) return c;
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam"))
                {
                    string steam = key != null ? key.GetValue("SteamPath") as string : null;
                    if (!string.IsNullOrEmpty(steam))
                    {
                        string vdf = Path.Combine(steam, @"steamapps\libraryfolders.vdf");
                        if (File.Exists(vdf))
                        {
                            string t = File.ReadAllText(vdf);
                            foreach (Match m in Regex.Matches(t, "\"path\"\\s+\"(.+?)\""))
                            {
                                string lib = m.Groups[1].Value.Replace("\\\\", "\\");
                                foreach (var name in new[] { "Dawn of War Gold", "Dawn of War Anniversary Edition", "Dawn of War" })
                                {
                                    string p = Path.Combine(lib, @"steamapps\common\" + name);
                                    if (File.Exists(Path.Combine(p, "W40k.exe"))) return p;
                                }
                            }
                        }
                    }
                }
            }
            catch { }
            return null;
        }
    }

    // ---------- Тексты подсказок ----------
    static class Help
    {
        public const string Widescreen =
            "Расширяет обзор под ваш экран (честный FOV, не растяжение) и ставит нерастянутый UI.\r\n" +
            "Файлы игры патчатся на диске с полным бэкапом, поэтому после «Применить»\r\n" +
            "игра запускается ОБЫЧНЫМ способом из Steam — лаунчер для игры не нужен.\r\n" +
            "\r\n" +
            "Панели HUD не тянутся на всю ширину, а делятся и разъезжаются по углам экрана:\r\n" +
            "  • мини-карта и ресурсы — в левый нижний угол;\r\n" +
            "  • панель выбора отряда, команды и кнопки меню — в правый нижний угол;\r\n" +
            "  • центр экрана остаётся открытым — там виден 3D-мир.\r\n" +
            "\r\n" +
            "Отрисовка и UI работают только вместе: выключение снимает и UI-мод.";

        public const string ExeMode =
            "Режимы «Мини-карта (exe)» — как патчить константу соотношения в W40k.exe\r\n" +
            "(влияет только на мини-карту):\r\n" +
            "\r\n" +
            "  • skip (рекомендуется) — exe не трогаем; 3D-мир корректный, а квадратность\r\n" +
            "    мини-карты и так чинит UI-мод через разметку. Начинать с него.\r\n" +
            "\r\n" +
            "  • compromise — в exe пишется 1.25: помогает мини-карте у части версий,\r\n" +
            "    но искажает главное меню (в бою нормально).\r\n" +
            "\r\n" +
            "  • full — в exe полное соотношение: у кого-то мини-карта ок, но 3D-мир\r\n" +
            "    может растянуться. Крайний вариант.";

        public const string Textures =
            "Текстуры баров:\r\n" +
            "\r\n" +
            "  • дорисованные — сторонние текстуры с плавным/аккуратным краем\r\n" +
            "    (лежат в ui-unstretch\\textures-custom; на данный момент реализованы\r\n" +
            "    только для космического десанта).\r\n" +
            "\r\n" +
            "  • жёсткая обрезка — стандартные текстуры: они обрезаны по границе с картой,\r\n" +
            "    части раздвигаются по углам, и на стыках виден резкий обрыв картинки\r\n" +
            "    когда-то цельной панели.";

        public const string Zoom =
            "Отодвигает максимальный отвод камеры колёсиком (DistMax; оригинал 38).\r\n" +
            "Требует включённой «Full 3D Camera» в настройках графики игры.\r\n" +
            "Чем больше значение, тем сильнее дальний план затягивает туманом.";

        public const string Russian =
            "Ставит русский язык: прописывает [lang:russian] в W40k.ini (с резервной копией).\r\n" +
            "\r\n" +
            "Самих файлов русификатора в игре по умолчанию нет — их нужно скачать\r\n" +
            "отдельно (ссылки в README) и указать архив ниже: менеджер распакует его\r\n" +
            "в папку игры. В репозитории этих файлов нет: это чужой контент,\r\n" +
            "раздавать его вместе с модом нельзя.\r\n" +
            "\r\n" +
            "Если русификатор уже стоял до менеджера — он это увидит сам,\r\n" +
            "и архив указывать не потребуется.";

        public const string GamePath =
            "Папка, где лежит W40k.exe (например ...\\steamapps\\common\\Dawn of War Gold).\r\n" +
            "Обычно определяется автоматически по реестру Steam и библиотекам.";
    }

    // ---------- Главное окно ----------
    class MainForm : Form
    {
        Settings S;              // то, что показано в окне
        Settings applied;        // то, что реально стоит в игре (снимок)
        GameStatus status = new GameStatus();
        Theme th;

        readonly string root, launcher, cfgPath;
        string rusArchive = "";

        TextBox txtPath, log, txtRus;
        ComboBox cmbGame, cmbRes, cmbExe;
        NumericUpDown numW, numH, numDist;
        CheckBox chkWs, chkZoom, chkRus;
        RadioButton radCustom, radHard;
        Button btnApply, btnPlay, btnRestore, btnDefaults, btnRusBrowse, btnLogToggle;
        Label lblRusState, lblStatus;
        Panel header;
        ToolTip tip;
        List<HelpDot> dots = new List<HelpDot>();
        bool busy, loading, logVisible = true;
        int formHeightWithLog, formHeightNoLog;

        public MainForm()
        {
            root = ResolveRoot();
            launcher = Path.Combine(root, "DoW-Launcher.ps1");
            cfgPath = Path.Combine(root, "launcher-settings.json");
            th = Theme.FromSystem();
            S = Settings.Load(cfgPath);
            if (string.IsNullOrEmpty(S.GamePath))
            {
                string auto = GameFinder.Find();
                if (auto != null) S.GamePath = auto;
            }
            applied = S.Clone();
            BuildUi();
            Load += (s, e) => RefreshStatus();
        }

        static string ResolveRoot()
        {
            string dir = Application.StartupPath;
            if (File.Exists(Path.Combine(dir, "DoW-Launcher.ps1"))) return dir;
            string parent = Directory.GetParent(dir) != null ? Directory.GetParent(dir).FullName : dir;
            if (File.Exists(Path.Combine(parent, "DoW-Launcher.ps1"))) return parent;
            return dir;
        }

        void BuildUi()
        {
            Text = "Dawn of War — Mod Manager";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9f);
            BackColor = th.Bg;
            ForeColor = th.Fg;
            Width = 688;

            string ico = Path.Combine(root, @"app\app.ico");
            if (File.Exists(ico)) { try { Icon = new Icon(ico); } catch { } }

            tip = new ToolTip { AutoPopDelay = 32000, InitialDelay = 250, ReshowDelay = 80, ShowAlways = true };

            // --- Шапка: картинка app\header.png, иначе текст ---
            header = new Panel { Location = new Point(0, 0), Size = new Size(688, 64), BackColor = th.PanelBg };
            string hdrImg = Path.Combine(root, @"app\header.png");
            if (File.Exists(hdrImg))
            {
                try
                {
                    var pb = new PictureBox
                    {
                        Image = Image.FromFile(hdrImg),
                        SizeMode = PictureBoxSizeMode.Zoom,
                        Dock = DockStyle.Fill,
                        BackColor = th.PanelBg
                    };
                    header.Controls.Add(pb);
                }
                catch { AddHeaderText(); }
            }
            else AddHeaderText();
            Controls.Add(header);

            int y = 76;

            // --- Игра ---
            var grpGame = Group("Игра", 12, y, 660, 84);
            txtPath = Input(14, 24, 470);
            txtPath.Text = S.GamePath;
            txtPath.TextChanged += (s, e) => { if (!loading) MarkDirty(); };
            var dotPath = Dot(490, 27, Help.GamePath);
            var btnBrowse = Btn("Обзор…", 514, 22, 130, 26, (s, e) =>
            {
                using (var d = new FolderBrowserDialog { Description = "Папка с игрой (где лежит W40k.exe)" })
                    if (d.ShowDialog() == DialogResult.OK) { txtPath.Text = d.SelectedPath; RefreshStatus(); }
            });
            var btnAuto = Btn("Найти автоматически", 14, 52, 170, 24, (s, e) =>
            {
                string p = GameFinder.Find();
                if (p != null) { txtPath.Text = p; Log("Найдена игра: " + p); RefreshStatus(); }
                else Log("[!] Автопоиск не нашёл игру — укажите папку вручную.");
            });
            var lblGame = Lbl("Издание:", 380, 56);
            cmbGame = Combo(450, 52, 194, new object[] { "Базовая игра", "Winter Assault" });
            cmbGame.SelectedIndex = S.Game == "WA" ? 1 : 0;
            grpGame.Controls.AddRange(new Control[] { txtPath, dotPath, btnBrowse, btnAuto, lblGame, cmbGame });
            Controls.Add(grpGame);
            y += 92;

            // --- Widescreen + UI ---
            var grpWs = Group("Widescreen-отрисовка + нерастянутый UI (единый комплект)", 12, y, 660, 122);
            chkWs = Check("Включить отрисовку под разрешение (UI ставится автоматически)", 14, 24, 560);
            chkWs.Checked = S.Widescreen;
            var dotWs = Dot(580, 26, Help.Widescreen);
            chkWs.CheckedChanged += (s, e) => { ToggleWs(); if (!loading) MarkDirty(); };

            var lblRes = Lbl("Разрешение:", 14, 56);
            cmbRes = Combo(110, 52, 130, new object[] { "3440x1440", "2560x1080", "3840x1600", "5120x1440", "2560x1440", "1920x1080", "другое" });
            numW = Num(250, 52, 80, 640, 10000, S.Width);
            var lblX = Lbl("×", 334, 56);
            numH = Num(352, 52, 80, 480, 5000, S.Height);
            string preset = S.Width + "x" + S.Height;
            cmbRes.SelectedItem = cmbRes.Items.Contains(preset) ? preset : "другое";
            cmbRes.SelectedIndexChanged += (s, e) =>
            {
                var m = Regex.Match(cmbRes.SelectedItem.ToString(), "^(\\d+)x(\\d+)$");
                if (m.Success) { numW.Value = int.Parse(m.Groups[1].Value); numH.Value = int.Parse(m.Groups[2].Value); }
            };
            numW.ValueChanged += (s, e) => { if (!loading) MarkDirty(); };
            numH.ValueChanged += (s, e) => { if (!loading) MarkDirty(); };

            var lblExe = Lbl("Мини-карта (exe):", 452, 56);
            cmbExe = Combo(452, 76, 170, new object[] { "skip", "compromise", "full" });
            cmbExe.SelectedItem = new[] { "skip", "compromise", "full" }.Contains(S.ExeMode) ? S.ExeMode : "skip";
            cmbExe.SelectedIndexChanged += (s, e) => { if (!loading) MarkDirty(); };
            var dotExe = Dot(628, 79, Help.ExeMode);

            var lblTex = Lbl("Текстуры баров:", 14, 90);
            radCustom = Radio("дорисованные", 130, 88, 140);
            radHard = Radio("жёсткая обрезка", 280, 88, 150);
            radCustom.Checked = S.TexturesCustom; radHard.Checked = !S.TexturesCustom;
            radCustom.CheckedChanged += (s, e) => { if (!loading) MarkDirty(); };
            var dotTex = Dot(432, 91, Help.Textures);

            grpWs.Controls.AddRange(new Control[] { chkWs, dotWs, lblRes, cmbRes, numW, lblX, numH,
                lblExe, cmbExe, dotExe, lblTex, radCustom, radHard, dotTex });
            Controls.Add(grpWs);
            y += 130;

            // --- Камера ---
            var grpCam = Group("Камера", 12, y, 660, 56);
            chkZoom = Check("Улучшенный зум (отвод колёсиком дальше), DistMax:", 14, 24, 330);
            chkZoom.Checked = S.Zoom;
            chkZoom.CheckedChanged += (s, e) => { numDist.Enabled = chkZoom.Checked; if (!loading) MarkDirty(); };
            numDist = Num(350, 22, 80, 38, 300, S.DistMax);
            numDist.ValueChanged += (s, e) => { if (!loading) MarkDirty(); };
            var dotZoom = Dot(440, 26, Help.Zoom);
            grpCam.Controls.AddRange(new Control[] { chkZoom, numDist, dotZoom });
            Controls.Add(grpCam);
            y += 64;

            // --- Язык ---
            var grpLang = Group("Язык", 12, y, 660, 88);
            chkRus = Check("Русский язык", 14, 22, 130);
            chkRus.Checked = S.Russian;
            chkRus.CheckedChanged += (s, e) => { UpdateRusUi(); if (!loading) MarkDirty(); };
            var dotRus = Dot(150, 24, Help.Russian);
            lblRusState = Lbl("", 180, 24);
            lblRusState.AutoSize = false;
            lblRusState.Size = new Size(460, 18);
            txtRus = Input(14, 52, 470);
            txtRus.ReadOnly = true;
            tip.SetToolTip(txtRus, "Архив русификатора (zip/rar/7z), скачанный по ссылкам из README.\r\nБудет распакован в папку игры при нажатии «Применить».");
            btnRusBrowse = Btn("Указать архив…", 494, 50, 150, 26, (s, e) =>
            {
                using (var d = new OpenFileDialog { Title = "Архив русификатора", Filter = "Архивы (*.zip;*.rar;*.7z)|*.zip;*.rar;*.7z|Все файлы (*.*)|*.*" })
                    if (d.ShowDialog() == DialogResult.OK)
                    {
                        rusArchive = d.FileName;
                        txtRus.Text = d.FileName;
                        MarkDirty();
                    }
            });
            grpLang.Controls.AddRange(new Control[] { chkRus, dotRus, lblRusState, txtRus, btnRusBrowse });
            Controls.Add(grpLang);
            y += 96;

            // --- Кнопки ---
            btnApply = Btn("Применить", 12, y, 140, 34, (s, e) => Run("apply"));
            btnPlay = Btn("Применить и играть", 160, y, 180, 34, (s, e) => Run("launch"));
            btnPlay.Font = new Font("Segoe UI Semibold", 9.5f, FontStyle.Bold);
            btnPlay.FlatStyle = FlatStyle.Flat;
            btnDefaults = Btn("По умолчанию", 388, y, 140, 34, (s, e) => ResetToDefaults());
            tip.SetToolTip(btnDefaults, "Вернуть параметры окна к рекомендуемым значениям\r\n(3440×1440, widescreen+UI, дорисованные текстуры, зум 76, exe: skip).\r\nНа игру это не влияет, пока не нажать «Применить».");
            btnRestore = Btn("Откат", 536, y, 136, 34, (s, e) => Run("restore"));
            tip.SetToolTip(btnRestore, "Возвращает файлы игры к оригиналу и снимает все галочки в окне.\r\nФайлы русификатора при этом не удаляются — только язык вернётся на английский.");
            Controls.AddRange(new Control[] { btnApply, btnPlay, btnDefaults, btnRestore });
            y += 42;

            // --- Статус + переключатель лога ---
            lblStatus = Lbl("", 12, y + 6);
            lblStatus.AutoSize = false;
            lblStatus.Size = new Size(520, 20);
            btnLogToggle = Btn("Скрыть лог ▲", 536, y, 136, 26, (s, e) => ToggleLog());
            Controls.AddRange(new Control[] { lblStatus, btnLogToggle });
            y += 32;

            // --- Лог ---
            log = new TextBox
            {
                Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical,
                Location = new Point(12, y), Size = new Size(660, 220),
                Font = new Font("Consolas", 8.5f), BackColor = th.LogBg, ForeColor = th.LogFg,
                BorderStyle = BorderStyle.FixedSingle
            };
            Controls.Add(log);

            formHeightWithLog = y + 220 + 48;
            formHeightNoLog = y + 12 + 48;
            Height = formHeightWithLog;

            ToggleWs();
            numDist.Enabled = chkZoom.Checked;
            UpdateRusUi();
            ApplyTheme();

            if (!Directory.Exists(Path.Combine(root, @"ui-unstretch\textures-custom")))
            {
                radCustom.Enabled = false; radHard.Checked = true;
                Log("textures-custom не найдены — доступна только жёсткая обрезка.");
            }
            if (!File.Exists(launcher))
                Log("[!] Не найден DoW-Launcher.ps1 рядом с приложением (" + root + ").");
        }

        void AddHeaderText()
        {
            var title = new Label
            {
                Text = "Dawn of War — Mod Manager",
                ForeColor = Color.Gainsboro,
                Font = new Font("Segoe UI Semibold", 13f, FontStyle.Bold),
                Location = new Point(16, 18), AutoSize = true, BackColor = Color.Transparent
            };
            header.Controls.Add(title);
        }

        // ---------- Фабрики контролов ----------
        GroupBox Group(string text, int x, int y, int w, int h)
        {
            return new GroupBox { Text = text, Location = new Point(x, y), Size = new Size(w, h), ForeColor = th.GroupFg };
        }
        Button Btn(string text, int x, int y, int w, int h, EventHandler onClick)
        {
            var b = new Button { Text = text, Location = new Point(x, y), Size = new Size(w, h) };
            b.Click += onClick;
            return b;
        }
        Label Lbl(string text, int x, int y)
        {
            return new Label { Text = text, Location = new Point(x, y), AutoSize = true, ForeColor = th.Fg };
        }
        CheckBox Check(string text, int x, int y, int w)
        {
            return new CheckBox { Text = text, Location = new Point(x, y), Size = new Size(w, 22), ForeColor = th.Fg };
        }
        RadioButton Radio(string text, int x, int y, int w)
        {
            return new RadioButton { Text = text, Location = new Point(x, y), Size = new Size(w, 22), ForeColor = th.Fg };
        }
        TextBox Input(int x, int y, int w)
        {
            return new TextBox { Location = new Point(x, y), Size = new Size(w, 24), BackColor = th.InputBg, ForeColor = th.InputFg, BorderStyle = BorderStyle.FixedSingle };
        }
        ComboBox Combo(int x, int y, int w, object[] items)
        {
            var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Location = new Point(x, y), Size = new Size(w, 24), BackColor = th.InputBg, ForeColor = th.InputFg, FlatStyle = th.Dark ? FlatStyle.Flat : FlatStyle.Standard };
            c.Items.AddRange(items);
            return c;
        }
        NumericUpDown Num(int x, int y, int w, int min, int max, int val)
        {
            return new NumericUpDown { Location = new Point(x, y), Size = new Size(w, 24), Minimum = min, Maximum = max, Value = Math.Min(Math.Max(val, min), max), BackColor = th.InputBg, ForeColor = th.InputFg, BorderStyle = BorderStyle.FixedSingle };
        }
        HelpDot Dot(int x, int y, string text)
        {
            var d = new HelpDot(th, tip, text) { Location = new Point(x, y) };
            dots.Add(d);
            return d;
        }

        void ApplyTheme()
        {
            BackColor = th.Bg;
            ForeColor = th.Fg;
            header.BackColor = th.PanelBg;
            foreach (var d in dots) d.SetTheme(th);
            btnPlay.BackColor = th.Accent;
            btnPlay.ForeColor = th.AccentFg;
            btnPlay.FlatAppearance.BorderColor = th.Accent;
            log.BackColor = th.LogBg;
            log.ForeColor = th.LogFg;
            lblStatus.ForeColor = th.Muted;
            lblRusState.ForeColor = th.Muted;
            if (th.Dark)
            {
                foreach (var b in new[] { btnApply, btnDefaults, btnRestore, btnRusBrowse, btnLogToggle })
                {
                    b.FlatStyle = FlatStyle.Flat;
                    b.BackColor = th.InputBg;
                    b.ForeColor = th.Fg;
                    b.FlatAppearance.BorderColor = th.Border;
                }
            }
        }

        // ---------- Состояние ----------
        void ToggleWs()
        {
            bool on = chkWs.Checked;
            foreach (Control c in new Control[] { cmbRes, numW, numH, radCustom, radHard, cmbExe })
                c.Enabled = on;
            if (on && !Directory.Exists(Path.Combine(root, @"ui-unstretch\textures-custom")))
                radCustom.Enabled = false;
        }

        void UpdateRusUi()
        {
            bool on = chkRus.Checked;
            bool haveLocale = status.LocaleRussian;
            if (!on)
            {
                lblRusState.Text = "";
                txtRus.Enabled = false; btnRusBrowse.Enabled = false;
                return;
            }
            if (haveLocale)
            {
                lblRusState.Text = "Файлы русификатора найдены в игре — архив не нужен.";
                txtRus.Enabled = false; btnRusBrowse.Enabled = false;
            }
            else
            {
                lblRusState.Text = "Файлы русификатора не найдены — укажите скачанный архив (ссылки в README).";
                txtRus.Enabled = true; btnRusBrowse.Enabled = true;
            }
        }

        void SyncFromUi()
        {
            S.GamePath = txtPath.Text.Trim();
            S.Game = cmbGame.SelectedIndex == 1 ? "WA" : "W40k";
            S.Width = (int)numW.Value;
            S.Height = (int)numH.Value;
            S.Widescreen = chkWs.Checked;
            S.TexturesCustom = radCustom.Checked;
            S.Zoom = chkZoom.Checked;
            S.DistMax = (int)numDist.Value;
            S.Russian = chkRus.Checked;
            S.ExeMode = cmbExe.SelectedItem != null ? cmbExe.SelectedItem.ToString() : "skip";
        }

        // Кнопки «Применить» активны только если в окне есть изменения
        // относительно того, что реально стоит в игре.
        void MarkDirty()
        {
            SyncFromUi();
            bool dirty = !S.SameAs(applied);
            if (chkRus.Checked && !status.LocaleRussian && !string.IsNullOrEmpty(rusArchive)) dirty = true;
            btnApply.Enabled = dirty && !busy;
            btnPlay.Enabled = !busy;   // играть можно всегда
            lblStatus.Text = dirty ? "Есть несохранённые изменения — нажмите «Применить»."
                                   : "Настройки совпадают с тем, что установлено в игре.";
        }

        void RefreshStatus()
        {
            string gp = txtPath.Text.Trim();
            if (!File.Exists(Path.Combine(gp, "W40k.exe")))
            {
                lblStatus.Text = "Папка игры не найдена — укажите её.";
                return;
            }
            Log("Определяю текущее состояние игры…");
            SetBusy(true);
            RunPs("-Status", (code, output) =>
            {
                status = GameStatus.Parse(output);
                SetBusy(false);
                if (!status.Known) { Log("[!] Не удалось прочитать состояние игры."); return; }
                loading = true;
                // подставляем реальные факты в окно
                chkWs.Checked = status.WidescreenPatched || status.UiInstalled;
                if (status.Width > 0 && status.Height > 0)
                {
                    numW.Value = Math.Min(Math.Max(status.Width, 640), 10000);
                    numH.Value = Math.Min(Math.Max(status.Height, 480), 5000);
                    string p = status.Width + "x" + status.Height;
                    cmbRes.SelectedItem = cmbRes.Items.Contains(p) ? p : "другое";
                }
                if (radCustom.Enabled) radCustom.Checked = status.TexturesCustom;
                radHard.Checked = !radCustom.Checked;
                chkZoom.Checked = status.ZoomInstalled;
                if (status.DistMax >= 38) numDist.Value = Math.Min(status.DistMax, 300);
                numDist.Enabled = chkZoom.Checked;
                chkRus.Checked = status.LangRussian;
                ToggleWs();
                UpdateRusUi();
                SyncFromUi();
                applied = S.Clone();      // это и есть «что стоит в игре»
                loading = false;
                MarkDirty();

                var parts = new List<string>();
                parts.Add(status.WidescreenPatched ? "widescreen: стоит" : "widescreen: нет");
                parts.Add(status.UiInstalled ? "UI: стоит" : "UI: нет");
                parts.Add(status.ZoomInstalled ? ("зум: стоит (DistMax " + status.DistMax + ")") : "зум: нет");
                parts.Add(status.LocaleRussian ? (status.LangRussian ? "русский: включён" : "русификатор есть, язык англ.") : "русификатора нет");
                Log("Состояние игры → " + string.Join("; ", parts));
            });
        }

        void ResetToDefaults()
        {
            loading = true;
            var d = new Settings();
            chkWs.Checked = d.Widescreen;
            numW.Value = d.Width; numH.Value = d.Height;
            cmbRes.SelectedItem = d.Width + "x" + d.Height;
            cmbExe.SelectedItem = d.ExeMode;
            if (radCustom.Enabled) radCustom.Checked = d.TexturesCustom; else radHard.Checked = true;
            chkZoom.Checked = d.Zoom;
            numDist.Value = d.DistMax;
            chkRus.Checked = d.Russian;
            cmbGame.SelectedIndex = 0;
            ToggleWs();
            numDist.Enabled = chkZoom.Checked;
            UpdateRusUi();
            loading = false;
            MarkDirty();
            Log("Параметры окна возвращены к значениям по умолчанию (на игру пока не влияет — нажмите «Применить»).");
        }

        // После отката снимаем все галочки: окно показывает «ничего не стоит»
        void ResetUiAfterRestore()
        {
            loading = true;
            chkWs.Checked = false;
            chkZoom.Checked = false;
            chkRus.Checked = false;
            radHard.Checked = true;
            numDist.Enabled = false;
            rusArchive = ""; txtRus.Text = "";
            ToggleWs();
            UpdateRusUi();
            SyncFromUi();
            applied = S.Clone();
            loading = false;
            MarkDirty();
        }

        void ToggleLog()
        {
            logVisible = !logVisible;
            log.Visible = logVisible;
            btnLogToggle.Text = logVisible ? "Скрыть лог ▲" : "Показать лог ▼";
            Height = logVisible ? formHeightWithLog : formHeightNoLog;
        }

        void SetBusy(bool b)
        {
            busy = b;
            btnApply.Enabled = !b && btnApply.Enabled;
            btnPlay.Enabled = !b;
            btnRestore.Enabled = !b;
            btnDefaults.Enabled = !b;
            Cursor = b ? Cursors.WaitCursor : Cursors.Default;
            if (!b) MarkDirty();
        }

        // ---------- Запуск бэкенда ----------
        void RunPs(string modeArg, Action<int, string> onDone)
        {
            if (!File.Exists(launcher)) { Log("[!] DoW-Launcher.ps1 не найден."); if (onDone != null) onDone(1, ""); return; }
            string gp = txtPath.Text.Trim().Replace("'", "''");
            string psCmd = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '"
                + launcher.Replace("'", "''") + "' " + modeArg + " -GamePath '" + gp + "'";
            if (modeArg != "-Status" && !string.IsNullOrEmpty(rusArchive))
                psCmd += " -RussianArchive '" + rusArchive.Replace("'", "''") + "'";

            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -Command \"" + psCmd.Replace("\"", "\\\"") + "\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
                WorkingDirectory = root
            };
            var sb = new StringBuilder();
            bool quiet = modeArg == "-Status";
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            p.OutputDataReceived += (s, e) =>
            {
                if (e.Data == null) return;
                sb.AppendLine(e.Data);
                if (!quiet) Log(e.Data);
            };
            p.ErrorDataReceived += (s, e) => { if (e.Data != null) Log("[err] " + e.Data); };
            p.Exited += (s, e) => BeginInvoke((Action)(() => { if (onDone != null) onDone(p.ExitCode, sb.ToString()); }));
            try
            {
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                Log("[!] Не удалось запустить powershell: " + ex.Message);
                if (onDone != null) onDone(1, "");
            }
        }

        void Run(string mode)
        {
            if (busy) return;
            SyncFromUi();
            try { S.Save(cfgPath); }
            catch (Exception ex) { Log("[!] Не удалось сохранить настройки: " + ex.Message); return; }

            string modeArg = mode == "launch" ? "-Launch" : mode == "restore" ? "-RestoreAll" : "-Apply";
            Log("");
            Log("==== " + (mode == "launch" ? "Применяю и запускаю игру"
                       : mode == "restore" ? "Полный откат" : "Применяю настройки") + " ====");
            SetBusy(true);
            RunPs(modeArg, (code, output) =>
            {
                Log("==== Готово (код выхода " + code + ") ====");
                SetBusy(false);
                if (mode == "restore") { ResetUiAfterRestore(); RefreshStatus(); }
                else RefreshStatus();
            });
        }

        void Log(string msg)
        {
            if (log.InvokeRequired) { log.BeginInvoke((Action<string>)Log, msg); return; }
            log.AppendText(msg + "\r\n");
            log.SelectionStart = log.TextLength;
            log.ScrollToCaret();
        }
    }

    // ---------- Самопроверка без GUI ----------
    static class SelfTest
    {
        public static void Run()
        {
            string tmp = Path.Combine(Path.GetTempPath(), "dowmm-selftest.json");
            var a = new Settings { GamePath = @"D:\Games\Dawn of War Gold", Width = 3440, Height = 1440, Russian = true, DistMax = 90, ExeMode = "compromise", TexturesCustom = false };
            a.Save(tmp);
            var b = Settings.Load(tmp);
            bool ok = b.GamePath == a.GamePath && b.Width == a.Width && b.Height == a.Height
                && b.Russian == a.Russian && b.DistMax == a.DistMax
                && b.ExeMode == a.ExeMode && b.TexturesCustom == a.TexturesCustom;
            Console.WriteLine("settings roundtrip: " + (ok ? "OK" : "FAIL"));

            string js = "{\"GamePath\":\"D:\\\\g\",\"WidescreenPatched\":true,\"UiInstalled\":true,\"TexturesCustom\":false,\"ZoomInstalled\":true,\"DistMax\":76,\"LocaleRussian\":true,\"LangRussian\":false,\"Width\":3440,\"Height\":1440}";
            var st = GameStatus.Parse(js);
            bool ok2 = st.Known && st.WidescreenPatched && st.UiInstalled && !st.TexturesCustom
                && st.ZoomInstalled && st.DistMax == 76 && st.LocaleRussian && !st.LangRussian
                && st.Width == 3440 && st.Height == 1440;
            Console.WriteLine("status parse: " + (ok2 ? "OK" : "FAIL"));

            var s1 = new Settings(); var s2 = new Settings();
            bool ok3 = s1.SameAs(s2); s2.Zoom = !s2.Zoom; ok3 = ok3 && !s1.SameAs(s2);
            Console.WriteLine("dirty compare: " + (ok3 ? "OK" : "FAIL"));

            try { File.Delete(tmp); } catch { }
            Environment.ExitCode = (ok && ok2 && ok3) ? 0 : 1;
        }
    }
}
