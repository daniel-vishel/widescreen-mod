// ============================================================
//  Dawn of War — Mod Manager (WinForms, .NET Framework 4.8)
//  Полноценное графическое приложение-обёртка над PowerShell-
//  скриптами модов. Вся тяжёлая логика (распаковка SGA, патч
//  памяти, нарезка/подгонка текстур, трансформ UI) остаётся в
//  уже протестированных скриптах; приложение только собирает
//  настройки и вызывает DoW-Launcher.ps1 в CLI-режиме, показывая
//  живой лог.
//
//  Сборка: powershell -File app\Build-App.ps1
//  Самопроверка без окна: DoW-ModManager.exe --selftest
// ============================================================
using System;
using System.Diagnostics;
using System.Drawing;
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

    // ---------- Настройки (совпадают с $S в DoW-Launcher.ps1) ----------
    class Settings
    {
        public string GamePath = "";
        public string Game = "W40k";          // W40k | WA
        public int Width = 3440;
        public int Height = 1440;
        public bool Widescreen = true;         // отрисовка + UI (единый комплект)
        public bool TexturesCustom = true;     // true = дорисованные, false = жёсткая обрезка
        public bool Zoom = true;
        public int DistMax = 76;
        public bool Russian = false;
        public bool Wasd = false;
        public string ExeMode = "skip";        // skip | compromise | full

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
                s.Wasd           = JBool(t, "Wasd", s.Wasd);
                s.ExeMode        = JStr(t, "ExeMode", s.ExeMode);
            }
            catch { /* повреждённый json — берём значения по умолчанию */ }
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
            sb.AppendFormat("  \"Wasd\": {0},\r\n", B(Wasd));
            sb.AppendFormat("  \"ExeMode\": \"{0}\"\r\n", Esc(ExeMode));
            sb.Append("}\r\n");
            File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
        }

        static string B(bool v) { return v ? "true" : "false"; }
        static string Esc(string s) { return (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\""); }
        static string JStr(string t, string key, string def)
        {
            var m = Regex.Match(t, "\"" + key + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
            if (!m.Success) return def;
            return m.Groups[1].Value.Replace("\\\\", "\\").Replace("\\\"", "\"");
        }
        static int JInt(string t, string key, int def)
        {
            var m = Regex.Match(t, "\"" + key + "\"\\s*:\\s*(-?\\d+)");
            int v; return (m.Success && int.TryParse(m.Groups[1].Value, out v)) ? v : def;
        }
        static bool JBool(string t, string key, bool def)
        {
            var m = Regex.Match(t, "\"" + key + "\"\\s*:\\s*(true|false)", RegexOptions.IgnoreCase);
            return m.Success ? m.Groups[1].Value.ToLowerInvariant() == "true" : def;
        }
    }

    // ---------- Автопоиск папки игры (порт из скриптов) ----------
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

    // ---------- Главное окно ----------
    class MainForm : Form
    {
        readonly Settings S;
        readonly string root;       // папка со скриптами
        readonly string launcher;   // DoW-Launcher.ps1
        readonly string cfgPath;

        TextBox txtPath, log;
        ComboBox cmbGame, cmbRes, cmbExe;
        NumericUpDown numW, numH, numDist;
        CheckBox chkWs, chkZoom, chkRus, chkWasd;
        RadioButton radCustom, radHard;
        Button btnApply, btnPlay, btnRestore;
        ToolTip tip;
        bool busy;

        public MainForm()
        {
            root = ResolveRoot();
            launcher = Path.Combine(root, "DoW-Launcher.ps1");
            cfgPath = Path.Combine(root, "launcher-settings.json");
            S = Settings.Load(cfgPath);
            if (string.IsNullOrEmpty(S.GamePath))
            {
                string auto = GameFinder.Find();
                if (auto != null) S.GamePath = auto;
            }
            BuildUi();
        }

        // exe может лежать в корне репо или в app\ — ищем скрипт рядом и на уровень выше
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
            Size = new Size(688, 836);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9f);
            BackColor = Color.FromArgb(245, 246, 248);

            tip = new ToolTip { AutoPopDelay = 20000, InitialDelay = 350, ReshowDelay = 100, ShowAlways = true };

            var header = new Panel { Location = new Point(0, 0), Size = new Size(688, 54), BackColor = Color.FromArgb(28, 32, 38) };
            var title = new Label
            {
                Text = "Dawn of War — Mod Manager",
                ForeColor = Color.Gainsboro,
                Font = new Font("Segoe UI Semibold", 13f, FontStyle.Bold),
                Location = new Point(16, 12), AutoSize = true
            };
            header.Controls.Add(title);
            Controls.Add(header);

            int y = 66;

            // --- Игра ---
            var grpGame = Group("Игра", 12, y, 660, 84);
            txtPath = new TextBox { Location = new Point(14, 24), Size = new Size(494, 24), Text = S.GamePath };
            var btnBrowse = Btn("Обзор…", 514, 22, 130, 26, (s, e) =>
            {
                using (var d = new FolderBrowserDialog { Description = "Папка с игрой (где лежит W40k.exe)" })
                    if (d.ShowDialog() == DialogResult.OK) txtPath.Text = d.SelectedPath;
            });
            var btnAuto = Btn("Найти автоматически", 14, 52, 170, 24, (s, e) =>
            {
                string p = GameFinder.Find();
                if (p != null) { txtPath.Text = p; Log("Найдена игра: " + p); }
                else Log("[!] Автопоиск не нашёл игру — укажите папку вручную.");
            });
            var lblGame = new Label { Text = "Издание:", Location = new Point(380, 56), AutoSize = true };
            cmbGame = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Location = new Point(450, 52), Size = new Size(194, 24) };
            cmbGame.Items.AddRange(new object[] { "W40k (базовая игра)", "WA (Winter Assault)" });
            cmbGame.SelectedIndex = S.Game == "WA" ? 1 : 0;
            grpGame.Controls.AddRange(new Control[] { txtPath, btnBrowse, btnAuto, lblGame, cmbGame });
            Controls.Add(grpGame);
            y += 92;

            // --- Widescreen + UI ---
            var grpWs = Group("Widescreen-отрисовка + нерастянутый UI (единый комплект)", 12, y, 660, 176);
            chkWs = new CheckBox { Text = "Включить отрисовку под разрешение (UI ставится автоматически)", Location = new Point(14, 24), Size = new Size(620, 22), Checked = S.Widescreen };
            tip.SetToolTip(chkWs,
                "Расширяет обзор под ваш экран (честный FOV, не растяжение) и ставит нерастянутый UI.\r\n" +
                "Панели HUD не тянутся на всю ширину, а делятся и разъезжаются по углам экрана:\r\n" +
                "  • мини-карта и ресурсы — в левый нижний угол;\r\n" +
                "  • панель выбора отряда, команды и кнопки меню — в правый нижний угол;\r\n" +
                "  • центр экрана остаётся открытым — там виден 3D-мир.\r\n" +
                "Отрисовка и UI работают только вместе: выключение снимает и UI-мод.");
            var lblRes = new Label { Text = "Разрешение:", Location = new Point(14, 54), AutoSize = true };
            cmbRes = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Location = new Point(110, 50), Size = new Size(130, 24) };
            cmbRes.Items.AddRange(new object[] { "3440x1440", "2560x1080", "3840x1600", "5120x1440", "2560x1440", "1920x1080", "другое" });
            numW = new NumericUpDown { Minimum = 640, Maximum = 10000, Value = S.Width, Location = new Point(250, 50), Size = new Size(80, 24) };
            var lblX = new Label { Text = "×", Location = new Point(334, 54), AutoSize = true };
            numH = new NumericUpDown { Minimum = 480, Maximum = 5000, Value = S.Height, Location = new Point(352, 50), Size = new Size(80, 24) };
            string preset = S.Width + "x" + S.Height;
            cmbRes.SelectedItem = cmbRes.Items.Contains(preset) ? preset : "другое";
            cmbRes.SelectedIndexChanged += (s, e) =>
            {
                var m = Regex.Match(cmbRes.SelectedItem.ToString(), "^(\\d+)x(\\d+)$");
                if (m.Success) { numW.Value = int.Parse(m.Groups[1].Value); numH.Value = int.Parse(m.Groups[2].Value); }
            };
            var lblExe = new Label { Text = "Мини-карта (exe):", Location = new Point(452, 54), AutoSize = true };
            cmbExe = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Location = new Point(452, 74), Size = new Size(192, 24) };
            cmbExe.Items.AddRange(new object[] { "skip", "compromise", "full" });
            cmbExe.SelectedItem = new[] { "skip", "compromise", "full" }.Contains(S.ExeMode) ? S.ExeMode : "skip";
            tip.SetToolTip(cmbExe,
                "Как патчить константу соотношения в W40k.exe — влияет на мини-карту:\r\n" +
                "  • skip (рекомендуется) — exe не трогаем. 3D-мир корректный; квадратность\r\n" +
                "    мини-карты и так чинит UI-мод через разметку. Начинайте с этого.\r\n" +
                "  • compromise — в exe пишется 1.25: помогает мини-карте у части версий,\r\n" +
                "    но искажает главное меню (в самом бою нормально).\r\n" +
                "  • full — в exe полное соотношение: у кого-то мини-карта ок, но 3D-мир\r\n" +
                "    может растянуться. Крайний вариант.");
            var lblTex = new Label { Text = "Текстуры баров:", Location = new Point(14, 88), AutoSize = true };
            radCustom = new RadioButton { Text = "дорисованные", Location = new Point(130, 86), Size = new Size(140, 22), Checked = S.TexturesCustom };
            radHard = new RadioButton { Text = "жёсткая обрезка", Location = new Point(280, 86), Size = new Size(160, 22), Checked = !S.TexturesCustom };
            tip.SetToolTip(radCustom,
                "Фоны панелей берутся из ui-unstretch\\textures-custom (ваш перерисованный арт\r\n" +
                "с плавными/аккуратными краями) и подгоняются под гнёзда кнопок. Мягкий стык.");
            tip.SetToolTip(radHard,
                "Стандартная текстура из архива режется по границам зон и раздвигается.\r\n" +
                "Быстро и без ручной работы, но на местах разреза виден резкий обрыв картинки.");
            var note1 = new Label { Text = "UI-панели делятся и разъезжаются по углам: мини-карта — слева, команды и меню — справа, в центре — 3D-мир.", Location = new Point(14, 116), Size = new Size(636, 18), ForeColor = Color.DimGray };
            var note2 = new Label { Text = "«Дорисованные» — ваш арт с плавным краем; «жёсткая обрезка» — резкий обрыв на стыке. Выкл. отрисовку — UI-мод снимается.", Location = new Point(14, 136), Size = new Size(636, 32), ForeColor = Color.DimGray };
            grpWs.Controls.AddRange(new Control[] { chkWs, lblRes, cmbRes, numW, lblX, numH, lblExe, cmbExe, lblTex, radCustom, radHard, note1, note2 });
            Controls.Add(grpWs);
            chkWs.CheckedChanged += (s, e) => ToggleWs();
            y += 184;

            // --- Камера ---
            var grpCam = Group("Камера", 12, y, 660, 84);
            chkZoom = new CheckBox { Text = "Улучшенный зум (отвод колёсиком дальше), DistMax:", Location = new Point(14, 24), Size = new Size(340, 22), Checked = S.Zoom };
            numDist = new NumericUpDown { Minimum = 38, Maximum = 300, Value = S.DistMax, Location = new Point(360, 22), Size = new Size(80, 24) };
            chkWasd = new CheckBox { Text = "WASD-камера (Scroll Lock ВКЛ = камера, ВЫКЛ = обычные хоткеи)", Location = new Point(14, 52), Size = new Size(620, 22), Checked = S.Wasd };
            tip.SetToolTip(chkZoom, "Отодвигает максимальный отвод камеры колёсиком (DistMax; оригинал 38).\r\nТребует включённой «Full 3D Camera» в настройках графики игры.");
            tip.SetToolTip(chkWasd,
                "В движке DoW1 клавиши камеры не переназначаются, поэтому включается перехватчик:\r\n" +
                "Scroll Lock ВКЛ — W/A/S/D двигают камеру (лампочка на клавиатуре = режим включён);\r\n" +
                "Scroll Lock ВЫКЛ — те же клавиши работают как обычные хоткеи (A = attack-move и т.д.).\r\n" +
                "Действует только в окне игры, закрывается вместе с ней.");
            grpCam.Controls.AddRange(new Control[] { chkZoom, numDist, chkWasd });
            Controls.Add(grpCam);
            y += 92;

            // --- Язык ---
            var grpLang = Group("Язык", 12, y, 660, 54);
            chkRus = new CheckBox { Text = "Русский язык ([lang:russian] в W40k.ini; локализация должна быть установлена)", Location = new Point(14, 22), Size = new Size(630, 22), Checked = S.Russian };
            tip.SetToolTip(chkRus,
                "Прописывает строку [lang:russian] в W40k.ini (с резервной копией).\r\n" +
                "Сами русские файлы должны быть в игре (Locale\\Russian) — иначе выберите\r\n" +
                "русский язык в свойствах игры в Steam, чтобы Steam их докачал.");
            grpLang.Controls.Add(chkRus);
            Controls.Add(grpLang);
            y += 64;

            // --- Кнопки ---
            btnApply = Btn("Применить", 12, y, 150, 34, (s, e) => Run("apply"));
            btnPlay = Btn("Применить и играть", 170, y, 200, 34, (s, e) => Run("launch"));
            btnPlay.Font = new Font("Segoe UI Semibold", 9.5f, FontStyle.Bold);
            btnPlay.BackColor = Color.FromArgb(52, 120, 200);
            btnPlay.ForeColor = Color.White;
            btnPlay.FlatStyle = FlatStyle.Flat;
            btnRestore = Btn("Полный откат", 532, y, 140, 34, (s, e) => Run("restore"));
            Controls.AddRange(new Control[] { btnApply, btnPlay, btnRestore });
            y += 44;

            // --- Лог ---
            log = new TextBox
            {
                Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical,
                Location = new Point(12, y), Size = new Size(660, 796 - y),
                Font = new Font("Consolas", 8.5f), BackColor = Color.FromArgb(24, 26, 30), ForeColor = Color.Gainsboro
            };
            Controls.Add(log);

            ToggleWs();
            if (!Directory.Exists(Path.Combine(root, @"ui-unstretch\textures-custom")))
            {
                radCustom.Enabled = false; radHard.Checked = true;
                Log("textures-custom не найдены — доступна только жёсткая обрезка.");
            }
            if (!File.Exists(launcher))
                Log("[!] Не найден DoW-Launcher.ps1 рядом с приложением (" + root + ").");
            else
                Log("Готов. Настройте параметры и нажмите «Применить и играть».");
        }

        GroupBox Group(string text, int x, int y, int w, int h)
        {
            return new GroupBox { Text = text, Location = new Point(x, y), Size = new Size(w, h) };
        }
        Button Btn(string text, int x, int y, int w, int h, EventHandler onClick)
        {
            var b = new Button { Text = text, Location = new Point(x, y), Size = new Size(w, h) };
            b.Click += onClick;
            return b;
        }

        void ToggleWs()
        {
            bool on = chkWs.Checked;
            foreach (Control c in new Control[] { cmbRes, numW, numH, radCustom, radHard, cmbExe })
                c.Enabled = on;
            if (on && !Directory.Exists(Path.Combine(root, @"ui-unstretch\textures-custom")))
                radCustom.Enabled = false;
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
            S.Wasd = chkWasd.Checked;
            S.ExeMode = cmbExe.SelectedItem != null ? cmbExe.SelectedItem.ToString() : "skip";
        }

        void SetBusy(bool b)
        {
            busy = b;
            btnApply.Enabled = btnPlay.Enabled = btnRestore.Enabled = !b;
            Cursor = b ? Cursors.WaitCursor : Cursors.Default;
        }

        void Run(string mode)
        {
            if (busy) return;
            if (!File.Exists(launcher)) { Log("[!] DoW-Launcher.ps1 не найден — приложение должно лежать рядом со скриптами."); return; }
            SyncFromUi();
            try { S.Save(cfgPath); }
            catch (Exception ex) { Log("[!] Не удалось сохранить настройки: " + ex.Message); return; }

            string modeArg = mode == "launch" ? "-Launch" : mode == "restore" ? "-RestoreAll" : "-Apply";
            Log("");
            Log("==== " + (mode == "launch" ? "Применяю и запускаю игру" : mode == "restore" ? "Полный откат" : "Применяю настройки") + " ====");
            SetBusy(true);

            string gp = S.GamePath.Replace("'", "''");
            string psCmd = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '"
                + launcher.Replace("'", "''") + "' " + modeArg + " -GamePath '" + gp + "'";
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
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            p.OutputDataReceived += (s, e) => { if (e.Data != null) Log(e.Data); };
            p.ErrorDataReceived += (s, e) => { if (e.Data != null) Log("[err] " + e.Data); };
            p.Exited += (s, e) => BeginInvoke((Action)(() =>
            {
                SetBusy(false);
                Log("==== Готово (код выхода " + p.ExitCode + ") ====");
            }));
            try
            {
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                SetBusy(false);
                Log("[!] Не удалось запустить powershell: " + ex.Message);
            }
        }

        void Log(string msg)
        {
            if (log.InvokeRequired) { log.BeginInvoke((Action<string>)Log, msg); return; }
            log.AppendText(msg + "\r\n");
            log.SelectionStart = log.TextLength;
            log.ScrollToCaret();
        }
    }

    // ---------- Самопроверка без GUI (для сборочного прогона) ----------
    static class SelfTest
    {
        public static void Run()
        {
            string tmp = Path.Combine(Path.GetTempPath(), "dowmm-selftest.json");
            var a = new Settings { GamePath = @"D:\Games\Dawn of War Gold", Width = 3440, Height = 1440, Russian = true, Wasd = true, DistMax = 90, ExeMode = "compromise", TexturesCustom = false };
            a.Save(tmp);
            var b = Settings.Load(tmp);
            bool ok = b.GamePath == a.GamePath && b.Width == a.Width && b.Height == a.Height
                && b.Russian == a.Russian && b.Wasd == a.Wasd && b.DistMax == a.DistMax
                && b.ExeMode == a.ExeMode && b.TexturesCustom == a.TexturesCustom;
            Console.WriteLine("settings roundtrip: " + (ok ? "OK" : "FAIL"));
            Console.WriteLine("  path='" + b.GamePath + "' exe=" + b.ExeMode + " distmax=" + b.DistMax);
            Console.WriteLine("game auto-detect: " + (GameFinder.Find() ?? "(not found — normal without the game)"));
            try { File.Delete(tmp); } catch { }
            Environment.ExitCode = ok ? 0 : 1;
        }
    }
}
