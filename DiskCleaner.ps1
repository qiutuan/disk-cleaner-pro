# ============================================================
#  DiskCleanerPro - C 盘智能清理工具
#  PowerShell + WinForms（橙色主题，纯代码绘制，无图片资源）
#  启动：启动清理工具.bat（pwsh -STA 优先，PS5.1 兜底）
#  写入边界：所有运行时数据仅写入本目录 runtime\ 内
# ============================================================

param([switch]$SelfTest)   # -SelfTest：仅对 clear\testdata 内自建数据跑引擎自测，不弹 UI、不碰真实文件

#region 基础设置
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Continue'   # 绝不因单个错误中断程序
$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# 工具目录（脚本自身所在目录 = 唯一允许写入的位置）
$script:ToolRoot = $PSScriptRoot
$script:DataDir  = Join-Path $script:ToolRoot 'runtime'
$script:LogDir   = Join-Path $script:DataDir 'logs'
#endregion

#region 主题色板（无图片资源，纯代码着色）
# Fluent 风浅色主题：中性底色承载内容，橙色只做主操作点缀；风险色换更沉稳的现代色阶
$script:Theme = @{
  Bg        = '#F5F6F8'   # 主背景（中性浅灰）
  Banner    = '#FFFFFF'   # 顶部栏（白）
  Primary   = '#F97316'   # 主操作色（橙）
  Secondary = '#F97316'   # 次级（与主色一致，弱化多橙叠加）
  Green     = '#16A34A'   # 绝对安全
  Yellow    = '#D97706'   # 谨慎
  Red       = '#DC2626'   # 需确认
  Text      = '#1F2937'   # 主文字（深灰蓝）
  SubText   = '#6B7280'   # 次级文字
  Disabled  = '#C4C9D0'
  FontUi    = 'Microsoft YaHei UI'   # 界面统一字体（Win11 风格）
  CardBg    = '#FFFFFF'   # 卡片/面板背景
  CardLine  = '#E5E7EB'   # 发丝分隔线
  LightBtn  = '#EEF1F4'   # 浅灰副按钮（深色文字）
  NavBg     = '#EEF1F4'   # 侧边导航条背景
  NavHover  = '#E4E8ED'   # 侧边导航悬停
}
#endregion

#region 日志
function Write-CleanLog {
  param([string]$Message)
  try {
    if (-not (Test-Path $script:LogDir)) {
      New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    }
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath (Join-Path $script:LogDir 'cleanup.log') -Value $line -Encoding UTF8
  } catch { }
}
#endregion

#region 程序集加载（引擎与 UI 共用，须在异常兜底之前）
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic   # 回收站删除 API
Add-Type -AssemblyName PresentationFramework    # WPF 界面（v1.3.0）
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
#endregion

#region 现代控件（Win11 风格：圆角按钮 / 圆角进度条 / 卡片面板，纯代码绘制无图片）
# 视觉样式必须在创建任何控件之前开启一次（幂等，worker runspace 中重复调用无副作用）
try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
if (-not ('DiskCleaner.ModernButton' -as [type])) {
# .NET 下 WinForms/绘图类型分散在多个私有程序集（System.Private.Windows.* 等），
# 逐个引用易漏；此处直接把进程已加载的全部程序集作为编译引用，简单可靠
$uiRefs = [System.AppDomain]::CurrentDomain.GetAssemblies() |
  Where-Object { $_.Location } | ForEach-Object { $_.Location } | Sort-Object -Unique
Add-Type -ReferencedAssemblies $uiRefs -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Text.RegularExpressions;
using System.Windows.Forms;
namespace DiskCleaner {
  public static class Ui {
    internal static GraphicsPath Rounded(Rectangle r, int rad) {
      int d = rad * 2;
      if (d > r.Width) d = r.Width;
      if (d > r.Height) d = r.Height;
      GraphicsPath p = new GraphicsPath();
      p.AddArc(r.X, r.Y, d, d, 180, 90);
      p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
      p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
      p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
      p.CloseFigure();
      return p;
    }
    internal static Color Shift(Color c, int amt) {
      return Color.FromArgb(Math.Max(0, Math.Min(255, c.R + amt)),
                            Math.Max(0, Math.Min(255, c.G + amt)),
                            Math.Max(0, Math.Min(255, c.B + amt)));
    }
    internal static bool IsDark(Color c) {
      return (0.299 * c.R + 0.587 * c.G + 0.114 * c.B) < 140;
    }
  }
  // 圆角按钮：深色底悬停提亮、浅色底悬停加深；禁用自动置灰
  public class ModernButton : Button {
    private int _radius = 6;
    private Color _hover = Color.Empty;
    private Color _press = Color.Empty;
    private bool _isHover;
    private bool _isDown;
    public ModernButton() {
      SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
               ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
      BackColor = Color.FromArgb(0xFB, 0xE7, 0xCC);
      ForeColor = Color.FromArgb(0x6D, 0x4C, 0x41);
      FlatStyle = FlatStyle.Flat;
      FlatAppearance.BorderSize = 0;
    }
    public int Radius { get { return _radius; } set { _radius = value; Invalidate(); } }
    public Color HoverBackColor { get { return _hover; } set { _hover = value; Invalidate(); } }
    public Color PressBackColor { get { return _press; } set { _press = value; Invalidate(); } }
    protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); _isHover = true; Invalidate(); }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); _isHover = false; Invalidate(); }
    protected override void OnMouseDown(MouseEventArgs me) { base.OnMouseDown(me); _isDown = true; Invalidate(); }
    protected override void OnMouseUp(MouseEventArgs me) { base.OnMouseUp(me); _isDown = false; Invalidate(); }
    protected override void OnPaint(PaintEventArgs e) {
      e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
      Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
      Color fill = Enabled ? BackColor : Color.FromArgb(0xEC, 0xEC, 0xEC);
      if (Enabled && _isDown) {
        fill = (_press != Color.Empty) ? _press : (Ui.IsDark(BackColor) ? Ui.Shift(BackColor, -28) : Ui.Shift(BackColor, -32));
      } else if (Enabled && _isHover) {
        fill = (_hover != Color.Empty) ? _hover : (Ui.IsDark(BackColor) ? Ui.Shift(BackColor, 22) : Ui.Shift(BackColor, -16));
      }
      using (GraphicsPath path = Ui.Rounded(r, _radius)) {
        using (SolidBrush b = new SolidBrush(fill)) e.Graphics.FillPath(b, path);
        TextRenderer.DrawText(e.Graphics, Text, Font,
          new Rectangle(1, 1, Width - 2, Height - 2),
          Enabled ? ForeColor : Color.FromArgb(0x9E, 0x9E, 0x9E),
          TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter |
          TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
      }
    }
  }
  // 圆角进度条：连续态画橙色渐变填充，Marquee 态自带位移动画
  public class ModernProgressBar : ProgressBar {
    private Color _fill = Color.FromArgb(0xF5, 0x7C, 0x00);
    private Color _track = Color.FromArgb(0xEF, 0xE3, 0xD5);
    private System.Windows.Forms.Timer _anim;
    private int _pos = 0;
    private bool _running = false;
    public ModernProgressBar() {
      SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
               ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    public Color BarColor { get { return _fill; } set { _fill = value; Invalidate(); } }
    public Color TrackColor { get { return _track; } set { _track = value; Invalidate(); } }
    private void SetupAnim() {
      if (_anim != null) return;
      _anim = new System.Windows.Forms.Timer();
      _anim.Interval = 24;
      _anim.Tick += delegate { _pos = (_pos + 6) % Math.Max(80, Width + 80); Invalidate(); };
    }
    private void SetRunning(bool r) {
      if (r && !_running) { SetupAnim(); _anim.Start(); _running = true; }
      else if (!r && _running) { if (_anim != null) _anim.Stop(); _running = false; }
    }
    protected override void OnStyleChanged(EventArgs e) {
      base.OnStyleChanged(e);
      SetRunning(Style == ProgressBarStyle.Marquee);
    }
    protected override void OnVisibleChanged(EventArgs e) {
      base.OnVisibleChanged(e);
      if (Style == ProgressBarStyle.Marquee) SetRunning(Visible);
    }
    protected override void OnHandleDestroyed(EventArgs e) {
      SetRunning(false);
      base.OnHandleDestroyed(e);
    }
    protected override void OnPaintBackground(PaintEventArgs pevent) { }
    protected override void OnPaint(PaintEventArgs e) {
      e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
      Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
      int rad = Math.Max(3, Math.Min(8, Height / 2));
      using (GraphicsPath path = Ui.Rounded(r, rad)) {
        using (SolidBrush bg = new SolidBrush(_track)) e.Graphics.FillPath(bg, path);
      }
      if (Style == ProgressBarStyle.Marquee) {
        int seg = Math.Max(70, Width / 3);
        int x = _pos - seg;
        if (x < 0) x = 0;
        int w = Math.Min(seg, Width - x);
        if (w > 2) {
          Rectangle fr = new Rectangle(x, 1, w, Height - 2);
          using (GraphicsPath fp = Ui.Rounded(fr, rad)) {
            using (LinearGradientBrush fb = new LinearGradientBrush(fr, _fill, Ui.Shift(_fill, 26), 90f))
              e.Graphics.FillPath(fb, fp);
          }
        }
      } else {
        double pct = (Maximum > 0) ? (double)Value / Maximum : 0;
        int w = (int)((Width - 2) * pct);
        if (w > 0) {
          Rectangle fr = new Rectangle(1, 1, w, Height - 2);
          using (GraphicsPath fp = Ui.Rounded(fr, rad)) {
            using (LinearGradientBrush fb = new LinearGradientBrush(fr, _fill, Ui.Shift(_fill, 26), 90f))
              e.Graphics.FillPath(fb, fp);
          }
        }
      }
    }
  }
  // 卡片面板：白底圆角 + 细描边（用于右侧详情栏等独立卡片）
  public class CardPanel : Panel {
    private int _radius = 8;
    private Color _border = Color.FromArgb(0xE8, 0xE0, 0xD8);
    public CardPanel() {
      SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
               ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw |
               ControlStyles.SupportsTransparentBackColor, true);
      BackColor = Color.White;
    }
    public int Radius { get { return _radius; } set { _radius = value; Invalidate(); } }
    public Color BorderColor { get { return _border; } set { _border = value; Invalidate(); } }
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) {
      e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
      Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
      using (GraphicsPath path = Ui.Rounded(r, _radius)) {
        using (SolidBrush b = new SolidBrush(BackColor)) e.Graphics.FillPath(b, path);
        using (Pen p = new Pen(_border)) e.Graphics.DrawPath(p, path);
      }
    }
  }
  // 列表排序器：Mode 0=文本字典序 1=数值（解析 KB/MB/GB/TB/PB 单位与百分比；解析失败回退文本）
  public class LvSorter : System.Collections.IComparer {
    public int Column = -1;
    public int Mode = 0;
    public int Dir = 1;
    static double ParseNum(string s) {
      if (string.IsNullOrEmpty(s)) return double.NegativeInfinity;
      string t = s.Replace(",", "").Trim();
      Match m = Regex.Match(t, @"^(-?[\d.]+)\s*([KMGTP])?(?:B)?\s*%?\s*$", RegexOptions.IgnoreCase);
      if (m.Success) {
        double v;
        if (!double.TryParse(m.Groups[1].Value, System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out v)) return double.NegativeInfinity;
        string u = m.Groups[2].Value.ToUpperInvariant();
        if (u == "K") v *= 1024.0; else if (u == "M") v *= 1048576.0;
        else if (u == "G") v *= 1073741824.0; else if (u == "T") v *= 1099511627776.0;
        else if (u == "P") v *= 1125899906842624.0;
        return v;
      }
      return double.NegativeInfinity;
    }
    public int Compare(object x, object y) {
      System.Windows.Forms.ListViewItem a = (System.Windows.Forms.ListViewItem)x;
      System.Windows.Forms.ListViewItem b = (System.Windows.Forms.ListViewItem)y;
      string sa = (a.SubItems.Count > Column) ? a.SubItems[Column].Text : "";
      string sb = (b.SubItems.Count > Column) ? b.SubItems[Column].Text : "";
      int r;
      if (Mode == 1) {
        double da = ParseNum(sa); double db = ParseNum(sb);
        if (double.IsNegativeInfinity(da) || double.IsNegativeInfinity(db))
          r = string.Compare(sa, sb, StringComparison.CurrentCulture);
        else r = da.CompareTo(db);
      } else {
        r = string.Compare(sa, sb, StringComparison.CurrentCulture);
      }
      return r * Dir;
    }
  }
}
'@
}
# 统一创建现代按钮：$Back 十六进制，默认浅橙副按钮样式（深色主按钮/红色危险按钮由调用处显式覆盖）
function New-ModernButton {
  param([string]$Text, [string]$Back = $script:Theme.LightBtn, [string]$Fore = '#374151', [int]$FontSize = 9, [switch]$Bold)
  $b = New-Object DiskCleaner.ModernButton
  $b.Text = $Text
  $b.BackColor = [System.Drawing.ColorTranslator]::FromHtml($Back)
  $b.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($Fore)
  $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
  $b.Font = New-Object System.Drawing.Font($script:Theme.FontUi, $FontSize, $style)
  return $b
}
# 统一创建现代进度条：$Fill 填充色，$Track 轨道色
function New-ModernProgressBar {
  param([string]$Fill = $script:Theme.Primary, [string]$Track = '#EFE3D5')
  $b = New-Object DiskCleaner.ModernProgressBar
  $b.BarColor = [System.Drawing.ColorTranslator]::FromHtml($Fill)
  $b.TrackColor = [System.Drawing.ColorTranslator]::FromHtml($Track)
  return $b
}

