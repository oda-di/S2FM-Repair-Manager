using System.Diagnostics;
using System.Drawing.Imaging;
using System.Globalization;
using Microsoft.Win32;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace S2FMRepairManager;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        if (args.Length == 3 && string.Equals(args[0], "--verify-layout", StringComparison.OrdinalIgnoreCase))
        {
            using var form = new MainForm();
            form.StartPosition = FormStartPosition.Manual;
            form.Location = new Point(40, 40);
            form.Show();
            Application.DoEvents();
            var success = form.WriteLayoutDiagnostics(args[1], args[2]);
            form.Close();
            return success ? 0 : 1;
        }
        if (args.Length == 3 && string.Equals(args[0], "--scan-maps", StringComparison.OrdinalIgnoreCase))
        {
            using var form = new MainForm();
            return form.WriteMapScanDiagnostics(args[1], args[2]) ? 0 : 1;
        }
        Application.Run(new MainForm());
        return 0;
    }
}

internal sealed class MainForm : Form
{
    private static readonly string DefaultCs2Root = FindCs2Root() ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
        "Steam", "steamapps", "common", "Counter-Strike Global Offensive");
    private static readonly Color Background = Color.FromArgb(17, 20, 27);
    private static readonly Color Surface = Color.FromArgb(27, 32, 42);
    private static readonly Color SurfaceAlt = Color.FromArgb(35, 41, 53);
    private static readonly Color TextPrimary = Color.FromArgb(238, 241, 247);
    private static readonly Color TextMuted = Color.FromArgb(158, 168, 187);
    private static readonly Color Accent = Color.FromArgb(75, 136, 255);
    private static readonly Color Success = Color.FromArgb(48, 184, 119);
    private static readonly Color Danger = Color.FromArgb(224, 84, 96);
    private static readonly Color Warning = Color.FromArgb(235, 174, 69);

    private readonly string kitRoot;
    private readonly string settingsPath;
    private readonly TextBox cs2RootBox = new();
    private readonly ComboBox addonBox = new();
    private readonly TextBox searchBox = new();
    private readonly ComboBox sessionBox = new();
    private readonly DataGridView mapGrid = new();
    private readonly RichTextBox logBox = new();
    private readonly Label globalStatusLabel = new();
    private readonly Label selectionLabel = new();
    private readonly Label statusLabel = new();
    private readonly ProgressBar progressBar = new();
    private readonly CheckBox showWorkshopCheckBox = new();
    private readonly CheckBox mountedOnlyCheckBox = new();
    private readonly Button prepareButton = new();
    private readonly Button launchButton = new();
    private readonly Button prepareLaunchButton = new();
    private readonly Button refreshButton = new();
    private readonly Button browseButton = new();
    private readonly Button unmountButton = new();
    private readonly System.Windows.Forms.Timer statusTimer = new() { Interval = 2000 };
    private readonly List<MapInfo> allMaps = [];
    private bool busy;

    public MainForm()
    {
        kitRoot = ResolveKitRoot();
        var settingsOverride = Environment.GetEnvironmentVariable("S2FM_REPAIR_SETTINGS_PATH");
        settingsPath = string.IsNullOrWhiteSpace(settingsOverride)
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "S2FMRepairManager",
                "settings.json")
            : Path.GetFullPath(settingsOverride);

        Text = "S2FM Repair Manager";
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96F, 96F);
        MinimumSize = new Size(1100, 760);
        Size = new Size(1280, 860);
        BackColor = Background;
        ForeColor = TextPrimary;
        Font = new Font("Segoe UI", 10F);

        BuildUi();
        LoadSettings();
        Shown += async (_, _) => await RefreshEverythingAsync();
        FormClosing += (_, _) => SaveSettings();
        FormClosed += (_, _) => statusTimer.Dispose();
        statusTimer.Tick += (_, _) =>
        {
            if (!busy) UpdateGlobalStatus(cs2RootBox.Text.Trim());
        };
        statusTimer.Start();
    }

    private void BuildUi()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            BackColor = Background,
            Padding = new Padding(24),
            ColumnCount = 1,
            RowCount = 5,
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 94));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 132));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 64));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 36));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));
        Controls.Add(root);

        root.Controls.Add(BuildHeader(), 0, 0);
        root.Controls.Add(BuildSettingsPanel(), 0, 1);
        root.Controls.Add(BuildMapsPanel(), 0, 2);
        root.Controls.Add(BuildLogPanel(), 0, 3);
        root.Controls.Add(BuildStatusBar(), 0, 4);
    }

    private Control BuildHeader()
    {
        var panel = new Panel { Dock = DockStyle.Fill };
        var title = new Label
        {
            Text = "S2FM Repair Manager",
            AutoSize = true,
            Font = new Font("Segoe UI Semibold", 22F),
            ForeColor = TextPrimary,
            Location = new Point(0, 0),
        };
        var subtitle = new Label
        {
            Text = "Монтаж карт, восстановление солнечного света и запуск Source Filmmaker",
            AutoSize = true,
            ForeColor = TextMuted,
            Location = new Point(3, 52),
        };
        globalStatusLabel.AutoSize = true;
        globalStatusLabel.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        globalStatusLabel.Font = new Font("Segoe UI Semibold", 10F);
        globalStatusLabel.Location = new Point(780, 13);
        panel.Resize += (_, _) => globalStatusLabel.Left = Math.Max(0, panel.ClientSize.Width - globalStatusLabel.Width - 6);
        panel.Controls.AddRange([title, subtitle, globalStatusLabel]);
        return panel;
    }

    private Control BuildSettingsPanel()
    {
        var card = Card();
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(18, 14, 18, 14),
            ColumnCount = 6,
            RowCount = 2,
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 92));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 48));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 86));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 175));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 130));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 50));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 50));
        card.Controls.Add(layout);

        layout.Controls.Add(FieldLabel("CS2"), 0, 0);
        ConfigureTextBox(cs2RootBox);
        layout.Controls.Add(cs2RootBox, 1, 0);
        browseButton.Text = "…";
        StyleButton(browseButton, SurfaceAlt, TextPrimary, 42);
        browseButton.Dock = DockStyle.Fill;
        browseButton.Click += BrowseButton_Click;
        layout.Controls.Add(browseButton, 2, 0);
        layout.Controls.Add(FieldLabel("Аддон"), 3, 0);
        addonBox.Dock = DockStyle.Fill;
        addonBox.DropDownStyle = ComboBoxStyle.DropDown;
        addonBox.AutoCompleteMode = AutoCompleteMode.SuggestAppend;
        addonBox.AutoCompleteSource = AutoCompleteSource.ListItems;
        addonBox.BackColor = SurfaceAlt;
        addonBox.ForeColor = TextPrimary;
        addonBox.FlatStyle = FlatStyle.Flat;
        addonBox.Margin = new Padding(3, 5, 8, 5);
        addonBox.DropDownWidth = 280;
        addonBox.AccessibleName = "Аддон";
        addonBox.AccessibleDescription = "Выбери существующий аддон или введи имя нового";
        addonBox.SelectionChangeCommitted += async (_, _) => await RefreshEverythingAsync();
        layout.Controls.Add(addonBox, 4, 0);
        refreshButton.Text = "Обновить";
        StyleButton(refreshButton, SurfaceAlt, TextPrimary);
        refreshButton.Click += async (_, _) => await RefreshEverythingAsync();
        layout.Controls.Add(refreshButton, 5, 0);

        layout.Controls.Add(FieldLabel("Сессия"), 0, 1);
        sessionBox.Dock = DockStyle.Fill;
        sessionBox.DropDownStyle = ComboBoxStyle.DropDown;
        sessionBox.AutoCompleteMode = AutoCompleteMode.SuggestAppend;
        sessionBox.AutoCompleteSource = AutoCompleteSource.ListItems;
        sessionBox.BackColor = SurfaceAlt;
        sessionBox.ForeColor = TextPrimary;
        sessionBox.FlatStyle = FlatStyle.Flat;
        sessionBox.Margin = new Padding(3, 5, 8, 5);
        sessionBox.AccessibleName = "Имя сессии";
        sessionBox.AccessibleDescription = "Введи новое имя, например session_test, или выбери существующую сессию";
        layout.SetColumnSpan(sessionBox, 2);
        layout.Controls.Add(sessionBox, 1, 1);
        layout.Controls.Add(FieldLabel("Поиск"), 3, 1);
        ConfigureTextBox(searchBox);
        searchBox.PlaceholderText = "de_mirage…";
        searchBox.TextChanged += (_, _) => ApplyMapFilter();
        layout.SetColumnSpan(searchBox, 2);
        layout.Controls.Add(searchBox, 4, 1);
        return card;
    }

    private Control BuildMapsPanel()
    {
        var card = Card();
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(14),
            ColumnCount = 1,
            RowCount = 3,
        };
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 60));
        card.Controls.Add(layout);

        var heading = new Panel { Dock = DockStyle.Fill };
        var mapsTitle = new Label
        {
            Text = "Карты",
            AutoSize = true,
            Font = new Font("Segoe UI Semibold", 13F),
            ForeColor = TextPrimary,
        };
        selectionLabel.AutoSize = true;
        selectionLabel.ForeColor = TextMuted;
        selectionLabel.Location = new Point(88, 5);
        showWorkshopCheckBox.Text = "Отображать карты из мастерской";
        showWorkshopCheckBox.AutoSize = true;
        showWorkshopCheckBox.Checked = false;
        showWorkshopCheckBox.ForeColor = TextMuted;
        showWorkshopCheckBox.Location = new Point(235, 4);
        showWorkshopCheckBox.AccessibleName = "Отображать карты из мастерской";
        showWorkshopCheckBox.CheckedChanged += (_, _) => ApplyMapFilter();
        mountedOnlyCheckBox.Text = "Только смонтированные";
        mountedOnlyCheckBox.AutoSize = true;
        mountedOnlyCheckBox.Checked = false;
        mountedOnlyCheckBox.ForeColor = TextMuted;
        mountedOnlyCheckBox.Location = new Point(620, 4);
        mountedOnlyCheckBox.AccessibleName = "Только смонтированные карты";
        mountedOnlyCheckBox.CheckedChanged += (_, _) => ApplyMapFilter();
        heading.Controls.AddRange([mapsTitle, selectionLabel, showWorkshopCheckBox, mountedOnlyCheckBox]);
        layout.Controls.Add(heading, 0, 0);

        ConfigureMapGrid();
        layout.Controls.Add(mapGrid, 0, 1);

        var actionsHost = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            RowCount = 1,
        };
        actionsHost.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        actionsHost.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        actionsHost.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 340));
        var actions = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Padding = new Padding(0, 10, 0, 0),
            Margin = Padding.Empty,
        };
        var deleteAction = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft,
            WrapContents = false,
            Padding = new Padding(0, 10, 0, 0),
            Margin = Padding.Empty,
        };
        prepareButton.Text = "Смонтировать карты";
        prepareLaunchButton.Text = "Смонтировать и запустить";
        launchButton.Text = "Запустить SFM";
        unmountButton.Text = "Демонтировать и удалить";
        StyleButton(prepareButton, Accent, Color.White, 210);
        StyleButton(prepareLaunchButton, Success, Color.White, 260);
        StyleButton(launchButton, SurfaceAlt, TextPrimary, 180);
        StyleButton(unmountButton, Danger, Color.White, 320);
        prepareButton.Click += async (_, _) => await PrepareSelectedAsync(false);
        prepareLaunchButton.Click += async (_, _) => await PrepareSelectedAsync(true);
        launchButton.Click += async (_, _) => await LaunchSfmAsync();
        unmountButton.Click += async (_, _) => await UnmountSelectedAsync();
        actions.Controls.AddRange([prepareButton, prepareLaunchButton, launchButton]);
        deleteAction.Controls.Add(unmountButton);
        actionsHost.Controls.Add(actions, 0, 0);
        actionsHost.Controls.Add(deleteAction, 1, 0);
        layout.Controls.Add(actionsHost, 0, 2);
        return card;
    }

    private Control BuildLogPanel()
    {
        var card = Card();
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(14, 10, 14, 12),
            RowCount = 2,
            ColumnCount = 1,
        };
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.Controls.Add(new Label
        {
            Text = "Журнал",
            AutoSize = true,
            Font = new Font("Segoe UI Semibold", 11F),
            ForeColor = TextPrimary,
        }, 0, 0);
        logBox.Dock = DockStyle.Fill;
        logBox.ReadOnly = true;
        logBox.BorderStyle = BorderStyle.None;
        logBox.BackColor = Color.FromArgb(20, 24, 32);
        logBox.ForeColor = Color.FromArgb(194, 204, 222);
        logBox.Font = new Font("Cascadia Mono", 9F);
        logBox.DetectUrls = false;
        layout.Controls.Add(logBox, 0, 1);
        card.Controls.Add(layout);
        return card;
    }

    private Control BuildStatusBar()
    {
        var panel = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            Padding = new Padding(2, 9, 2, 0),
        };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 240));
        statusLabel.Text = "Готово";
        statusLabel.ForeColor = TextMuted;
        statusLabel.Dock = DockStyle.Fill;
        progressBar.Dock = DockStyle.Fill;
        progressBar.Style = ProgressBarStyle.Marquee;
        progressBar.MarqueeAnimationSpeed = 25;
        progressBar.Visible = false;
        panel.Controls.Add(statusLabel, 0, 0);
        panel.Controls.Add(progressBar, 1, 0);
        return panel;
    }

    private void ConfigureMapGrid()
    {
        mapGrid.Dock = DockStyle.Fill;
        mapGrid.BackgroundColor = Color.FromArgb(20, 24, 32);
        mapGrid.BorderStyle = BorderStyle.None;
        mapGrid.AllowUserToAddRows = false;
        mapGrid.AllowUserToDeleteRows = false;
        mapGrid.AllowUserToResizeRows = false;
        mapGrid.ReadOnly = true;
        mapGrid.MultiSelect = true;
        mapGrid.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
        mapGrid.RowHeadersVisible = false;
        mapGrid.AutoGenerateColumns = false;
        mapGrid.EnableHeadersVisualStyles = false;
        mapGrid.ColumnHeadersDefaultCellStyle.BackColor = SurfaceAlt;
        mapGrid.ColumnHeadersDefaultCellStyle.ForeColor = TextPrimary;
        mapGrid.ColumnHeadersDefaultCellStyle.Font = new Font("Segoe UI Semibold", 9.5F);
        mapGrid.ColumnHeadersHeight = 40;
        mapGrid.DefaultCellStyle.BackColor = Color.FromArgb(20, 24, 32);
        mapGrid.DefaultCellStyle.ForeColor = TextPrimary;
        mapGrid.DefaultCellStyle.SelectionBackColor = Color.FromArgb(50, 74, 117);
        mapGrid.DefaultCellStyle.SelectionForeColor = Color.White;
        mapGrid.DefaultCellStyle.Padding = new Padding(7, 4, 7, 7);
        mapGrid.RowTemplate.Height = 44;
        mapGrid.GridColor = Color.FromArgb(43, 49, 62);
        mapGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Map", HeaderText = "Карта", DataPropertyName = "DisplayName", AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill, FillWeight = 52 });
        mapGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Status", HeaderText = "Состояние", DataPropertyName = "Status", AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill, FillWeight = 35 });
        mapGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Size", HeaderText = "Размер", DataPropertyName = "SizeText", Width = 115 });
        mapGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "Modified", HeaderText = "Обновлена", DataPropertyName = "ModifiedText", Width = 145 });
        mapGrid.SelectionChanged += (_, _) => UpdateSelectionLabel();
        mapGrid.CellFormatting += MapGrid_CellFormatting;
    }

    private async Task RefreshEverythingAsync()
    {
        if (busy) return;
        SetBusy(true, "Сканирование карт и аддонов…");
        try
        {
            SaveSettings();
            allMaps.Clear();
            var root = cs2RootBox.Text.Trim();
            var missingKitFiles = RequiredKitFiles()
                .Where(path => !File.Exists(Path.Combine(kitRoot, path)))
                .ToList();
            if (missingKitFiles.Count > 0)
            {
                Log($"Комплект повреждён. Не найдены файлы: {string.Join(", ", missingKitFiles)}", true);
                globalStatusLabel.Text = "● Комплект повреждён";
                globalStatusLabel.ForeColor = Danger;
                return;
            }

            await RestoreOfficialClientIfIdleAsync();

            var toolsExecutable = Path.Combine(root, "game", "bin", "win64", "cs2.exe");
            var dmxConvert = Path.Combine(root, "game", "bin", "win64", "dmxconvert.exe");
            if (!File.Exists(toolsExecutable) || !File.Exists(dmxConvert))
            {
                Log("Не найдены CS2 Workshop Tools. Установи их в Steam, затем нажми «Обновить».", true);
                globalStatusLabel.Text = "● Workshop Tools не найдены";
                globalStatusLabel.ForeColor = Danger;
                return;
            }
            var mapsDir = Path.Combine(root, "game", "csgo", "maps");
            if (!Directory.Exists(mapsDir))
            {
                Log($"Папка карт не найдена: {mapsDir}", true);
                globalStatusLabel.Text = "● CS2 не найдена";
                globalStatusLabel.ForeColor = Danger;
                return;
            }

            var addonCount = LoadAddons(root);
            var addon = addonBox.Text.Trim();
            var scan = await Task.Run(() => DiscoverMaps(root, addon));
            allMaps.AddRange(scan.Maps);
            foreach (var warning in scan.Warnings) Log(warning, true);
            ApplyMapFilter();
            LoadSessions(root, addon);
            UpdateGlobalStatus(root);
            Log($"Найдено аддонов: {addonCount}. Карт: {allMaps.Count} (Workshop: {allMaps.Count(map => map.IsWorkshop)}).");
        }
        catch (Exception ex)
        {
            Log(ex.Message, true);
        }
        finally
        {
            SetBusy(false, "Готово");
        }
        await Task.CompletedTask;
    }

    private MapInfo ReadMapInfo(string root, string addon, string name, string sourcePath,
        string? workshopId = null, string? workshopTitle = null, long? sourceSize = null, DateTime? sourceModified = null)
    {
        var source = new FileInfo(sourcePath);
        var manifestPath = Path.Combine(root, "game", "csgo", "s2fm_repair_backup", "map_light_overrides", $"{addon}.{name}.json");
        var addonVpk = Path.Combine(root, "game", "csgo_addons", addon, "maps", $"{name}.vpk");
        var state = PatchState.NotInstalled;
        DateTime? installedAt = null;

        if (File.Exists(manifestPath))
        {
            try
            {
                using var document = JsonDocument.Parse(File.ReadAllText(manifestPath));
                var rootElement = document.RootElement;
                var schemaVersion = rootElement.TryGetProperty("schemaVersion", out var schemaProperty)
                    ? schemaProperty.GetInt32()
                    : 0;
                if (rootElement.TryGetProperty("installedAtUtc", out var installedProperty) &&
                    DateTime.TryParse(installedProperty.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal, out var parsed))
                    installedAt = parsed.ToUniversalTime();
                state = File.Exists(addonVpk) ? PatchState.Ready : PatchState.Broken;
                string? installedWorkshopId = null;
                if (rootElement.TryGetProperty("workshopId", out var workshopProperty) &&
                    workshopProperty.ValueKind == JsonValueKind.String)
                    installedWorkshopId = workshopProperty.GetString();
                if (state == PatchState.Ready && schemaVersion < 6)
                    state = PatchState.Stale;
                else if (state == PatchState.Ready && !string.Equals(installedWorkshopId, workshopId, StringComparison.Ordinal))
                    state = PatchState.Stale;
                else if (state == PatchState.Ready && workshopId is not null && schemaVersion < 8)
                    state = PatchState.Stale;
                else if (state == PatchState.Ready && installedAt.HasValue &&
                    (sourceModified ?? source.LastWriteTime).ToUniversalTime() > installedAt.Value.AddMinutes(1))
                    state = PatchState.Stale;
            }
            catch
            {
                state = PatchState.Broken;
            }
        }
        else if (File.Exists(addonVpk))
        {
            state = PatchState.Untracked;
        }

        return new MapInfo(name, sourcePath, sourceSize ?? source.Length, sourceModified ?? source.LastWriteTime,
            state, manifestPath, addonVpk, workshopId, workshopTitle);
    }

    private MapScanResult DiscoverMaps(string root, string addon)
    {
        var maps = new List<MapInfo>();
        var warnings = new List<string>();
        var mapsDir = Path.Combine(root, "game", "csgo", "maps");
        foreach (var vpk in Directory.EnumerateFiles(mapsDir, "*.vpk", SearchOption.TopDirectoryOnly).OrderBy(Path.GetFileName))
        {
            var name = Path.GetFileNameWithoutExtension(vpk);
            if (name.EndsWith("_dir", StringComparison.OrdinalIgnoreCase)) continue;
            maps.Add(ReadMapInfo(root, addon, name, vpk));
        }

        var commonDir = Directory.GetParent(root);
        var steamAppsDir = commonDir is not null && string.Equals(commonDir.Name, "common", StringComparison.OrdinalIgnoreCase)
            ? commonDir.Parent
            : null;
        var workshopRoot = steamAppsDir is null ? null : Path.Combine(steamAppsDir.FullName, "workshop", "content", "730");
        if (workshopRoot is null || !Directory.Exists(workshopRoot))
            return new MapScanResult(maps.OrderBy(map => map.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList(), warnings);

        var viewer = new[]
        {
            Path.Combine(kitRoot, "tools", "ValveResourceFormat", "Source2Viewer-CLI.exe"),
            Path.Combine(kitRoot, "third_party", "ValveResourceFormat", "Source2Viewer-CLI.exe"),
        }.FirstOrDefault(File.Exists) ?? Path.Combine(kitRoot, "tools", "ValveResourceFormat", "Source2Viewer-CLI.exe");
        foreach (var itemDir in Directory.EnumerateDirectories(workshopRoot).OrderBy(Path.GetFileName))
        {
            var workshopId = Path.GetFileName(itemDir);
            if (!Regex.IsMatch(workshopId, "^[0-9]+$")) continue;
            var indexVpk = Path.Combine(itemDir, $"{workshopId}_dir.vpk");
            if (!File.Exists(indexVpk)) continue;
            try
            {
                var publishData = Path.Combine(itemDir, "publish_data.txt");
                var metadata = File.Exists(publishData) ? File.ReadAllText(publishData) : string.Empty;
                var parsedTitle = ReadPublishDataValue(metadata, "title");
                var title = string.IsNullOrWhiteSpace(parsedTitle) ? $"Workshop {workshopId}" : parsedTitle;
                var packageFiles = Directory.EnumerateFiles(itemDir, $"{workshopId}_*.vpk", SearchOption.TopDirectoryOnly).ToList();
                var packageSize = packageFiles.Sum(path => new FileInfo(path).Length);
                var packageModified = packageFiles.Max(File.GetLastWriteTime);
                foreach (var mapName in ListWorkshopMapNames(viewer, indexVpk))
                    maps.Add(ReadMapInfo(root, addon, mapName, indexVpk, workshopId, title, packageSize, packageModified));
            }
            catch (Exception ex)
            {
                warnings.Add($"Workshop {workshopId}: не удалось прочитать пакет ({ex.Message}).");
            }
        }
        return new MapScanResult(maps.OrderBy(map => map.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList(), warnings);
    }

    private static string? ReadPublishDataValue(string text, string key)
    {
        var match = Regex.Match(text, $"(?m)^\\s*\\\"{Regex.Escape(key)}\\\"\\s+\\\"(?<value>(?:\\\\.|[^\\\"])*)\\\"\\s*$",
            RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1));
        return match.Success
            ? match.Groups["value"].Value.Replace("\\\"", "\"").Replace("\\\\", "\\")
            : null;
    }

    private static IReadOnlyList<string> ListWorkshopMapNames(string viewer, string indexVpk)
    {
        var start = new ProcessStartInfo
        {
            FileName = viewer,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.ArgumentList.Add("-i");
        start.ArgumentList.Add(indexVpk);
        start.ArgumentList.Add("--vpk_list");
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Source2Viewer-CLI.exe не запустился.");
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(30_000))
        {
            process.Kill(true);
            throw new TimeoutException("превышено время чтения VPK");
        }
        Task.WaitAll(stdoutTask, stderrTask);
        if (process.ExitCode != 0)
            throw new InvalidOperationException(stderrTask.Result.Trim().Length > 0 ? stderrTask.Result.Trim() : "ошибка чтения VPK");

        return Regex.Matches(stdoutTask.Result, "(?im)^maps/(?<name>[A-Za-z0-9_]+)\\.vpk\\s+CRC:")
            .Select(match => match.Groups["name"].Value)
            .Where(name => !Regex.IsMatch(name, "(_skybox|_3dsky(?:box)?)$", RegexOptions.IgnoreCase))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private void ApplyMapFilter()
    {
        var query = searchBox.Text.Trim();
        var showWorkshop = showWorkshopCheckBox.Checked;
        var mountedOnly = mountedOnlyCheckBox.Checked;
        var filtered = allMaps.Where(map => (!map.IsWorkshop || showWorkshop) &&
            (!mountedOnly || map.State == PatchState.Ready) &&
            (query.Length == 0 || map.DisplayName.Contains(query, StringComparison.OrdinalIgnoreCase) ||
             (map.WorkshopId?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false))).ToList();
        if (mapGrid.Columns["Map"] is DataGridViewColumn mapColumn)
            mapColumn.HeaderText = showWorkshop ? "Карта / название Workshop" : "Карта";
        mapGrid.DataSource = null;
        mapGrid.DataSource = filtered;
        UpdateSelectionLabel();
    }

    private int LoadAddons(string root)
    {
        var typedName = addonBox.Text.Trim();
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var addonsRoot in new[]
        {
            Path.Combine(root, "game", "csgo_addons"),
            Path.Combine(root, "content", "csgo_addons"),
        })
        {
            if (!Directory.Exists(addonsRoot)) continue;
            foreach (var directory in Directory.EnumerateDirectories(addonsRoot, "*", SearchOption.TopDirectoryOnly))
            {
                var name = Path.GetFileName(directory);
                if (Regex.IsMatch(name, "^[A-Za-z0-9_-]+$")) names.Add(name);
            }
        }

        addonBox.BeginUpdate();
        try
        {
            addonBox.Items.Clear();
            foreach (var name in names.OrderBy(name => name, StringComparer.CurrentCultureIgnoreCase))
                addonBox.Items.Add(name);
            addonBox.SelectedIndex = -1;
            addonBox.Text = typedName.Length > 0 ? typedName : "sfm_repaired";
            addonBox.SelectionStart = addonBox.Text.Length;
        }
        finally
        {
            addonBox.EndUpdate();
        }
        return names.Count;
    }

    private void LoadSessions(string root, string addon)
    {
        var selected = sessionBox.SelectedItem as SessionChoice;
        var typedName = sessionBox.Text.Trim();
        var settings = LoadSettingsObject();
        sessionBox.Items.Clear();
        sessionBox.Items.Add(new SessionChoice("Без автозагрузки", null));
        var sessionsDir = Path.Combine(root, "game", "csgo_addons", addon, "elements", "sessions");
        if (Directory.Exists(sessionsDir))
        {
            foreach (var file in Directory.EnumerateFiles(sessionsDir, "*.dmx", SearchOption.TopDirectoryOnly).OrderByDescending(File.GetLastWriteTimeUtc))
                sessionBox.Items.Add(new SessionChoice(Path.GetFileNameWithoutExtension(file), file));
        }
        var wantedPath = selected?.Path ?? settings.Session;
        var wantedChoice = sessionBox.Items.Cast<SessionChoice>().FirstOrDefault(choice =>
            choice.Path is not null && string.Equals(choice.Path, wantedPath, StringComparison.OrdinalIgnoreCase));
        if (wantedChoice is not null)
            sessionBox.SelectedItem = wantedChoice;
        else if (string.Equals(typedName, "Без автозагрузки", StringComparison.OrdinalIgnoreCase))
            sessionBox.SelectedIndex = 0;
        else
        {
            sessionBox.SelectedIndex = -1;
            sessionBox.Text = typedName.Length > 0 ? typedName : settings.SessionName ?? string.Empty;
        }
    }

    private async Task PrepareSelectedAsync(bool launchAfter)
    {
        string? sessionName = null;
        if (launchAfter && !TryGetRequestedSessionName(out sessionName)) return;
        var existingSessionPath = launchAfter ? FindExistingSessionPath(sessionName) : null;
        if (existingSessionPath is not null)
        {
            if (!EnsureSfmClosed()) return;
            SetBusy(true, "Открытие сохранённой сессии…");
            var opened = false;
            try
            {
                Log($"Сессия '{sessionName}' уже существует — открываю её без изменений.");
                opened = await EnsureAddonAsync() && await EnsureGlobalPatchAsync() &&
                    await LaunchSfmInternalAsync(existingSessionPath);
            }
            finally
            {
                SetBusy(false, opened ? "SFM запущен" : "Не удалось открыть сессию");
            }
            return;
        }

        var selected = SelectedMaps();
        if (selected.Count == 0)
        {
            MessageBox.Show(this, "Выбери хотя бы одну карту.", "S2FM Repair Manager", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        if (launchAfter && sessionName is not null && selected.Count != 1)
        {
            MessageBox.Show(this, "Для создания или открытия сессии выбери ровно одну карту.", "S2FM Repair Manager", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        if (!EnsureSfmClosed()) return;

        SetBusy(true, "Монтаж карт…");
        var success = true;
        try
        {
            success = await EnsureAddonAsync();
            foreach (var map in selected)
            {
                if (!success) break;
                statusLabel.Text = $"Монтаж {map.Name}…";
                if (map.State == PatchState.Stale)
                {
                    Log($"{map.Name}: карта обновилась, пересобираю патч.");
                    success = await RunScriptAsync("Uninstall-S2FMMapLightFix.ps1", ["-Cs2Root", cs2RootBox.Text.Trim(), "-Addon", addonBox.Text.Trim(), "-Map", map.Name]);
                    if (!success) break;
                }
                var installArguments = new List<string>
                {
                    "-Cs2Root", cs2RootBox.Text.Trim(),
                    "-Addon", addonBox.Text.Trim(),
                    "-Map", map.Name,
                };
                if (map.WorkshopId is not null)
                {
                    installArguments.Add("-WorkshopId");
                    installArguments.Add(map.WorkshopId);
                }
                success = await RunScriptAsync("Install-S2FMMapLightFix.ps1", installArguments);
            }
            if (success)
            {
                Log("Выбранные карты смонтированы.");
                await RefreshMapsWithoutBusyAsync();
                if (launchAfter)
                {
                    string? sessionPath = null;
                    if (sessionName is not null)
                    {
                        sessionPath = await EnsureSessionAsync(sessionName, selected.Single());
                        success = sessionPath is not null;
                    }
                    if (success)
                        success = await EnsureGlobalPatchAsync() && await LaunchSfmInternalAsync(sessionPath);
                }
            }
        }
        finally
        {
            SetBusy(false, success ? "Готово" : "Операция завершилась с ошибкой");
        }
    }

    private async Task LaunchSfmAsync()
    {
        if (!TryGetRequestedSessionName(out var sessionName)) return;
        string? sessionPath = null;
        if (sessionName is not null)
        {
            sessionPath = FindExistingSessionPath(sessionName);
            if (sessionPath is null)
            {
                MessageBox.Show(this, "Такой сессии ещё нет. Выбери карту и нажми «Смонтировать и запустить» — менеджер создаст её.",
                    "Сессия не найдена", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
        }
        if (!EnsureSfmClosed()) return;
        SetBusy(true, "Запуск SFM…");
        var success = false;
        try
        {
            success = await EnsureAddonAsync() && await EnsureGlobalPatchAsync() && await LaunchSfmInternalAsync(sessionPath);
        }
        finally
        {
            SetBusy(false, success ? "SFM запущен" : "Не удалось запустить SFM");
        }
    }

    private async Task UnmountSelectedAsync()
    {
        var selected = SelectedMaps()
            .GroupBy(map => map.Name, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .ToList();
        var mounted = selected.Where(map => File.Exists(map.ManifestPath)).ToList();
        if (mounted.Count == 0)
        {
            MessageBox.Show(this, "Среди выбранных карт нет смонтированных этим лаунчером.",
                "Нечего удалять", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        var names = string.Join(Environment.NewLine, mounted.Take(12).Select(map => $"• {map.Name}"));
        if (mounted.Count > 12) names += $"{Environment.NewLine}• …и ещё {mounted.Count - 12}";
        var confirmation = MessageBox.Show(this,
            $"Будут удалены смонтированные файлы выбранных карт из текущего аддона:{Environment.NewLine}{Environment.NewLine}{names}{Environment.NewLine}{Environment.NewLine}" +
            "Сессии SFM и исходные файлы карт в content удалены не будут.",
            "Демонтировать и удалить карты?", MessageBoxButtons.YesNo, MessageBoxIcon.Warning,
            MessageBoxDefaultButton.Button2);
        if (confirmation != DialogResult.Yes) return;
        if (!EnsureSfmClosed()) return;

        SetBusy(true, "Демонтаж карт…");
        var success = true;
        try
        {
            foreach (var map in mounted)
            {
                statusLabel.Text = $"Удаление {map.Name}…";
                success = await RunScriptAsync("Uninstall-S2FMMapLightFix.ps1",
                    ["-Cs2Root", cs2RootBox.Text.Trim(), "-Addon", addonBox.Text.Trim(), "-Map", map.Name]);
                if (!success) break;
            }
            if (success)
            {
                Log($"Демонтировано и удалено карт: {mounted.Count}.");
                await RefreshMapsWithoutBusyAsync();
            }
        }
        finally
        {
            SetBusy(false, success ? "Готово" : "Удаление завершилось с ошибкой");
        }
    }

    private async Task<bool> LaunchSfmInternalAsync(string? sessionPath)
    {
        var args = new List<string> { "-Cs2Root", cs2RootBox.Text.Trim(), "-Addon", addonBox.Text.Trim() };
        if (sessionPath is not null)
        {
            args.Add("-Session");
            args.Add(sessionPath);
        }
        var result = await RunScriptAsync("Start-S2FMPatched.ps1", args);
        if (result)
            Log("SFM запущен. После его закрытия конфигурация официального клиента восстановится автоматически.");
        else
            await RestoreOfficialClientIfIdleAsync();
        return result;
    }

    private async Task<string?> EnsureSessionAsync(string sessionName, MapInfo map)
    {
        statusLabel.Text = $"Создание сессии {sessionName}…";
        var resultPath = Path.Combine(Path.GetTempPath(), $"s2fm-session-result-{Guid.NewGuid():N}.txt");
        try
        {
            var success = await RunScriptAsync("New-S2FMSession.ps1",
                ["-Cs2Root", cs2RootBox.Text.Trim(), "-Addon", addonBox.Text.Trim(), "-SessionName", sessionName, "-Map", map.Name, "-ResultPath", resultPath]);
            if (!success) return null;

            var sessionPath = File.Exists(resultPath) ? File.ReadAllText(resultPath).Trim() : string.Empty;
            if (sessionPath.Length == 0 || !File.Exists(sessionPath))
            {
                Log("Скрипт завершился без ошибки, но не вернул путь созданной сессии.", true);
                return null;
            }
            LoadSessions(cs2RootBox.Text.Trim(), addonBox.Text.Trim());
            sessionBox.SelectedItem = sessionBox.Items.Cast<SessionChoice>().FirstOrDefault(choice =>
                string.Equals(choice.Path, sessionPath, StringComparison.OrdinalIgnoreCase));
            Log($"Сессия готова: {Path.GetFileNameWithoutExtension(sessionPath)} ({map.Name}).");
            return sessionPath;
        }
        finally
        {
            if (File.Exists(resultPath)) File.Delete(resultPath);
        }
    }

    private bool TryGetRequestedSessionName(out string? sessionName)
    {
        var value = sessionBox.Text.Trim();
        if (value.Length == 0 || string.Equals(value, "Без автозагрузки", StringComparison.OrdinalIgnoreCase))
        {
            sessionName = null;
            return true;
        }
        sessionName = Path.GetFileNameWithoutExtension(value);
        if (!Regex.IsMatch(sessionName, "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"))
        {
            MessageBox.Show(this, "Имя сессии: 1–64 латинских букв, цифр, символов _ или -. Например: session_test",
                "Некорректное имя сессии", MessageBoxButtons.OK, MessageBoxIcon.Information);
            sessionName = null;
            return false;
        }
        return true;
    }

    private string? FindExistingSessionPath(string? sessionName)
    {
        if (sessionName is null) return null;
        if (sessionBox.SelectedItem is SessionChoice selected && selected.Path is not null &&
            string.Equals(Path.GetFileNameWithoutExtension(selected.Path), sessionName, StringComparison.OrdinalIgnoreCase) &&
            File.Exists(selected.Path))
            return Path.GetFullPath(selected.Path);

        var candidate = Path.Combine(cs2RootBox.Text.Trim(), "game", "csgo_addons", addonBox.Text.Trim(),
            "elements", "sessions", $"{sessionName}.dmx");
        return File.Exists(candidate) ? Path.GetFullPath(candidate) : null;
    }

    private async Task<bool> EnsureGlobalPatchAsync()
    {
        var gameInfo = Path.Combine(cs2RootBox.Text.Trim(), "game", "csgo", "gameinfo.gi");
        if (File.Exists(gameInfo) && File.ReadAllText(gameInfo).Contains("\"SparseShadowTrees\" \"0\"", StringComparison.Ordinal))
        {
            UpdateGlobalStatus(cs2RootBox.Text.Trim());
            return true;
        }
        Log("Устанавливаю общий патч Sparse Shadow Trees…");
        var installed = await RunScriptAsync("Install-S2FMPatch.ps1", ["-Cs2Root", cs2RootBox.Text.Trim()]);
        if (installed) UpdateGlobalStatus(cs2RootBox.Text.Trim());
        return installed;
    }

    private async Task<bool> RestoreOfficialClientIfIdleAsync()
    {
        var root = cs2RootBox.Text.Trim();
        var gameInfo = Path.Combine(root, "game", "csgo", "gameinfo.gi");
        if (!File.Exists(gameInfo) ||
            !File.ReadAllText(gameInfo).Contains("\"SparseShadowTrees\" \"0\"", StringComparison.Ordinal))
            return true;

        if (Process.GetProcessesByName("cs2").Length > 0)
        {
            Log("SFM-патч ещё активен, но CS2/SFM запущен. Закрой его и нажми «Обновить», чтобы вернуть совместимость с официальными серверами.", true);
            return false;
        }

        Log("Восстанавливаю конфигурацию официального клиента после предыдущего запуска SFM…");
        var restored = await RunScriptAsync("Uninstall-S2FMPatch.ps1", ["-Cs2Root", root]);
        if (restored) Log("Конфигурация официального клиента восстановлена.");
        return restored;
    }

    private async Task<bool> EnsureAddonAsync()
    {
        var addon = addonBox.Text.Trim();
        if (!Regex.IsMatch(addon, "^[A-Za-z0-9_-]+$"))
        {
            Log("Имя аддона может содержать только латинские буквы, цифры, _ и -.", true);
            return false;
        }
        return await RunScriptAsync("Initialize-S2FMAddon.ps1",
            ["-Cs2Root", cs2RootBox.Text.Trim(), "-Addon", addon]);
    }

    private async Task<bool> RunScriptAsync(string scriptName, IReadOnlyList<string> arguments)
    {
        var scriptPath = Path.Combine(kitRoot, scriptName);
        if (!File.Exists(scriptPath))
        {
            Log($"Не найден файл: {scriptPath}", true);
            return false;
        }

        var start = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = kitRoot,
        };
        start.ArgumentList.Add("-NoLogo");
        start.ArgumentList.Add("-NoProfile");
        start.ArgumentList.Add("-NonInteractive");
        start.ArgumentList.Add("-ExecutionPolicy");
        start.ArgumentList.Add("Bypass");
        start.ArgumentList.Add("-Command");
        start.ArgumentList.Add(BuildPowerShellCommand(scriptPath, arguments));

        Log($"> {scriptName} {string.Join(' ', arguments.Select(QuoteForLog))}");
        using var process = new Process { StartInfo = start };
        process.Start();
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        var stdout = await stdoutTask;
        var stderr = await stderrTask;
        if (!string.IsNullOrWhiteSpace(stdout)) Log(stdout.TrimEnd());
        if (!string.IsNullOrWhiteSpace(stderr)) Log(stderr.TrimEnd(), true);
        if (process.ExitCode != 0)
        {
            Log($"{scriptName}: код ошибки {process.ExitCode}.", true);
            return false;
        }
        return true;
    }

    private async Task RefreshMapsWithoutBusyAsync()
    {
        allMaps.Clear();
        var root = cs2RootBox.Text.Trim();
        var addon = addonBox.Text.Trim();
        LoadAddons(root);
        var scan = await Task.Run(() => DiscoverMaps(root, addon));
        allMaps.AddRange(scan.Maps);
        foreach (var warning in scan.Warnings) Log(warning, true);
        ApplyMapFilter();
        UpdateGlobalStatus(root);
    }

    private List<MapInfo> SelectedMaps() => mapGrid.SelectedRows.Cast<DataGridViewRow>()
        .Select(row => row.DataBoundItem as MapInfo)
        .Where(map => map is not null)
        .Cast<MapInfo>()
        .OrderBy(map => map.DisplayName)
        .ToList();

    private bool EnsureSfmClosed()
    {
        if (Process.GetProcessesByName("cs2").Length == 0) return true;
        MessageBox.Show(this, "Сначала сохрани сессию и закрой CS2/SFM. Приложение не завершает процесс принудительно, чтобы не потерять работу.",
            "CS2/SFM запущен", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        return false;
    }

    private void UpdateGlobalStatus(string root)
    {
        var gameInfo = Path.Combine(root, "game", "csgo", "gameinfo.gi");
        bool patched;
        try
        {
            patched = File.Exists(gameInfo) && File.ReadAllText(gameInfo).Contains("\"SparseShadowTrees\" \"0\"", StringComparison.Ordinal);
        }
        catch (IOException)
        {
            return;
        }
        globalStatusLabel.Text = patched
            ? "● SFM-патч активен — официальные серверы недоступны"
            : "● Официальный клиент совместим";
        globalStatusLabel.ForeColor = patched ? Danger : Success;
        globalStatusLabel.Left = Math.Max(0, globalStatusLabel.Parent?.ClientSize.Width - globalStatusLabel.Width - 6 ?? 0);
    }

    private void UpdateSelectionLabel() => selectionLabel.Text = $"Выбрано: {mapGrid.SelectedRows.Count}";

    private void MapGrid_CellFormatting(object? sender, DataGridViewCellFormattingEventArgs e)
    {
        if (mapGrid.Columns[e.ColumnIndex].Name != "Status" || mapGrid.Rows[e.RowIndex].DataBoundItem is not MapInfo map) return;
        e.CellStyle.ForeColor = map.State switch
        {
            PatchState.Ready => Success,
            PatchState.Stale => Warning,
            PatchState.Broken or PatchState.Untracked => Danger,
            _ => TextMuted,
        };
    }

    private void SetBusy(bool value, string text)
    {
        busy = value;
        progressBar.Visible = value;
        statusLabel.Text = text;
        foreach (var control in new Control[] { prepareButton, prepareLaunchButton, launchButton, unmountButton, refreshButton, browseButton, cs2RootBox, addonBox, mapGrid, showWorkshopCheckBox, mountedOnlyCheckBox })
            control.Enabled = !value;
        UseWaitCursor = value;
    }

    private void Log(string message, bool error = false)
    {
        if (InvokeRequired)
        {
            BeginInvoke(() => Log(message, error));
            return;
        }
        logBox.SelectionStart = logBox.TextLength;
        logBox.SelectionColor = error ? Color.FromArgb(255, 132, 142) : Color.FromArgb(194, 204, 222);
        logBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {message}{Environment.NewLine}");
        logBox.ScrollToCaret();
    }

    private void BrowseButton_Click(object? sender, EventArgs e)
    {
        using var dialog = new FolderBrowserDialog
        {
            Description = "Выбери папку Counter-Strike Global Offensive",
            SelectedPath = Directory.Exists(cs2RootBox.Text) ? cs2RootBox.Text : DefaultCs2Root,
            UseDescriptionForTitle = true,
        };
        if (dialog.ShowDialog(this) == DialogResult.OK) cs2RootBox.Text = dialog.SelectedPath;
    }

    private void LoadSettings()
    {
        var settings = LoadSettingsObject();
        cs2RootBox.Text = settings.Cs2Root is { Length: > 0 } savedRoot && IsCs2Root(savedRoot)
            ? savedRoot
            : DefaultCs2Root;
        addonBox.Text = string.IsNullOrWhiteSpace(settings.Addon) ||
            (settings.SchemaVersion < 2 && string.Equals(settings.Addon, "camcorder", StringComparison.OrdinalIgnoreCase))
                ? "sfm_repaired"
                : settings.Addon;
        sessionBox.Text = settings.SessionName ?? (settings.Session is null ? string.Empty : Path.GetFileNameWithoutExtension(settings.Session));
    }

    private ManagerSettings LoadSettingsObject()
    {
        try
        {
            return File.Exists(settingsPath)
                ? JsonSerializer.Deserialize<ManagerSettings>(File.ReadAllText(settingsPath)) ?? new()
                : new();
        }
        catch { return new(); }
    }

    private void SaveSettings()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(settingsPath)!);
            var session = (sessionBox.SelectedItem as SessionChoice)?.Path;
            var sessionName = string.Equals(sessionBox.Text.Trim(), "Без автозагрузки", StringComparison.OrdinalIgnoreCase)
                ? null
                : Path.GetFileNameWithoutExtension(sessionBox.Text.Trim());
            File.WriteAllText(settingsPath, JsonSerializer.Serialize(
                new ManagerSettings(cs2RootBox.Text.Trim(), addonBox.Text.Trim(), session, sessionName, 2),
                new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    private static string ResolveKitRoot()
    {
        var candidates = new List<string> { AppContext.BaseDirectory, Environment.CurrentDirectory };
        var current = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 6 && current is not null; i++, current = current.Parent) candidates.Add(current.FullName);
        foreach (var candidate in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
            if (File.Exists(Path.Combine(candidate, "Install-S2FMMapLightFix.ps1"))) return candidate;
        return AppContext.BaseDirectory;
    }

    private static IReadOnlyList<string> RequiredKitFiles() =>
    [
        "S2FMPatch.Common.ps1",
        "Initialize-S2FMAddon.ps1",
        "Install-S2FMPatch.ps1",
        "Uninstall-S2FMPatch.ps1",
        "Install-S2FMMapLightFix.ps1",
        "Uninstall-S2FMMapLightFix.ps1",
        "Start-S2FMPatched.ps1",
        "Clear-S2FMCommunitySearchPath.ps1",
        "New-S2FMSession.ps1",
        Path.Combine("templates", "blank-session.dmx.b64"),
        Path.Combine("tools", "S2FMEntityPatcher.exe"),
        Path.Combine("tools", "S2FMVpkPatcher.exe"),
        Path.Combine("tools", "ValveResourceFormat", "Source2Viewer-CLI.exe"),
        Path.Combine("tools", "ffmpeg", "bin", "ffmpeg.exe"),
    ];

    private static bool IsCs2Root(string path) =>
        File.Exists(Path.Combine(path, "game", "bin", "win64", "cs2.exe")) &&
        File.Exists(Path.Combine(path, "game", "csgo", "gameinfo.gi"));

    private static string? FindCs2Root()
    {
        var steamRoots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        static void AddRoot(HashSet<string> roots, object? value)
        {
            if (value is string path && path.Length > 0)
                roots.Add(path.Replace('/', Path.DirectorySeparatorChar));
        }

        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam");
            AddRoot(steamRoots, key?.GetValue("SteamPath"));
        }
        catch { }
        foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
        {
            try
            {
                using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view);
                using var key = baseKey.OpenSubKey(@"SOFTWARE\Valve\Steam");
                AddRoot(steamRoots, key?.GetValue("InstallPath"));
            }
            catch { }
        }

        var programFilesSteam = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam");
        if (Directory.Exists(programFilesSteam)) steamRoots.Add(programFilesSteam);

        var libraries = new HashSet<string>(steamRoots, StringComparer.OrdinalIgnoreCase);
        foreach (var steamRoot in steamRoots)
        {
            var vdf = Path.Combine(steamRoot, "steamapps", "libraryfolders.vdf");
            if (!File.Exists(vdf)) continue;
            try
            {
                var text = File.ReadAllText(vdf);
                foreach (Match match in Regex.Matches(text, "\\\"path\\\"\\s+\\\"(?<path>[^\\\"]+)\\\"", RegexOptions.IgnoreCase))
                    libraries.Add(match.Groups["path"].Value.Replace("\\\\", "\\"));
            }
            catch { }
        }

        foreach (var library in libraries)
        {
            var candidate = Path.Combine(library, "steamapps", "common", "Counter-Strike Global Offensive");
            if (IsCs2Root(candidate)) return candidate;
        }
        return null;
    }

    private static Panel Card() => new()
    {
        Dock = DockStyle.Fill,
        BackColor = Surface,
        Margin = new Padding(0, 0, 0, 12),
    };

    private static Label FieldLabel(string text) => new()
    {
        Text = text,
        AutoSize = false,
        TextAlign = ContentAlignment.MiddleLeft,
        Dock = DockStyle.Fill,
        ForeColor = TextMuted,
        AutoEllipsis = false,
    };

    private static void ConfigureTextBox(TextBox box)
    {
        box.Dock = DockStyle.Fill;
        box.BackColor = SurfaceAlt;
        box.ForeColor = TextPrimary;
        box.BorderStyle = BorderStyle.FixedSingle;
        box.Margin = new Padding(3, 5, 8, 5);
    }

    private static void StyleButton(Button button, Color background, Color foreground, int width = 110)
    {
        button.Width = width;
        button.Height = 40;
        button.BackColor = background;
        button.ForeColor = foreground;
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.Cursor = Cursors.Hand;
        button.Font = new Font("Segoe UI Semibold", 9.5F);
        button.Margin = new Padding(0, 0, 9, 0);
    }

    private static string QuoteForLog(string value) => value.Contains(' ') ? $"\"{value}\"" : value;

    private static string BuildPowerShellCommand(string scriptPath, IReadOnlyList<string> arguments)
    {
        if (arguments.Count % 2 != 0) throw new ArgumentException("PowerShell arguments must be name/value pairs.");
        var command = new StringBuilder("$OutputEncoding = [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); & ");
        command.Append(PowerShellLiteral(scriptPath));
        for (var index = 0; index < arguments.Count; index += 2)
        {
            var name = arguments[index];
            if (name.Length < 2 || name[0] != '-' || name.Skip(1).Any(character => !char.IsLetterOrDigit(character)))
                throw new ArgumentException($"Invalid PowerShell parameter name: {name}");
            command.Append(' ').Append(name).Append(' ').Append(PowerShellLiteral(arguments[index + 1]));
        }
        command.Append("; $invocationSucceeded = $?; $nativeCode = $LASTEXITCODE; if (-not $invocationSucceeded) { if ($nativeCode) { exit $nativeCode } else { exit 1 } }; exit 0");
        return command.ToString();
    }

    private static string PowerShellLiteral(string value) => $"'{value.Replace("'", "''")}'";

    internal bool WriteLayoutDiagnostics(string reportPath, string screenshotPath)
    {
        PerformLayout();
        Refresh();
        Application.DoEvents();
        var scanWait = Stopwatch.StartNew();
        while (busy && scanWait.Elapsed < TimeSpan.FromSeconds(30))
        {
            Application.DoEvents();
            Thread.Sleep(25);
        }

        var issues = new List<string>();
        var visibleTexts = new HashSet<string>(StringComparer.Ordinal);
        InspectControlTree(this, issues, visibleTexts);
        foreach (var expected in new[] { "Аддон", "Поиск", "Отображать карты из мастерской", "Только смонтированные", "Смонтировать карты", "Смонтировать и запустить", "Запустить SFM", "Демонтировать и удалить" })
            if (!visibleTexts.Contains(expected)) issues.Add($"Required text is missing: {expected}");
        if (addonBox.DropDownStyle != ComboBoxStyle.DropDown)
            issues.Add("Addon selector is not editable");
        var originalAddon = addonBox.Text;
        addonBox.Text = "custom_addon_test";
        LoadAddons(cs2RootBox.Text.Trim());
        if (!string.Equals(addonBox.Text, "custom_addon_test", StringComparison.Ordinal))
            issues.Add("Custom addon name is not preserved while refreshing the addon list");
        addonBox.Text = originalAddon;
        var availableAddons = LoadAddons(cs2RootBox.Text.Trim());
        if (showWorkshopCheckBox.Checked)
            issues.Add("Workshop maps checkbox must be unchecked by default");
        if (mountedOnlyCheckBox.Checked)
            issues.Add("Mounted-only checkbox must be unchecked by default");
        var defaultRows = mapGrid.Rows.Cast<DataGridViewRow>()
            .Select(row => row.DataBoundItem as MapInfo)
            .Where(map => map is not null)
            .Cast<MapInfo>()
            .ToList();
        if (defaultRows.Any(map => map.IsWorkshop))
            issues.Add("Workshop maps are visible while the checkbox is unchecked");
        showWorkshopCheckBox.Checked = true;
        Application.DoEvents();
        if (allMaps.Any(map => map.IsWorkshop) && !mapGrid.Rows.Cast<DataGridViewRow>()
            .Any(row => row.DataBoundItem is MapInfo { IsWorkshop: true }))
            issues.Add("Workshop maps do not appear after enabling the checkbox");
        showWorkshopCheckBox.Checked = false;
        Application.DoEvents();
        var readyProbe = new MapInfo("__mounted_ready_probe__", string.Empty, 0, DateTime.MinValue,
            PatchState.Ready, string.Empty, string.Empty, null, null);
        var unreadyProbe = new MapInfo("__mounted_unready_probe__", string.Empty, 0, DateTime.MinValue,
            PatchState.NotInstalled, string.Empty, string.Empty, null, null);
        allMaps.Add(readyProbe);
        allMaps.Add(unreadyProbe);
        mountedOnlyCheckBox.Checked = true;
        Application.DoEvents();
        var mountedRows = mapGrid.Rows.Cast<DataGridViewRow>()
            .Select(row => row.DataBoundItem as MapInfo)
            .Where(map => map is not null)
            .Cast<MapInfo>()
            .ToList();
        if (!mountedRows.Contains(readyProbe))
            issues.Add("Mounted-only filter hides a ready map");
        if (mountedRows.Contains(unreadyProbe) || mountedRows.Any(map => map.State != PatchState.Ready))
            issues.Add("Mounted-only filter displays a map that is not ready");
        mountedOnlyCheckBox.Checked = false;
        allMaps.Remove(readyProbe);
        allMaps.Remove(unreadyProbe);
        ApplyMapFilter();
        Application.DoEvents();
        foreach (var removed in new[] { "Удалить патч", "Собрать MP4" })
            if (visibleTexts.Contains(removed)) issues.Add($"Removed control is still visible: {removed}");
        var gridProbe = TextRenderer.MeasureText("ar_shoots_night", mapGrid.Font,
            new Size(int.MaxValue, int.MaxValue), TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
        var gridTextHeight = mapGrid.RowTemplate.Height - mapGrid.DefaultCellStyle.Padding.Vertical - 4;
        if (gridProbe.Height > gridTextHeight)
            issues.Add($"Map row text is clipped vertically ({gridProbe.Height}>{gridTextHeight})");

        var report = new
        {
            Passed = issues.Count == 0,
            Dpi = DeviceDpi,
            ClientSize = new { ClientSize.Width, ClientSize.Height },
            DisplayedMaps = mapGrid.Rows.Count,
            AvailableWorkshopMaps = allMaps.Count(map => map.IsWorkshop),
            AvailableReadyMaps = allMaps.Count(map => map.State == PatchState.Ready),
            AvailableAddons = availableAddons,
            AddonSelectorEditable = addonBox.DropDownStyle == ComboBoxStyle.DropDown,
            VisibleTexts = visibleTexts.OrderBy(text => text).ToArray(),
            Issues = issues,
        };
        var reportFullPath = Path.GetFullPath(reportPath);
        var screenshotFullPath = Path.GetFullPath(screenshotPath);
        Directory.CreateDirectory(Path.GetDirectoryName(reportFullPath)!);
        Directory.CreateDirectory(Path.GetDirectoryName(screenshotFullPath)!);
        File.WriteAllText(reportFullPath, JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
        using var bitmap = new Bitmap(Width, Height);
        DrawToBitmap(bitmap, new Rectangle(Point.Empty, Size));
        bitmap.Save(screenshotFullPath, ImageFormat.Png);
        return issues.Count == 0;
    }

    internal bool WriteMapScanDiagnostics(string cs2Root, string reportPath)
    {
        try
        {
            var scan = DiscoverMaps(Path.GetFullPath(cs2Root), "sfm_repaired");
            var report = new
            {
                Passed = scan.Warnings.Count == 0,
                Total = scan.Maps.Count,
                Workshop = scan.Maps.Count(map => map.IsWorkshop),
                Maps = scan.Maps.Select(map => new
                {
                    map.Name,
                    map.DisplayName,
                    map.WorkshopId,
                    map.WorkshopTitle,
                    map.SourcePath,
                }).ToArray(),
                scan.Warnings,
            };
            var fullPath = Path.GetFullPath(reportPath);
            Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
            File.WriteAllText(fullPath, JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
            return report.Passed;
        }
        catch (Exception ex)
        {
            var fullPath = Path.GetFullPath(reportPath);
            Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
            File.WriteAllText(fullPath, JsonSerializer.Serialize(new { Passed = false, Error = ex.ToString() }, new JsonSerializerOptions { WriteIndented = true }));
            return false;
        }
    }

    private static void InspectControlTree(Control parent, List<string> issues, HashSet<string> visibleTexts)
    {
        foreach (Control control in parent.Controls)
        {
            if (!control.Visible) continue;
            if (!string.IsNullOrWhiteSpace(control.Text)) visibleTexts.Add(control.Text);

            if (control is Label or Button or CheckBox)
            {
                var measured = TextRenderer.MeasureText(control.Text, control.Font, new Size(int.MaxValue, int.MaxValue),
                    TextFormatFlags.SingleLine | TextFormatFlags.NoPadding);
                var internalInset = control is Button ? 12 : 0;
                var availableWidth = Math.Max(0, control.ClientSize.Width - control.Padding.Horizontal - internalInset);
                var availableHeight = Math.Max(0, control.ClientSize.Height - control.Padding.Vertical - internalInset / 2);
                if (measured.Width > availableWidth)
                    issues.Add($"Text is clipped horizontally: '{control.Text}' ({measured.Width}>{availableWidth})");
                if (measured.Height > availableHeight)
                    issues.Add($"Text is clipped vertically: '{control.Text}' ({measured.Height}>{availableHeight})");
            }
            if (control.Right > parent.ClientSize.Width + 1 || control.Bottom > parent.ClientSize.Height + 1)
                issues.Add($"Control exceeds parent bounds: {control.GetType().Name} '{control.Text}'");
            InspectControlTree(control, issues, visibleTexts);
        }
    }
}

internal enum PatchState
{
    NotInstalled,
    Ready,
    Stale,
    Broken,
    Untracked,
}

internal sealed record MapInfo(
    string Name,
    string SourcePath,
    long Size,
    DateTime Modified,
    PatchState State,
    string ManifestPath,
    string AddonVpkPath,
    string? WorkshopId,
    string? WorkshopTitle)
{
    public bool IsWorkshop => WorkshopId is not null;
    public string DisplayName => IsWorkshop
        ? $"{WorkshopTitle} — {Name}  [Workshop]"
        : Name;

    public string Status => State switch
    {
        PatchState.Ready => "● Смонтирована",
        PatchState.Stale => "● Требует обновления",
        PatchState.Broken => "● Патч повреждён",
        PatchState.Untracked => "● Не отслеживается",
        _ => "Не смонтирована",
    };

    public string SizeText => Size >= 1024L * 1024 * 1024
        ? $"{Size / (1024d * 1024 * 1024):0.00} ГБ"
        : $"{Size / (1024d * 1024):0} МБ";
    public string ModifiedText => Modified.ToString("dd.MM.yyyy HH:mm");
}

internal sealed record MapScanResult(List<MapInfo> Maps, List<string> Warnings);

internal sealed record SessionChoice(string DisplayName, string? Path)
{
    public override string ToString() => DisplayName;
}

internal sealed record ManagerSettings(
    string? Cs2Root = null,
    string? Addon = null,
    string? Session = null,
    string? SessionName = null,
    int SchemaVersion = 0);