function Register-ColumnSort {
  # 列头点击排序助手（所有列表通用）：
  #   NumericCols 中的列按数值排序（含 KB/MB/GB/TB/PB/百分比解析，解析失败回退文本字典序）；
  #   同一列再次点击切换升/降序。排序器状态挂在 $Lv.Tag 上，事件闭包不捕获外部变量
  param([System.Windows.Forms.ListView]$Lv, [int[]]$NumericCols = @())
  $s0 = New-Object DiskCleaner.LvSorter
  $s0.Column = -1
  $Lv.Tag = @{ Sorter = $s0; Numeric = $NumericCols }
  $Lv.add_ColumnClick({
    param($s, $e)
    try {
      $st = $s.Tag
      if (-not $st) { return }
      $sorter = $st.Sorter
      $col = $e.Column
      if ($sorter.Column -eq $col) {
        $sorter.Dir = - $sorter.Dir
      } else {
        $sorter.Column = $col
        $sorter.Dir = 1
        $sorter.Mode = if (@($st.Numeric) -contains $col) { 1 } else { 0 }
      }
      $s.Sorting = 'None'
      $s.ListViewItemSorter = $sorter   # 赋值即触发排序
    } catch { }
  })
}
#endregion

#region 全局异常兜底（程序绝不闪退）
[AppDomain]::CurrentDomain.add_UnhandledException({
  param($s, $e)
  Write-CleanLog ("UnhandledException: " + $e.ExceptionObject.ToString())
})
[System.Windows.Forms.Application]::add_ThreadException({
  param($s, $e)
  Write-CleanLog ("ThreadException: " + $e.Exception.Message)
  try { [System.Windows.Forms.MessageBox]::Show($e.Exception.Message, 'DiskCleanerPro 提示', 'OK', 'Warning') } catch { }
})
#endregion

#region 路径工具（环境变量 + 通配符展开）
function Expand-EnvPath {
  param([string]$Path)
  if (-not $Path) { return $Path }
  $r = [Environment]::ExpandEnvironmentVariables($Path)
  # 兼容 $env:VAR 写法
  $r = [regex]::Replace($r, '\$env:(\w+)', {
    param($m) [Environment]::GetEnvironmentVariable($m.Groups[1].Value)
  })
  return $r
}

function Get-ExpandedPaths {
  # 支持多级通配符：%LOCALAPPDATA%\JetBrains\*\log → 逐段展开存在的子目录
  param([string]$Raw)
  $expanded = Expand-EnvPath $Raw
  if (-not $expanded) { return @() }
  if ($expanded -notmatch '[\*\?]') { return @($expanded) }

  $trimmed = $expanded.TrimEnd('\')
  $parts = $trimmed -split '[\\/]' | Where-Object { $_ -ne '' }
  # 找不含通配符的最长字面前缀作为起点
  $base = ''; $restIdx = $parts.Count
  for ($i = 0; $i -lt $parts.Count; $i++) {
    if ($parts[$i] -match '[\*\?]') { $restIdx = $i; break }
    if ($base -eq '') {
      $base = if ($parts[$i] -match '^[A-Za-z]:$') { $parts[$i] + '\' } else { $parts[$i] }
    } else {
      $base = Join-Path $base $parts[$i]
    }
  }
  if ($restIdx -ge $parts.Count) { return @($base) }
  if (-not (Test-Path -LiteralPath $base)) { return @() }
  $rest = $parts[$restIdx..($parts.Count - 1)]

  function Expand-GlobRec {
    param([string]$B, [string[]]$S, [int]$i)
    $out = @()
    if ($i -ge $S.Count) { return @($B) }
    $seg = $S[$i]
    if ($seg -match '[\*\?]') {
      foreach ($c in (Get-ChildItem -LiteralPath $B -Force -ErrorAction SilentlyContinue)) {
        if ($c.Name -like $seg) { $out += Expand-GlobRec (Join-Path $B $c.Name) $S ($i + 1) }
      }
    } else {
      $nxt = Join-Path $B $seg
      if (Test-Path -LiteralPath $nxt) { $out += Expand-GlobRec $nxt $S ($i + 1) }
    }
    return $out
  }
  $result = @(Expand-GlobRec $base $rest 0 | Where-Object { $_ })
  return , $result   # 逗号包裹防止单元素被解包成标量，保证 .Count/foreach 始终可用
}
#endregion

#region 白名单闸门（安全底线：受保护路径绝对不删）
# 两层语义：
#   ProtectedRoots  = 受保护根。目标是根自身或其祖先 → 禁止（防删盘根/用户主目录/WINDIR
#                     根/ProgramData/ProgramFiles 根/工具自身目录及其祖先链）。
#                     注意：根的"内部"不在此层拦截，否则用户 Temp 等核心清理项全被误拦。
#   ForbiddenSubtrees = 禁止子树。目标位于其内部 → 一律禁止（System32/WinSxS/assembly/
#                     SysWOW64/卷信息/回收站/启动菜单/恢复分区/引导与页面文件等）。
$script:ProtectedRoots = @(
  'C:\', 'D:\', 'E:\', 'F:\', 'G:\', 'H:\', 'I:\', 'J:\', 'K:\', 'L:\',
  "$env:WINDIR", "$env:USERPROFILE",
  "$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:ProgramData"
)
$script:ForbiddenSubtrees = @(
  "$env:WINDIR\System32", "$env:WINDIR\WinSxS",
  "$env:WINDIR\assembly", "$env:WINDIR\SysWOW64",
  "$env:SystemDrive\ProgramData\Microsoft\Windows\Start Menu",
  "$env:SystemDrive\ProgramData\Microsoft\Windows\Recovery",
  "$env:SystemDrive\System Volume Information",
  "$env:SystemDrive\Recovery",
  "$env:SystemDrive\bootmgr",
  "$env:SystemDrive\pagefile.sys",
  "$env:SystemDrive\hiberfil.sys",
  "$env:SystemDrive\swapfile.sys",
  "$env:SystemDrive\`$Recycle.Bin"
)
$script:DynamicWhitelist = @($script:ToolRoot)   # 工具自身目录，防"删到自己"

function Test-Whitelist {
  param([string]$FullPath)
  if (-not $FullPath) { return $false }
  try { $fp = [IO.Path]::GetFullPath($FullPath).TrimEnd('\') + '\' } catch { return $false }
  # UNC（网络共享）一律禁止：不在本机受控范围内
  if ($fp.StartsWith('\\')) { return $false }
  # 任意盘符的盘根一律禁止（C:\..L:\ 已列于 ProtectedRoots，此处兜底覆盖其余盘符/热插拔盘）
  if ($fp -match '^[A-Za-z]:\\$') { return $false }
  # 显式放行工具自建的可丢弃测试数据（testdata，仅自测用、无真实数据），
  # 须在受保护根/禁止子树判断之前短路，否则会被盘根(G:\)等规则拦死
  $testArea = Join-Path $script:ToolRoot 'testdata'
  try { $ta = [IO.Path]::GetFullPath($testArea).TrimEnd('\') + '\' } catch { $ta = '' }
  if ($ta -and $fp.StartsWith($ta, 'OrdinalIgnoreCase')) { return $true }
  # 规则1：目标是受保护根自身或其祖先（含工具目录祖先链）→ 禁止
  foreach ($w in ($script:ProtectedRoots + $script:DynamicWhitelist)) {
    try { $we = [IO.Path]::GetFullPath((Expand-EnvPath $w)).TrimEnd('\') + '\' } catch { continue }
    if ($we.StartsWith($fp, 'OrdinalIgnoreCase')) { return $false }
  }
  # 规则2：目标位于禁止子树内（System32/WinSxS/卷信息/回收站等）→ 一律禁止
  foreach ($w in $script:ForbiddenSubtrees) {
    try { $we = [IO.Path]::GetFullPath((Expand-EnvPath $w)).TrimEnd('\') + '\' } catch { continue }
    if ($fp.StartsWith($we, 'OrdinalIgnoreCase')) { return $false }
  }
  return $true
}
#endregion

#region 配置加载（内嵌兜底 + 外部 JSON 合并 + detect 筛选）
# 内嵌最小兜底清单：外部 config\cleanup-items.json 缺失/损坏时使用
$script:EmbeddedItemsJson = @'
[
  { "id":"sys_tmp_user","category":"system","name":"用户临时文件","desc":"临时文件，可安全删除","paths":["%LOCALAPPDATA%\\Temp"],"risk":"green","defaultChecked":true,"method":"delete-dir" },
  { "id":"sys_tmp_win","category":"system","name":"Windows 临时文件","desc":"系统临时文件","paths":["%WINDIR%\\Temp"],"risk":"green","defaultChecked":true,"method":"delete-dir" },
  { "id":"sys_crashdump","category":"system","name":"崩溃转储","desc":"应用崩溃转储","paths":["%LOCALAPPDATA%\\CrashDumps"],"risk":"green","defaultChecked":true,"method":"delete-dir" }
]
'@

function Test-Detect {
  param($Detect)
  if (-not $Detect -or -not $Detect.type) { return $true }
  switch ($Detect.type) {
    'path-exists' {
      foreach ($v in $Detect.value) {
        if (Test-Path -LiteralPath (Expand-EnvPath $v)) { return $true }
      }
      return $false
    }
    'command-exists' {
      foreach ($v in $Detect.value) {
        if (Get-Command $v -ErrorAction SilentlyContinue) { return $true }
      }
      return $false
    }
  }
  return $true
}

function Load-CleanupItems {
  $configPath = Join-Path $script:ToolRoot 'config\cleanup-items.json'
  $items = $null
  if (Test-Path $configPath) {
    try {
      $items = Get-Content -Raw -Encoding UTF8 $configPath | ConvertFrom-Json
    } catch {
      Write-CleanLog "配置文件解析失败，回退内嵌默认: $($_.Exception.Message)"
    }
  }
  if (-not $items) {
    try { $items = $script:EmbeddedItemsJson | ConvertFrom-Json } catch { return @() }
  }
  $valid = @()
  foreach ($it in $items) {
    if (-not $it.id) { continue }
    if (-not $it.category) { $it.category = 'app' }
    if (-not $it.name)  { $it.name = $it.id }
    if (-not $it.desc)  { $it.desc = '' }
    if (-not $it.risk)  { $it.risk = 'yellow' }
    if ($null -eq $it.defaultChecked) { $it.defaultChecked = ($it.risk -eq 'green') }
    if (-not $it.method) { $it.method = 'delete-dir' }
    if (-not $it.paths) { $it.paths = @() }
    # detect 为可选字段，用 PSObject.Properties 访问避免 StrictMode 抛异常
    $detProp = $it.PSObject.Properties['detect']
    $detect = if ($detProp) { $detProp.Value } else { $null }
    if (-not (Test-Detect $detect)) { continue }   # 机器上不存在 → 隐藏
    $valid += $it
  }
  return $valid
}
#endregion

#region 后台任务桥接（PS7 runspace 修复）
# PS7 下 BackgroundWorker.DoWork 委托的 prologue 在 GetContextFromTLS() 处失败——
# ThreadPool 线程没有 runspace，脚本连第一行都执行不到（实测注入 DefaultRunspace 也无效，
# 因为注入行本身也是 PowerShell 语句）。方案：用 C# 桥接委托，在 DoWork 线程上先设好
# DefaultRunspace，再把脚本交给各自预置的 worker runspace 执行（进度/取消/结果照常封送）。
Add-Type -AssemblyName System.Management.Automation
if (-not ('WorkerBridge' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.ComponentModel;
public static class WorkerBridge {
  public static DoWorkEventHandler MakeDoWork(Runspace rs, string script) {
    return delegate(object sender, DoWorkEventArgs e) {
      Runspace.DefaultRunspace = rs;
      using (var ps = PowerShell.Create()) {
        ps.Runspace = rs;
        ps.AddScript(script).AddArgument(sender).AddArgument(e);
        ps.Invoke();
      }
    };
  }
}
'@
}

$script:WorkerRs = @{}          # name -> runspace（每个 worker 独立，避免并发争用）
$script:WorkerSourceCache = $null

function script:Get-WorkerSource {
  # 读取自身文件，取 #region 入口 之前的函数/数据段，作为 worker runspace 的初始化源
  if ($script:WorkerSourceCache) { return $script:WorkerSourceCache }
  try {
    $src = Get-Content -Raw -Encoding UTF8 (Join-Path $script:ToolRoot 'DiskCleaner.ps1')
    # 用"行首锚定"的正则定位入口区标记——不能 IndexOf 字面量（本函数里的 '#region 入口'
    # 字符串字面量会与标记碰撞，导致把源截断在本函数中途）
    $m = [regex]::Match($src, '(?m)^#region 入口\s*$')
    if (-not $m.Success) { throw '入口标记未找到' }
    $seg = $src.Substring(0, $m.Index)
    # 剔除 pre-entry 的路径赋值与 param 块（worker 不需要 $SelfTest，且动态注入时它们会失效）
    $seg = $seg -replace '(?m)^\$script:(ToolRoot|DataDir|LogDir)\s*=.*$', ''
    $seg = $seg -replace '(?m)^param\s*\(.*$', ''
    $script:WorkerSourceCache = $seg
    return $seg
  } catch {
    Write-CleanLog ("无法生成 worker 初始化源: $($_.Exception.Message)")
    return $null
  }
}

function script:Get-WorkerRunspace {
  param([string]$Name)
  if ($script:WorkerRs.ContainsKey($Name)) { return $script:WorkerRs[$Name] }
  $src = Get-WorkerSource
  if (-not $src) { throw "worker[$Name] 初始化源不可用" }
  $rs = [runspacefactory]::CreateRunspace()
  $rs.Open()
  $ps = [powershell]::Create(); $ps.Runspace = $rs
  try {
    $tool = $script:ToolRoot.Replace("'", "''")
    $data = $script:DataDir.Replace("'", "''")
    $log  = $script:LogDir.Replace("'", "''")
    $init = "`$script:ToolRoot='$tool'`n`$script:DataDir='$data'`n`$script:LogDir='$log'`n" + $src
    $null = $ps.AddScript($init).Invoke()
    # 绑定共享 SizeCache 引用（必须在源之后：源内 line 222 会自建独立 @{}，先跑源再覆盖引用）
    $null = $ps.AddScript('$script:SizeCache = $args[0]').AddArgument($script:SizeCache).Invoke()
    $errs = @($ps.Streams.Error)
    if ($errs.Count -gt 0) {
      Write-CleanLog ("worker[$Name] 初始化错误 {0} 条（示例: {1}）" -f $errs.Count, $errs[0].ToString())
    }
  } catch {
    $rs.Close(); $rs.Dispose()
    throw "worker[$Name] 初始化失败: $($_.Exception.Message)"
  } finally {
    $ps.Dispose()
  }
  $script:WorkerRs[$Name] = $rs
  return $rs
}

function script:Register-WorkerBody {
  param($Worker, [string]$Name, [scriptblock]$ScriptBlock)
  $rs = Get-WorkerRunspace -Name $Name
  $Worker.add_DoWork([WorkerBridge]::MakeDoWork($rs, $ScriptBlock.ToString()))
}
#endregion

#region 扫描引擎（高性能目录大小 + size-cache）
$script:SizeCache = @{}   # id -> bytes

function Measure-DirBytes {
  # 迭代（栈）遍历：消除 PowerShell 深递归的函数调用开销，且深路径不会栈溢出；
  # 跳过重解析点（Junction）防死循环；逐目录 try/catch 降级
  param([string]$Root)
  $total = 0L
  if (-not (Test-Path -LiteralPath $Root)) { return 0L }
  # 根自身是重解析点 → 其"内容"不属于它，直接按 0 处理（防透过 Junction 统计目标）
  try { if ([IO.DirectoryInfo]::new($Root).Attributes -band [IO.FileAttributes]::ReparsePoint) { return 0L } } catch { }
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($Root)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    try {
      foreach ($f in [IO.Directory]::EnumerateFiles($dir)) {
        try { $total += ([IO.FileInfo]::new($f)).Length } catch { }
      }
      foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) {
        try {
          if (([IO.DirectoryInfo]::new($d)).Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
          $stack.Push($d)
        } catch { }
      }
    } catch { }   # 无权限/占用 → 跳过该目录继续
  }
  return $total
}

function Save-SizeCache {
  try {
    $obj = [ordered]@{}
    foreach ($k in $script:SizeCache.Keys) {
      $v = $script:SizeCache[$k]
      if ($v -is [hashtable]) { $obj[$k] = @{ b = [long]$v.b; t = [long]$v.t } }
      else { $obj[$k] = @{ b = [long]$v; t = -1L } }   # 旧格式兜底
    }
    $json = $obj | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText((Join-Path $script:DataDir 'size-cache.json'), $json, [Text.UTF8Encoding]::new($false))
  } catch { }
}

function Load-SizeCache {
  $script:SizeCache = @{}
  try {
    $p = Join-Path $script:DataDir 'size-cache.json'
    if (Test-Path $p) {
      $o = Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json
      foreach ($prop in $o.PSObject.Properties) {
        $v = $prop.Value
        if ($v -is [pscustomobject]) {
          # 新格式 {b:字节, t:时间戳}；字段用 PSObject.Properties 访问避免 StrictMode 抛异常
          $b = 0L; $t = -1L
          $bp = $v.PSObject.Properties['b']; if ($bp) { $b = [long]$bp.Value }
          $tp = $v.PSObject.Properties['t']; if ($tp) { $t = [long]$tp.Value }
          $script:SizeCache[$prop.Name] = @{ b = $b; t = $t }
        } else {
          # 旧格式平铺数字 → t=-1 保证首次扫描强制重测并升级为新格式
          $script:SizeCache[$prop.Name] = @{ b = [long]$v; t = -1L }
        }
      }
    }
  } catch { }
}
# 启动即加载磁盘缓存（此前 Load-SizeCache 只定义未调用，跨会话缓存从未生效——v1.2.0 修复）
Load-SizeCache

function Get-ItemStamp {
  # 清理项所有展开根路径的时间戳指纹：任一目录 LastWriteTimeUtc 变化 → 缓存失效重测
  param($Item)
  $stamp = 0L
  foreach ($raw in $Item.paths) {
    foreach ($p in (Get-ExpandedPaths $raw)) {
      try {
        $fsItem = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        if ($fsItem) {
          $t = $fsItem.LastWriteTimeUtc.Ticks
          if ($t -gt $stamp) { $stamp = $t }
        }
      } catch { }
    }
  }
  return $stamp
}

function Get-ItemSize {
  param($Item, [switch]$Force)
  if ($Item.method -eq 'exec') { return 0L }
  $stamp = Get-ItemStamp $Item
  if (-not $Force -and $script:SizeCache.ContainsKey($Item.id)) {
    $ent = $script:SizeCache[$Item.id]
    # 只有新格式 hashtable 且时间戳指纹一致才命中；旧格式/标量/时间戳变化 → 重测
    if ($ent -is [hashtable] -and $ent.t -eq $stamp) { return [long]$ent.b }
  }
  $total = 0L
  foreach ($raw in $Item.paths) {
    foreach ($p in (Get-ExpandedPaths $raw)) {
      if (-not (Test-Path -LiteralPath $p)) { continue }
      try {
        if ($Item.method -eq 'delete-file') {
          if (Test-Path -LiteralPath $p -PathType Leaf) { $total += ([IO.FileInfo]::new($p)).Length }
        } else {
          # 注意：不能用 $item（与参数 $Item 大小写碰撞，会把参数覆盖成 FileInfo）
          $fsItem = Get-Item -LiteralPath $p -Force
          if ($fsItem -and ($fsItem.Attributes -band [IO.FileAttributes]::Directory)) { $total += Measure-DirBytes $p }
        }
      } catch { }
    }
  }
  $script:SizeCache[$Item.id] = @{ b = $total; t = $stamp }
  return $total
}
#endregion

#region 删除引擎（安全优先：默认回收站，占用自动跳过，保留根目录）
function Remove-DirContents {
  # 保留根目录、删除全部子项；返回实际释放字节
  param([string]$Dir, [string]$Mode)
  # 根自身是重解析点 → 只删链接本身，绝不枚举进链接目标（防止清空真实目标内容）
  try {
    if ([IO.DirectoryInfo]::new($Dir).Attributes -band [IO.FileAttributes]::ReparsePoint) {
      try {
        if ($Mode -eq 'Recycle') {
          [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Dir, 'OnlyErrorDialogs', 'SendToRecycleBin', 'ThrowException')
        } else {
          [IO.Directory]::Delete($Dir, $false)
        }
      } catch { }
      return 0L
    }
  } catch { }
  $released = 0L
  foreach ($f in [IO.Directory]::EnumerateFiles($Dir)) {
    try {
      $sz = ([IO.FileInfo]::new($f)).Length
      if ($Mode -eq 'Recycle') {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f, 'OnlyErrorDialogs', 'SendToRecycleBin')
      } else {
        [IO.File]::Delete($f)
      }
      $released += $sz
    } catch { }   # 占用/权限失败 → 自动跳过
  }
  foreach ($d in [IO.Directory]::EnumerateDirectories($Dir)) {
    # 重解析点子目录（Junction/符号链接）：只删链接本身，不测大小、不递归、不枚举目标
    $isReparse = $false
    try { $isReparse = ([IO.DirectoryInfo]::new($d).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } catch { }
    if ($isReparse) {
      try {
        if ($Mode -eq 'Recycle') {
          [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($d, 'OnlyErrorDialogs', 'SendToRecycleBin', 'ThrowException')
        } else {
          [IO.Directory]::Delete($d, $false)
        }
      } catch { }
      continue
    }
    $sz = Measure-DirBytes $d
    try {
      if ($Mode -eq 'Recycle') {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($d, 'OnlyErrorDialogs', 'SendToRecycleBin', 'ThrowException')
        $released += $sz
      } else {
        try {
          [IO.Directory]::Delete($d, $true)
          $released += $sz
        } catch {
          $released += Remove-DirContents $d 'Permanent'   # 子目录被占用 → 递归逐项
        }
      }
    } catch {
      if ($Mode -eq 'Recycle') { $released += Remove-DirContents $d 'Recycle' }  # 递归降级
    }
  }
  if ($Mode -eq 'Permanent') {
    # 永久模式：清空后尝试连根删除；被占用/被监视则静默保留（不报错不崩溃）
    try { [IO.Directory]::Delete($Dir, $true) } catch { }
  }
  return $released
}

function Remove-PatternFile {
  param([string]$Path, [string]$Mode)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0L }
  try {
    $sz = ([IO.FileInfo]::new($Path)).Length
    if ($Mode -eq 'Recycle') {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    } else {
      [IO.File]::Delete($Path)
    }
    return $sz
  } catch { return 0L }
}

function Invoke-ExecItem {
  param($Item)
  $cmd = $Item.execCommand
  $timeout = if ($Item.execTimeoutSec) { $Item.execTimeoutSec } else { 120 }
  Write-CleanLog "执行命令项: $($Item.name)"
  $job = Start-Job -ScriptBlock { param($c) try { Invoke-Expression $c | Out-Null; 'OK' } catch { "ERR: $_" } } -ArgumentList $cmd
  $done = Wait-Job $job -Timeout $timeout
  $res = if ($done) { (Receive-Job $job -Keep) -join ' | ' } else { 'TIMEOUT(已中止)' }
  if (-not $done) { Stop-Job $job }
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  Write-CleanLog "命令项结果: $res"
  return 0L
}

function Invoke-SafeDelete {
  # 统一删除入口：白名单闸门 + 回收站/永久模式 + 逐项日志
  param($Item, [string]$Mode)
  $released = 0L
  $skipped = 0
  if ($Item.method -eq 'exec') {
    $released = Invoke-ExecItem $Item
    return [pscustomobject]@{ Name = $Item.name; Released = $released; Skipped = 0 }
  }
  foreach ($raw in $Item.paths) {
    foreach ($p in (Get-ExpandedPaths $raw)) {
      if (-not (Test-Path -LiteralPath $p)) { continue }
      $full = [IO.Path]::GetFullPath($p)
      if (-not (Test-Whitelist $full)) {
        Write-CleanLog "跳过(受保护路径): $full"
        $skipped++
        continue
      }
      try {
        if ($Item.method -eq 'delete-file') {
          $released += Remove-PatternFile $full $Mode
        } else {
          $released += Remove-DirContents $full $Mode
        }
        Write-CleanLog "已清理: $($Item.name) :: $full"
      } catch {
        Write-CleanLog "清理失败: $($Item.name) :: $full :: $($_.Exception.Message)"
      }
    }
  }
  return [pscustomobject]@{ Name = $Item.name; Released = $released; Skipped = $skipped }
}

function Export-CleanReport {
  # 清理完成后自动导出 CSV 报告到 runtime\reports（写入仅限工具目录内，UTF-8 BOM 便于 Excel 打开）
  param(
    [object[]]$Details,
    [long]$Planned = 0,
    [long]$Released = 0,
    [int]$Skipped = 0,
    [string]$Mode = 'Recycle',
    [string]$Note = ''
  )
  try {
    $dir = Join-Path $script:DataDir 'reports'
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $file = Join-Path $dir ('clean-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('时间,模式,项目,分类,风险,计划大小(字节),实际释放(字节),跳过数')
    foreach ($d in $Details) {
      $name = '"' + ([string]$d.Name -replace '"', '""') + '"'
      $lines.Add(('{0},{1},{2},{3},{4},{5},{6},{7}' -f $ts, $Mode, $name,
        [string]$d.Category, [string]$d.Risk, [long]$d.Size, [long]$d.Released, [int]$d.Skipped))
    }
    $lines.Add(('{0},{1},"合计",,,{2},{3},{4}' -f $ts, $Mode, $Planned, $Released, $Skipped))
    if ($Note) { $lines.Add(('{0},{1},"备注: {2}",,,0,0,0' -f $ts, $Mode, ($Note -replace '"', '""'))) }
    [IO.File]::WriteAllLines($file, $lines, (New-Object System.Text.UTF8Encoding $true))
    return $file
  } catch {
    Write-CleanLog ('清理报告导出失败: ' + $_.Exception.Message)
    return $null
  }
}
#endregion

#region UI 工具（字节格式化 / 风险色 / 占位页）
function Format-Bytes {
  param([long]$Bytes)
  if ($Bytes -le 0) { return '0 B' }
  $units = 'B', 'KB', 'MB', 'GB', 'TB'
  $i = 0; $v = [double]$Bytes
  while ($v -ge 1024 -and $i -lt 4) { $v /= 1024; $i++ }
  return ('{0:N1} {1}' -f $v, $units[$i])
}

function Get-RiskColor {
  param([string]$Risk)
  switch ($Risk) {
    'green'  { return $script:Theme.Green }
    'yellow' { return $script:Theme.Yellow }
    'red'    { return $script:Theme.Red }
    default  { return $script:Theme.Text }
  }
}

function Get-RiskText {
  param([string]$Risk)
  switch ($Risk) {
    'green'  { return '绝对安全' }
    'yellow' { return '谨慎' }
    'red'    { return '需确认' }
    default  { return '未知' }
  }
}

function Get-RiskBackColor {
  # 柔和风险底色（浅 tint），配 Get-RiskColor 的深色前景，替代刺眼的整行纯色
  param([string]$Risk)
  switch ($Risk) {
    'green'  { return '#E8F5E9' }
    'yellow' { return '#FFF8E1' }
    'red'    { return '#FFEBEE' }
    default  { return '#FFFFFF' }
  }
}

function New-WpfBrush {
  param([string]$Hex)
  if (-not $Hex) { return $null }
  return ([System.Windows.Media.BrushConverter]::new()).ConvertFromString($Hex)
}
function New-WpfThickness {
  param([double]$L, [double]$T, [double]$R, [double]$B)
  return New-Object System.Windows.Thickness($L, $T, $R, $B)
}
function New-WpfPlaceholder {
  param([string]$Title, [string]$Msg = '此页正在 WPF 重构中…')
  $g = New-Object System.Windows.Controls.Grid
  $g.Margin = (New-WpfThickness 24 18 24 18)
  $sp = New-Object System.Windows.Controls.StackPanel
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $Title
  $t.FontSize = 18
  $t.FontWeight = [System.Windows.FontWeights]::Bold
  $t.Foreground = (New-WpfBrush $script:Theme.Text)
  $m = New-Object System.Windows.Controls.TextBlock
  $m.Text = $Msg
  $m.Margin = (New-WpfThickness 0 8 0 0)
  $m.FontSize = 13
  $m.Foreground = (New-WpfBrush $script:Theme.SubText)
  $null = $sp.Children.Add($t)
  $null = $sp.Children.Add($m)
  $null = $g.Children.Add($sp)
  return $g
}

function New-CleanPage {
  return (New-WpfPlaceholder -Title '缓存清理' -Msg '缓存清理主页面（WPF 重构中，下一提交启用）')
}
#endregion

#region 设置持久化（删除模式等，写入 runtime\settings.json）
$script:Settings = @{ DeleteMode = 'Recycle' }
function Load-Settings {
  try {
    $p = Join-Path $script:DataDir 'settings.json'
    if (Test-Path $p) {
      $o = Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json
      if ($o.DeleteMode -eq 'Permanent') { $script:Settings.DeleteMode = 'Permanent' }
    }
  } catch { }
}
function Save-Settings {
  try {
    if (-not (Test-Path $script:DataDir)) {
      New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $script:DataDir 'settings.json'), ($script:Settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  } catch { }
}
#endregion

#region 附加功能页（大文件 / 软件占用 / 重复文件 / 还原点 / 启动项）
function Get-FixedDrives {
  # 固定磁盘（DriveType=3）的盘符列表，如 C: D: E:；逗号包裹保证返回数组
  $drives = @()
  try { $drives = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object { $_.DeviceID }) } catch { $drives = @('C:') }
  return , $drives
}

function Open-InExplorer {
  param([string]$Path, [switch]$Select)
  try {
    if ($Select) { Start-Process explorer.exe -ArgumentList "/select,`"$Path`"" } else { Start-Process explorer.exe -ArgumentList $Path }
  } catch { }
}

function Remove-UserPathToRecycle {
  # 附加页专用：单路径安全删除 → 仅回收站 + 白名单闸门；返回实际释放字节
  param([string]$Path)
  try { $full = [IO.Path]::GetFullPath($Path) } catch { return 0L }
  if (-not (Test-Whitelist $full)) {
    Write-CleanLog "跳过(受保护路径): $full"
    return 0L
  }
  try {
    if (Test-Path -LiteralPath $full -PathType Leaf) {
      $sz = ([IO.FileInfo]::new($full)).Length
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($full, 'OnlyErrorDialogs', 'SendToRecycleBin')
      return $sz
    }
    if (Test-Path -LiteralPath $full -PathType Container) {
      $sz = Measure-DirBytes $full
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($full, 'OnlyErrorDialogs', 'SendToRecycleBin', 'ThrowException')
      return $sz
    }
  } catch { }
  return 0L
}

function Get-FileHashSha256 {
  param([string]$Path)
  try {
    $fs = [IO.File]::OpenRead($Path)
    try {
      $sha = [Security.Cryptography.SHA256]::Create()
      try { return [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '') } finally { $sha.Dispose() }
    } finally { $fs.Dispose() }
  } catch { return $null }
}

function Get-FileHashSha256Partial {
  # 首 64KB 部分哈希：重复检测预筛用（大文件先比头部，避免对每个候选全量读盘）
  param([string]$Path)
  try {
    $fs = [IO.File]::OpenRead($Path)
    try {
      $len = [Math]::Min(65536L, $fs.Length)
      $buf = New-Object byte[] $len
      $null = $fs.Read($buf, 0, $len)
      $sha = [Security.Cryptography.SHA256]::Create()
      try { return [BitConverter]::ToString($sha.ComputeHash($buf)).Replace('-', '') } finally { $sha.Dispose() }
    } finally { $fs.Dispose() }
  } catch { return $null }
}

# ---------- Tab: 空间分析（WizTree 式目录占用浏览器） ----------
function Get-DirSizes {
  # 全盘迭代扫描：每个目录的直接文件字节合计（不含子目录内容）；跳过重解析点
  param([string]$Root, [System.ComponentModel.BackgroundWorker]$W)
  $own = New-Object 'System.Collections.Generic.Dictionary[string,long]'
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($Root)
  $dirs = 0
  while ($stack.Count -gt 0) {
    if ($W -and $W.CancellationPending) { return $null }
    $dir = $stack.Pop()
    $bytes = 0L
    try {
      $di = [IO.DirectoryInfo]::new($dir)
      if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
      foreach ($f in [IO.Directory]::EnumerateFiles($dir)) {
        try { $bytes += ([IO.FileInfo]::new($f)).Length } catch { }
      }
      foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) {
        try {
          if (([IO.DirectoryInfo]::new($d)).Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
          $stack.Push($d)
        } catch { }
      }
    } catch { }
    $own[$dir] = $bytes
    $dirs++
    if (($dirs % 500) -eq 0 -and $W) { $W.ReportProgress(0, ("已扫描 {0} 个目录..." -f $dirs)) }
  }
  return $own
}

function Get-MergedDirTotals {
  # 自底向上聚合：total[dir] = dir 及全部子孙的直接文件字节合计
  # 第一遍按长度倒序预建全部条目（total=own）；第二遍按同一顺序把每个目录的 total
  # 累加进其父（长度倒序保证子目录先于父目录被累加）
  param([System.Collections.Generic.Dictionary[string,long]]$Own)
  $total = New-Object 'System.Collections.Generic.Dictionary[string,long]'
  $keys = [string[]]$Own.Keys
  $cmp = [System.Comparison[string]] { param($a, $b) $b.Length.CompareTo($a.Length) }
  [System.Array]::Sort($keys, $cmp)
  foreach ($k in $keys) { $total[$k] = $Own[$k] }
  foreach ($k in $keys) {
    $pi = $k.LastIndexOf('\')
    if ($pi -gt 2) {   # 排除 "C:\" 盘根自身（无父目录可累加）
      $parent = $k.Substring(0, $pi)
      if ($total.ContainsKey($parent)) { $total[$parent] += $total[$k] }
    }
  }
  return $total
}

function New-SpacePage { return (New-WpfPlaceholder -Title '空间分析' -Msg '扫描目录占用并支持下钻（WPF 重构中）') }

# ---------- Tab: 大文件分析 ----------
function Get-LargeFiles {
  # 迭代(栈)遍历目标盘，收集 >= 阈值的文件；跳过重解析点与系统巨型目录
  param([string]$Root, [long]$Threshold, [System.ComponentModel.BackgroundWorker]$W)
  $result = New-Object System.Collections.Generic.List[object]
  $skipNames = @('WinSxS', 'System Volume Information', '$Recycle.Bin', 'Recovery', 'Config.Msi', 'Windows.old')
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($Root)
  $found = 0
  while ($stack.Count -gt 0) {
    if ($W -and $W.CancellationPending) { return $result }
    $dir = $stack.Pop()
    try {
      $di = [IO.DirectoryInfo]::new($dir)
      if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
      if ($skipNames -contains $di.Name) { continue }
      foreach ($f in [IO.Directory]::EnumerateFiles($dir)) {
        try {
          $fi = [IO.FileInfo]::new($f)
          if ($fi.Length -ge $Threshold) {
            $result.Add([pscustomobject]@{ Name = $fi.Name; Size = $fi.Length; Modified = $fi.LastWriteTime; Path = $fi.FullName })
            $found++
            if ($W -and (($found % 20) -eq 0)) { $W.ReportProgress(0, ("已发现 {0} 个大文件..." -f $found)) }
          }
        } catch { }
      }
      foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) { $stack.Push($d) }
    } catch { }
  }
  return $result
}

function New-LargeFilesPage { return (New-WpfPlaceholder -Title '大文件' -Msg '列出大文件并按体积排序（WPF 重构中）') }

# ---------- Tab: 空文件夹清理 ----------
function Get-EmptyDirs {
  # 找出可安全删除的空目录（级联判定）：
  #   空目录 = 自身 0 个直接文件，且全部子目录也均为空；
  # 子目录含重解析点(junction/符号链接)或访问失败 → 一律视为非空（阻断父目录删除，避免误伤目标内容）
  # 只输出"空子树顶端"（其父目录非空）——删除时整棵空子树一并进回收站
  param([string]$Root, [System.ComponentModel.BackgroundWorker]$W)
  $files = New-Object 'System.Collections.Generic.Dictionary[string,int]'
  $children = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]'
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($Root)
  $dirs = 0
  while ($stack.Count -gt 0) {
    if ($W -and $W.CancellationPending) { return $null }
    $dir = $stack.Pop()
    $fc = 0
    $kids = New-Object 'System.Collections.Generic.List[string]'
    try {
      $di = [IO.DirectoryInfo]::new($dir)
      if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }   # 重解析目录不入字典（其父会被它阻断）
      foreach ($f in [IO.Directory]::EnumerateFiles($dir)) { $fc++ }
      foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) {
        try {
          if (([IO.DirectoryInfo]::new($d)).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $kids.Add($d)   # 重解析子目录不展开但保留在子列表 → 阻断父目录
            continue
          }
          $kids.Add($d)
          $stack.Push($d)
        } catch { $kids.Add($d) }   # 访问失败：不可判定 → 阻断父目录
      }
    } catch { continue }            # 无法访问的目录不参与判定（其父已被它阻断）
    $files[$dir] = $fc
    $children[$dir] = $kids
    $dirs++
    if (($dirs % 500) -eq 0 -and $W) { $W.ReportProgress(0, ("已扫描 {0} 个目录..." -f $dirs)) }
  }
  # 自底向上标记：长度倒序保证先判定最深目录
  $empty = New-Object 'System.Collections.Generic.HashSet[string]'
  $keys = [string[]]$files.Keys
  $cmp = [System.Comparison[string]] { param($a, $b) $b.Length.CompareTo($a.Length) }
  [System.Array]::Sort($keys, $cmp)
  foreach ($k in $keys) {
    $isEmpty = ($files[$k] -eq 0)
    if ($isEmpty) {
      foreach ($c in $children[$k]) {
        if (-not $empty.Contains($c)) { $isEmpty = $false; break }
      }
    }
    if ($isEmpty) { $null = $empty.Add($k) }
  }
  # 只留空子树顶端（父目录非空）
  $result = New-Object System.Collections.Generic.List[object]
  foreach ($k in $keys) {
    if (-not $empty.Contains($k)) { continue }
    $pi = $k.LastIndexOf('\')
    if ($pi -gt 2) {
      $parent = $k.Substring(0, $pi)
      if ($empty.Contains($parent)) { continue }
    }
    $result.Add([pscustomobject]@{ Path = $k; Name = [IO.Path]::GetFileName($k) })
  }
  return $result
}

function New-EmptyDirPage { return (New-WpfPlaceholder -Title '空文件夹' -Msg '查找可安全删除的空目录（WPF 重构中）') }

# ---------- Tab: 系统加速 ----------
# ntdll NtSetSystemInformation：SystemMemoryListInformation(80) 释放内存
#   命令 5 = MemoryPurgeStandbyList（清待机内存）  命令 3 = MemoryEmptyWorkingSets（修剪工作集）
#   均需管理员权限；失败返回非零 NTSTATUS，UI 侧只提示不崩溃
if (-not ([System.Management.Automation.PSTypeName]'DiskCleanerPro.NativeMem').Type) {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace DiskCleanerPro {
  [StructLayout(LayoutKind.Sequential)]
  public class MEMORYSTATUSEX {
    public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
    public uint dwMemoryLoad;
    public ulong ullTotalPhys;
    public ulong ullAvailPhys;
    public ulong ullTotalPageFile;
    public ulong ullAvailPageFile;
    public ulong ullTotalVirtual;
    public ulong ullAvailVirtual;
    public ulong ullAvailExtendedVirtual;
  }
  public static class NativeMem {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX b);
    [DllImport("ntdll.dll")]
    public static extern int NtSetSystemInformation(int cls, ref int info, int len);
    // privilege 13 = SeProfileSingleProcessPrivilege（SystemMemoryListInformation 必需），
    // privilege 5 = SeIncreaseQuotaPrivilege（工作集操作兜底）
    [DllImport("ntdll.dll")]
    public static extern int RtlAdjustPrivilege(int privilege, bool enable, bool currentThread, out bool enabled);
  }
}
"@
}

function Get-MemoryInfoText {
  # 返回 @{ Pct = 0-100; UsedBytes; TotalBytes }；调用方负责 try/catch
  $st = New-Object DiskCleanerPro.MEMORYSTATUSEX
  if (-not [DiskCleanerPro.NativeMem]::GlobalMemoryStatusEx($st)) {
    return $null
  }
  return @{
    Pct        = [int]$st.dwMemoryLoad
    UsedBytes  = [long]($st.ullTotalPhys - $st.ullAvailPhys)
    TotalBytes = [long]$st.ullTotalPhys
  }
}

function Invoke-MemoryPurge {
  param([int]$Command)   # 5=清待机列表 3=修剪工作集
  # 先在进程令牌中启用所需特权（管理员身份 ≠ 特权已启用；未启用会返回 0xC0000061）
  $enabled = $false
  $null = [DiskCleanerPro.NativeMem]::RtlAdjustPrivilege(13, $true, $false, [ref]$enabled)
  $i = $Command
  $st = [DiskCleanerPro.NativeMem]::NtSetSystemInformation(80, [ref]$i, 4)
  if ($st -ne 0) {
    $null = [DiskCleanerPro.NativeMem]::RtlAdjustPrivilege(5, $true, $false, [ref]$enabled)
    $i = $Command
    $st = [DiskCleanerPro.NativeMem]::NtSetSystemInformation(80, [ref]$i, 4)
  }
  return $st             # 0 = STATUS_SUCCESS
}

function Test-IsAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

function New-SysAccelPage { return (New-WpfPlaceholder -Title '系统加速' -Msg '内存清理与系统加速（WPF 重构中）') }

# ---------- Tab: 软件占用 ----------
function Get-InstalledSoftware {
  $rows = New-Object System.Collections.Generic.List[object]
  $keys = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  foreach ($k in $keys) {
    if (-not (Test-Path $k)) { continue }
    foreach ($sub in (Get-Item $k)) {
      try {
        $name = $sub.GetValue('DisplayName')
        if (-not $name) { continue }
        $loc = $sub.GetValue('InstallLocation')
        $est = $sub.GetValue('EstimatedSize')   # 单位 KB
        $rows.Add([pscustomobject]@{
          Name      = [string]$name
          Publisher = [string]$sub.GetValue('Publisher')
          Version   = [string]$sub.GetValue('DisplayVersion')
          Location  = [string]$loc
          RegKB     = if ($est) { [long]$est } else { 0L }
          RealBytes = 0L
        })
      } catch { }
    }
  }
  return $rows
}

function New-SoftwarePage { return (New-WpfPlaceholder -Title '软件占用' -Msg '已安装软件与体积（WPF 重构中）') }

# ---------- Tab: 重复文件检测 ----------
function Get-DupeGroups {
  # 大小分桶(跳过<1MB) → SHA-256 → 同哈希=重复组；保留者=路径最短/最早
  param([string]$Root, [System.ComponentModel.BackgroundWorker]$W)
  $bySize = @{}
  $files = 0
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($Root)
  while ($stack.Count -gt 0) {
    if ($W -and $W.CancellationPending) { return $null }
    $dir = $stack.Pop()
    try {
      $di = [IO.DirectoryInfo]::new($dir)
      if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
      foreach ($f in [IO.Directory]::EnumerateFiles($dir)) {
        try {
          $fi = [IO.FileInfo]::new($f)
          if ($fi.Length -lt 1048576) { continue }   # 跳过 <1MB，聚焦大冗余
          $sz = $fi.Length
          if (-not $bySize.ContainsKey($sz)) { $bySize[$sz] = New-Object System.Collections.Generic.List[string] }
          $bySize[$sz].Add($f)
          $files++
          if (($files % 200) -eq 0 -and $W) { $W.ReportProgress(0, ("枚举文件 {0} 个..." -f $files)) }
        } catch { }
      }
      foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) { $stack.Push($d) }
    } catch { }
  }
  # 阶段1：首 64KB 头部哈希预筛（dupeGuru 同款两级策略：同大小 → 比头部 → 只对头部相同者做全量哈希）
  $fullJobs = New-Object System.Collections.Generic.List[object]   # @{ Paths=List[string]; Size=long }
  $i = 0
  foreach ($k in @($bySize.Keys)) {
    $bucket = $bySize[$k]
    if ($bucket.Count -lt 2) { continue }
    $partMap = @{}
    foreach ($f in $bucket) {
      if ($W -and $W.CancellationPending) { return $null }
      $ph = Get-FileHashSha256Partial $f
      if (-not $ph) { continue }
      $key = [string]$k + '|' + $ph
      if (-not $partMap.ContainsKey($key)) { $partMap[$key] = New-Object System.Collections.Generic.List[string] }
      $null = $partMap[$key].Add($f)
      $i++
      if (($i % 100) -eq 0 -and $W) { $W.ReportProgress(0, ("头部比对 {0}..." -f $i)) }
    }
    foreach ($lst in $partMap.Values) {
      if ($lst.Count -ge 2) { $fullJobs.Add([pscustomobject]@{ Paths = $lst; Size = $k }) }
    }
  }
  $bySize = $null
  # 阶段2：仅对头部相同的组做全量 SHA-256
  $byHash = @{}
  $i = 0
  foreach ($job in $fullJobs) {
    foreach ($f in $job.Paths) {
      if ($W -and $W.CancellationPending) { return $null }
      $h = Get-FileHashSha256 $f
      if (-not $h) { continue }
      if (-not $byHash.ContainsKey($h)) { $byHash[$h] = New-Object System.Collections.Generic.List[string] }
      $null = $byHash[$h].Add($f)
      $i++
      if (($i % 50) -eq 0 -and $W) { $W.ReportProgress(0, ("全量哈希 {0}..." -f $i)) }
    }
  }
  $result = New-Object System.Collections.Generic.List[object]
  $g = 0
  foreach ($h in $byHash.Keys) {
    $list = $byHash[$h]
    if ($list.Count -lt 2) { continue }
    $g++
    $size = 0L
    try { $size = ([IO.FileInfo]::new($list[0])).Length } catch { }
    $keep = ($list | Sort-Object @{ Expression = { $_.Length } }, @{ Expression = { $_ } })[0]
    foreach ($f in $list) {
      $result.Add([pscustomobject]@{ Group = $g; Size = $size; Path = $f; Keep = ($f -eq $keep) })
    }
  }
  return $result
}

function New-DupeFilesPage { return (New-WpfPlaceholder -Title '重复文件' -Msg '按哈希查找重复文件（WPF 重构中）') }

# ---------- Tab: 还原点管理 ----------
function Get-RestorePoints {
  $p = @()
  try { $p = @(Get-ComputerRestorePoint -ErrorAction Stop) } catch { $p = @() }
  return , $p   # 逗号包裹，保证调用方始终拿到数组（即使 0/1 个点）
}

function Remove-OldRestorePoints {
  # 删除除最近3个外的所有还原点；失败项跳过。返回删除数
  $pts = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)
  if ($pts.Count -le 3) { return 0 }
  $toDelete = $pts | Sort-Object CreationTime | Select-Object -First ($pts.Count - 3)
  $del = 0
  foreach ($rp in $toDelete) {
    try { Remove-ComputerRestorePoint -RestorePoint $rp.SequenceNumber -ErrorAction Stop; $del++ } catch { }
  }
  return $del
}

function New-RestorePage { return (New-WpfPlaceholder -Title '还原点' -Msg '系统还原点管理（WPF 重构中）') }

# ---------- Tab: 启动项管理 ----------
function Get-StartupItems {
  $rows = New-Object System.Collections.Generic.List[object]
  $runKeys = @(
    @{ Src = 'HKCU\Run';   Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' },
    @{ Src = 'HKLM\Run';   Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' },
    @{ Src = 'HKLM\Run';   Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' },
    @{ Src = 'HKCU\RunOnce'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' }
  )
  foreach ($k in $runKeys) {
    if (-not (Test-Path $k.Path)) { continue }
    try {
      $key = Get-Item $k.Path
      foreach ($n in $key.GetValueNames()) {
        try { $rows.Add([pscustomobject]@{ Source = $k.Src; Name = $n; Command = [string]$key.GetValue($n); Status = '启用' }) } catch { }
      }
    } catch { }
  }
  try {
    $sh = New-Object -ComObject WScript.Shell
    foreach ($fd in @(@{ Src = '启动文件夹(当前用户)'; Key = 'Startup' }, @{ Src = '启动文件夹(所有用户)'; Key = 'AllUsersStartup' })) {
      try {
        $dir = $sh.SpecialFolders.Item($fd.Key)
        if ($dir -and (Test-Path -LiteralPath $dir)) {
          foreach ($f in [IO.Directory]::EnumerateFiles($dir)) {
            $rows.Add([pscustomobject]@{ Source = $fd.Src; Name = [IO.Path]::GetFileName($f); Command = $f; Status = '启用' })
          }
        }
      } catch { }
    }
  } catch { }
  return $rows
}

function Backup-StartupReg {
  # 备份 Run 注册表键为 .reg 到 runtime（仅写入工具目录，不删除任何东西）
  $dir = $script:DataDir
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $files = @()
  foreach ($k in @(
    'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run'
  )) {
    $out = Join-Path $dir ('startup-' + $k.Split('\')[0] + '-' + $stamp + '.reg')
    try { & regedit /e $out $k 2>$null; if (Test-Path $out) { $files += $out } } catch { }
  }
  return $files
}

function New-StartupPage { return (New-WpfPlaceholder -Title '启动项' -Msg '启动项管理（WPF 重构中）') }
#endregion

#region 主窗口（橙色主题完整界面）
$script:WpfShellXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DiskCleanerPro - C 盘智能清理工具"
        Width="1200" Height="800" MinWidth="960" MinHeight="640"
        WindowStartupLocation="CenterScreen"
        Background="#F5F6F8" FontFamily="Microsoft YaHei UI" FontSize="13"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Text" Color="#1F2937"/>
    <SolidColorBrush x:Key="SubText" Color="#6B7280"/>
    <SolidColorBrush x:Key="CardLine" Color="#E5E7EB"/>
    <SolidColorBrush x:Key="CardBg" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="PageBg" Color="#F5F6F8"/>
    <SolidColorBrush x:Key="Primary" Color="#F97316"/>
    <SolidColorBrush x:Key="PrimaryHover" Color="#EA580C"/>
    <SolidColorBrush x:Key="PrimaryPress" Color="#C2410C"/>
    <SolidColorBrush x:Key="NavBg" Color="#EEF1F4"/>
    <SolidColorBrush x:Key="NavHover" Color="#E4E8ED"/>
    <SolidColorBrush x:Key="Green" Color="#16A34A"/>
    <SolidColorBrush x:Key="GreenHover" Color="#15803D"/>
    <SolidColorBrush x:Key="Red" Color="#DC2626"/>
    <SolidColorBrush x:Key="Yellow" Color="#D97706"/>
    <SolidColorBrush x:Key="LightBtn" Color="#EEF1F4"/>
    <SolidColorBrush x:Key="LightBtnHover" Color="#E4E8ED"/>
    <SolidColorBrush x:Key="LightBtnPress" Color="#DAE0E6"/>

    <!-- 浅色按钮 -->
    <Style x:Key="BtnLight" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Background" Value="{StaticResource LightBtn}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="6" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource LightBtnHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource LightBtnPress}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 主按钮（橙） -->
    <Style x:Key="BtnPrimary" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="{StaticResource Primary}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="8" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource PrimaryHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource PrimaryPress}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 绿色按钮 -->
    <Style x:Key="BtnGreen" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="{StaticResource Green}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="6" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource GreenHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#14532D"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 细进度条 -->
    <Style x:Key="BarThin" TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Foreground" Value="{StaticResource Primary}"/>
      <Setter Property="Background" Value="{StaticResource CardLine}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border x:Name="PART_Track" CornerRadius="3" Background="{TemplateBinding Background}">
              <Border x:Name="PART_Indicator" CornerRadius="3" Background="{TemplateBinding Foreground}"
                      HorizontalAlignment="Left"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 左侧导航项：GPU 合成 + 120ms 过渡，杜绝 WinForms 式整条重绘闪烁 -->
    <Style x:Key="NavItemStyle" TargetType="ListBoxItem">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#5B6470"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border CornerRadius="6" Margin="0,1">
              <Grid>
                <Border x:Name="HoverBg" CornerRadius="6" Background="Transparent"/>
                <Border x:Name="SelBg" CornerRadius="6" Background="White" Opacity="0"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="3"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Border x:Name="SelBar" Background="#F97316" CornerRadius="1.5" Margin="0,5,0,5" Opacity="0"/>
                  <ContentPresenter Grid.Column="1" Margin="12,9,8,9" VerticalAlignment="Center"/>
                </Grid>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <ColorAnimation Storyboard.TargetName="HoverBg" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#E4E8ED" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <ColorAnimation Storyboard.TargetName="HoverBg" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="Transparent" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="FontWeight" Value="Bold"/>
                <Setter Property="Foreground" Value="#1F2937"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="SelBg" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.12"/>
                      <DoubleAnimation Storyboard.TargetName="SelBar" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="SelBg" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.12"/>
                      <DoubleAnimation Storyboard.TargetName="SelBar" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="58"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- ============ 顶部栏 ============ -->
    <Border Grid.Row="0" Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardLine}" BorderThickness="0,0,0,1">
      <Grid Margin="16,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <StackPanel>
            <TextBlock Text="DiskCleanerPro" FontSize="15" FontWeight="Bold" Foreground="{StaticResource Text}"/>
            <TextBlock Text="C 盘智能清理工具" FontSize="10" Foreground="{StaticResource SubText}" Margin="0,2,0,0"/>
          </StackPanel>
          <Border x:Name="AdminBadge" CornerRadius="4" Background="#ECFDF5" Margin="12,0,0,0" Padding="8,4" VerticalAlignment="Center">
            <TextBlock x:Name="AdminBadgeText" Text="管理员" FontSize="11" FontWeight="Bold" Foreground="#047857"/>
          </Border>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnScan" Style="{StaticResource BtnLight}" Content="立即重新扫描" Height="32" Padding="16,0" Margin="0,0,8,0"/>
          <Button x:Name="BtnClearCache" Style="{StaticResource BtnLight}" Content="清空扫描缓存" Height="32" Padding="16,0" Margin="0,0,8,0"/>
          <Button x:Name="BtnCancelScan" Style="{StaticResource BtnLight}" Content="取消扫描" Height="32" Padding="14,0" IsEnabled="False"/>
        </StackPanel>
        <StackPanel Grid.Column="3" Width="260" VerticalAlignment="Center" Margin="16,0,0,0">
          <TextBlock x:Name="DiskInfo" Text="磁盘信息加载中..." FontSize="12" Foreground="{StaticResource Text}" TextAlignment="Right"/>
          <ProgressBar x:Name="DiskBar" Style="{StaticResource BarThin}" Height="5" Margin="0,5,0,0" Maximum="100"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ============ 主体：左侧导航 + 页面 ============ -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="200"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border Background="{StaticResource NavBg}" BorderBrush="{StaticResource CardLine}" BorderThickness="0,0,1,0">
        <ListBox x:Name="NavList" Background="Transparent" BorderThickness="0" Foreground="#5B6470"
                 SelectedIndex="0" Margin="8,8,8,8" ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                 ItemContainerStyle="{StaticResource NavItemStyle}" FocusVisualStyle="{x:Null}">
          <ListBoxItem>缓存清理</ListBoxItem>
          <ListBoxItem>空间分析</ListBoxItem>
          <ListBoxItem>空文件夹</ListBoxItem>
          <ListBoxItem>系统加速</ListBoxItem>
          <ListBoxItem>大文件</ListBoxItem>
          <ListBoxItem>软件占用</ListBoxItem>
          <ListBoxItem>重复文件</ListBoxItem>
          <ListBoxItem>还原点</ListBoxItem>
          <ListBoxItem>启动项</ListBoxItem>
        </ListBox>
      </Border>
      <Grid Grid.Column="1" x:Name="PageHost" Background="{StaticResource PageBg}"/>
    </Grid>

    <!-- ============ 底部操作条 ============ -->
    <Border Grid.Row="2" Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardLine}" BorderThickness="0,1,0,0">
      <Grid Margin="16,12,16,12">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="TotalLabel" Text="合计可释放: 0 B" FontSize="15" FontWeight="Bold" Foreground="{StaticResource Primary}" VerticalAlignment="Center"/>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnCancelClean" Style="{StaticResource BtnLight}" Content="取消" Width="70" Height="50" IsEnabled="False" Margin="0,0,8,0"/>
            <Button x:Name="BtnClean" Style="{StaticResource BtnPrimary}" Content="开始清理" Width="150" Height="50" FontSize="15"/>
          </StackPanel>
        </Grid>
        <Grid Grid.Row="1" Margin="0,10,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="BtnAll" Style="{StaticResource BtnLight}" Content="全选" Width="76" Height="30" Margin="0,0,8,0"/>
            <Button x:Name="BtnNone" Style="{StaticResource BtnLight}" Content="全不选" Width="76" Height="30" Margin="0,0,8,0"/>
            <Button x:Name="BtnLow" Style="{StaticResource BtnLight}" Content="仅低风险" Width="92" Height="30" Margin="0,0,8,0"/>
            <Button x:Name="BtnSafe" Style="{StaticResource BtnGreen}" Content="一键清理安全项" Width="130" Height="30"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="删除方式:" Foreground="{StaticResource SubText}" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <RadioButton x:Name="RbRecycle" Content="移到回收站 (可恢复)" IsChecked="True" VerticalAlignment="Center" Margin="0,0,16,0" Foreground="{StaticResource Text}"/>
            <RadioButton x:Name="RbPermanent" Content="永久删除 (不可恢复)" VerticalAlignment="Center" Foreground="{StaticResource Red}"/>
          </StackPanel>
        </Grid>
        <Grid Grid.Row="2" Margin="0,12,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <ProgressBar x:Name="CleanBar" Style="{StaticResource BarThin}" Height="6" VerticalAlignment="Center"/>
          <TextBlock x:Name="CleanStatus" Grid.Column="1" Text="就绪" Foreground="{StaticResource SubText}" FontSize="12" VerticalAlignment="Center" Margin="16,0,0,0"/>
        </Grid>
      </Grid>
    </Border>

    <!-- ============ 日志 ============ -->
    <Border Grid.Row="3" Background="#FBFBFC" BorderBrush="{StaticResource CardLine}" BorderThickness="0,1,0,0" Height="104">
      <TextBox x:Name="LogBox" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
               Background="Transparent" BorderThickness="0" FontFamily="Consolas" FontSize="12" Padding="12,6"/>
    </Border>
  </Grid>
</Window>
'@

function New-MainWindow {
  $win = $null
  try {
    $win = [System.Windows.Markup.XamlReader]::Parse($script:WpfShellXaml)
  } catch {
    Write-CleanLog ('WPF XAML 解析失败: ' + $_.Exception.Message)
    throw
  }
  # 提取命名控件
  function Get-Ctl([string]$name) { $win.FindName($name) }
  $script:BtnScan        = Get-Ctl 'BtnScan'
  $script:BtnCancelScan  = Get-Ctl 'BtnCancelScan'
  $script:DiskInfo       = Get-Ctl 'DiskInfo'
  $script:DiskBar        = Get-Ctl 'DiskBar'
  $script:NavList        = Get-Ctl 'NavList'
  $script:PageHost       = Get-Ctl 'PageHost'
  $script:TotalLabel     = Get-Ctl 'TotalLabel'
  $script:BtnClean       = Get-Ctl 'BtnClean'
  $script:BtnCancelClean = Get-Ctl 'BtnCancelClean'
  $script:CleanBar       = Get-Ctl 'CleanBar'
  $script:CleanStatus    = Get-Ctl 'CleanStatus'
  $script:LogBox         = Get-Ctl 'LogBox'
  $btnClearCache         = Get-Ctl 'BtnClearCache'
  $btnAll                = Get-Ctl 'BtnAll'
  $btnNone               = Get-Ctl 'BtnNone'
  $btnLow                = Get-Ctl 'BtnLow'
  $btnSafe               = Get-Ctl 'BtnSafe'
  $script:RbPermanent    = Get-Ctl 'RbPermanent'
  $rbRecycle             = Get-Ctl 'RbRecycle'
  $adminBadge            = Get-Ctl 'AdminBadge'
  $adminBadgeText        = Get-Ctl 'AdminBadgeText'

  # 管理员徽标
  try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
      $adminBadgeText.Text = '管理员'
      $adminBadgeText.Foreground = (New-WpfBrush '#047857')
      $adminBadge.Background = (New-WpfBrush '#ECFDF5')
    } else {
      $adminBadgeText.Text = '普通模式'
      $adminBadgeText.Foreground = (New-WpfBrush $script:Theme.Yellow)
      $adminBadge.Background = (New-WpfBrush '#FEF3C7')
    }
  } catch { }

  # 程序图标（代码绘制橙色圆角+白色对勾，无图片资源）
  try {
    $iconBmp = New-Object System.Drawing.Bitmap(32, 32)
    $ig = [System.Drawing.Graphics]::FromImage($iconBmp)
    $ig.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $ig.Clear([System.Drawing.Color]::Transparent)
    $ip = New-Object System.Drawing.Drawing2D.GraphicsPath
    $ip.AddArc(2, 2, 12, 12, 180, 90); $ip.AddArc(18, 2, 12, 12, 270, 90)
    $ip.AddArc(18, 18, 12, 12, 0, 90); $ip.AddArc(2, 18, 12, 12, 90, 90)
    $ip.CloseFigure()
    $ib = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary))
    $ig.FillPath($ib, $ip)
    $ipen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 3)
    $ipen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $ipen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $ig.DrawLine($ipen, 9, 17, 14, 22); $ig.DrawLine($ipen, 14, 22, 24, 9)
    $img = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($iconBmp.GetHicon(),
      [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    $win.Icon = $img
    $ipen.Dispose(); $ib.Dispose(); $ip.Dispose(); $ig.Dispose(); $iconBmp.Dispose()
  } catch { }

  # ---- 构造 9 个页面并加入 PageHost（Visibility 切换，保留各页状态） ----
  $script:Pages = @{}
  $script:NavKeys = @('clean', 'space', 'emptyd', 'sys', 'large', 'soft', 'dupe', 'restore', 'startup')
  $builders = @(
    @{ Key = 'clean';   Fn = { New-CleanPage } },
    @{ Key = 'space';   Fn = { New-SpacePage } },
    @{ Key = 'emptyd';  Fn = { New-EmptyDirPage } },
    @{ Key = 'sys';     Fn = { New-SysAccelPage } },
    @{ Key = 'large';   Fn = { New-LargeFilesPage } },
    @{ Key = 'soft';    Fn = { New-SoftwarePage } },
    @{ Key = 'dupe';    Fn = { New-DupeFilesPage } },
    @{ Key = 'restore'; Fn = { New-RestorePage } },
    @{ Key = 'startup'; Fn = { New-StartupPage } }
  )
  foreach ($b in $builders) {
    $pg = & $b.Fn
    $pg.HorizontalAlignment = 'Stretch'
    $pg.VerticalAlignment = 'Stretch'
    $pg.Visibility = 'Collapsed'
    $null = $script:PageHost.Children.Add($pg)
    $script:Pages[$b.Key] = $pg
  }

  # ---- 导航切换 ----
  $script:NavList.Add_SelectionChanged({
    param($s, $e)
    try {
      $idx = $script:NavList.SelectedIndex
      if ($idx -lt 0 -or $idx -ge $script:NavKeys.Count) { return }
      foreach ($k in $script:NavKeys) { $script:Pages[$k].Visibility = 'Collapsed' }
      $script:Pages[$script:NavKeys[$idx]].Visibility = 'Visible'
    } catch { }
  })
  # XAML 已带 SelectedIndex=0，SelectionChanged 不会再次触发 → 显式显示第一页
  foreach ($k in $script:NavKeys) { $script:Pages[$k].Visibility = 'Collapsed' }
  $script:Pages[$script:NavKeys[0]].Visibility = 'Visible'
  $script:NavList.SelectedIndex = 0

  # ---- 日志 ----
  function script:Log-Line {
    param([string]$Msg)
    try {
      $script:LogBox.AppendText((Get-Date -Format 'HH:mm:ss') + '  ' + $Msg + "`r`n")
      $script:LogBox.ScrollToEnd()
    } catch { }
    Write-CleanLog $Msg
  }

  # ---- 磁盘信息 ----
  function script:Refresh-DiskInfo {
    try {
      $d = Get-PSDrive -Name 'C'
      $used = [long]$d.Used; $free = [long]$d.Free; $total = $used + $free
      $pct = if ($total -gt 0) { [int](100 * $used / $total) } else { 0 }
      $script:DiskInfo.Text = ('C盘: 已用 {0} / 可用 {1}   占用 {2}%' -f (Format-Bytes $used), (Format-Bytes $free), $pct)
      $script:DiskBar.Maximum = 100
      $script:DiskBar.Value = [Math]::Min(100, $pct)
    } catch { }
  }

  # ---- 事件（主清理页在下一提交接通完整逻辑） ----
  function script:Start-Scan {
    Log-Line '扫描功能正在 WPF 重构中（后续提交启用）'
  }
  $script:BtnScan.Add_Click({ Start-Scan })
  $btnClearCache.Add_Click({
    Log-Line '清空扫描缓存功能正在 WPF 重构中'
  })
  $script:BtnCancelScan.Add_Click({ })

  # 恢复删除模式
  Load-Settings
  if ($script:Settings.DeleteMode -eq 'Permanent') { $script:RbPermanent.IsChecked = $true }

  # 就绪
  Refresh-DiskInfo
  Log-Line '工具已就绪（WPF 界面重构中，主清理功能后续提交启用）。'

  return $win
}
#endregion

#region 自测模式（仅操作 clear\testdata 内自建假数据，绝不碰真实文件）
function Run-SelfTest {
  $script:Pass = 0; $script:Fail = 0
  function Assert-True {
    param([bool]$Cond, [string]$Name)
    if ($Cond) { $script:Pass++; Write-Host ('  PASS  ' + $Name) }
    else       { $script:Fail++; Write-Host ('  FAIL  ' + $Name) }
  }
  Write-Host '== DiskCleanerPro SelfTest =='

  Write-Host '[1] 配置加载'
  $items = Load-CleanupItems
  Assert-True ($items.Count -gt 10) ("从 config 加载清理项 " + $items.Count + " 项")

  Write-Host '[2] 白名单闸门'
  Assert-True (-not (Test-Whitelist (Join-Path $env:SystemRoot 'System32'))) 'System32 被拒绝'
  Assert-True (-not (Test-Whitelist ($env:SystemDrive + '\'))) '盘根被拒绝'
  Assert-True (-not (Test-Whitelist $script:ToolRoot)) '工具自身目录被拒绝'
  $td = Join-Path $script:ToolRoot 'testdata'
  Assert-True (Test-Whitelist (Join-Path $td 'sub')) 'testdata 子路径允许'

  Write-Host '[3] 大小计算'
  $sizeDir = Join-Path $td 'size'
  New-Item -ItemType Directory -Force -Path $sizeDir | Out-Null
  1..5 | ForEach-Object {
    [IO.File]::WriteAllBytes((Join-Path $sizeDir ('f' + $_ + '.txt')), (New-Object byte[] 1000))
  }
  $sz = Measure-DirBytes $sizeDir
  Assert-True ($sz -eq 5000) ("Measure-DirBytes 5KB (实测 " + $sz + ")")

  Write-Host '[4] 回收站模式（保留根 + 占用跳过）'
  $rb = Join-Path $td 'rb'
  New-Item -ItemType Directory -Force -Path $rb | Out-Null
  [IO.File]::WriteAllText((Join-Path $rb 'a.txt'), 'aaa')
  $sub = Join-Path $rb 'sub'
  New-Item -ItemType Directory -Force -Path $sub | Out-Null
  [IO.File]::WriteAllText((Join-Path $sub 'b.txt'), 'bbb')
  $locked = Join-Path $rb 'locked.txt'
  [IO.File]::WriteAllText($locked, 'locked')
  $fs = [IO.File]::Open($locked, 'Open', 'Read', [IO.FileShare]::None)   # 模拟占用
  $fakeItem = [pscustomobject]@{ method = 'delete-dir'; name = 'test-rb'; paths = @($rb) }
  Invoke-SafeDelete $fakeItem 'Recycle' | Out-Null
  $fs.Close(); $fs.Dispose()
  Assert-True (Test-Path -LiteralPath $rb) '根目录保留'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $rb 'a.txt'))) '普通文件已进回收站'
  Assert-True (-not (Test-Path -LiteralPath $sub)) '子目录已回收'
  Assert-True (Test-Path -LiteralPath $locked) '被占用文件已跳过'
  Remove-Item -LiteralPath $locked -Force -ErrorAction SilentlyContinue

  Write-Host '[5] 永久模式'
  $perm = Join-Path $td 'perm'
  New-Item -ItemType Directory -Force -Path $perm | Out-Null
  [IO.File]::WriteAllText((Join-Path $perm 'a.txt'), 'aaa')
  $fakeItem2 = [pscustomobject]@{ method = 'delete-dir'; name = 'test-perm'; paths = @($perm) }
  Invoke-SafeDelete $fakeItem2 'Permanent' | Out-Null
  Assert-True (-not (Test-Path -LiteralPath $perm)) '永久删除成功'

  Write-Host '[6] 通配符 delete-file'
  $wf = Join-Path $td 'wf'
  New-Item -ItemType Directory -Force -Path $wf | Out-Null
  [IO.File]::WriteAllText((Join-Path $wf 'thumbcache_a.db'), 'x')
  [IO.File]::WriteAllText((Join-Path $wf 'keep.txt'), 'y')
  $patItem = [pscustomobject]@{ method = 'delete-file'; name = 'test-pat'; paths = @((Join-Path $wf 'thumbcache_*.db')) }
  Invoke-SafeDelete $patItem 'Recycle' | Out-Null
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $wf 'thumbcache_a.db'))) '通配符文件已删'
  Assert-True (Test-Path -LiteralPath (Join-Path $wf 'keep.txt')) '非匹配文件保留'

  Write-Host '[7] 多级通配符展开'
  $jb = Join-Path $td 'jb'
  foreach ($ide in 'IDEA', 'PyCharm') {
    New-Item -ItemType Directory -Force -Path (Join-Path $jb (Join-Path $ide 'log')) | Out-Null
  }
  $g1 = Get-ExpandedPaths (Join-Path $jb '*')
  Assert-True ($g1.Count -eq 2) ("一级通配符 2 项 (实测 " + $g1.Count + ")")
  $g2 = Get-ExpandedPaths (Join-Path $jb '*\log')
  Assert-True ($g2.Count -eq 2) ("二级通配符 2 项 (实测 " + $g2.Count + ")")
  $up = Join-Path $td 'up'
  New-Item -ItemType Directory -Force -Path (Join-Path $up 'utools-updater') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $up 'keepdir') | Out-Null
  $g3 = Get-ExpandedPaths (Join-Path $up '*-updater')
  Assert-True ($g3.Count -eq 1) ("尾段通配符 1 项 (实测 " + $g3.Count + ")")

  Write-Host '[8] 清理测试数据'
  if (Test-Path $td) { Remove-Item -LiteralPath $td -Recurse -Force -ErrorAction SilentlyContinue }

  Write-Host ('== 结果: PASS=' + $script:Pass + '  FAIL=' + $script:Fail + ' ==')
  if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
}
#endregion

#region 入口
if ($SelfTest) { Run-SelfTest; return }
$win = New-MainWindow
$null = $win.ShowDialog()
#endregion
