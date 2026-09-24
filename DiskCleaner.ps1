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
$script:Theme = @{
  Bg        = '#FFF3E0'   # 主背景（浅橙米）
  Banner    = '#E65100'   # 顶部横幅（深橙）
  Primary   = '#F57C00'   # 主按钮（橙）
  Secondary = '#FB8C00'   # 次级按钮
  Green     = '#43A047'   # 绝对安全
  Yellow    = '#F9A825'   # 谨慎
  Red       = '#E53935'   # 需确认
  Text      = '#3E2723'   # 主文字（深棕）
  Disabled  = '#BDBDBD'
  FontUi    = 'Microsoft YaHei UI'   # 界面统一字体（Win11 风格）
  CardBg    = '#FFFFFF'   # 卡片/面板背景
  CardLine  = '#F0E2D0'   # 面板分隔线
  LightBtn  = '#FBE7CC'   # 浅橙副按钮（深色文字）
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
}
'@
}
# 统一创建现代按钮：$Back 十六进制，默认浅橙副按钮样式（深色主按钮/红色危险按钮由调用处显式覆盖）
function New-ModernButton {
  param([string]$Text, [string]$Back = $script:Theme.LightBtn, [string]$Fore = '#6D4C41', [int]$FontSize = 9, [switch]$Bold)
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
$script:StaticWhitelist = @(
  'C:\', 'D:\', 'E:\', 'F:\', 'G:\', 'H:\', 'I:\', 'J:\', 'K:\', 'L:\',
  "$env:WINDIR", "$env:WINDIR\System32", "$env:WINDIR\WinSxS",
  "$env:WINDIR\assembly", "$env:WINDIR\SysWOW64",
  "$env:USERPROFILE",
  "$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:ProgramData",
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
  # 显式放行工具自建的可丢弃测试数据（testdata，仅自测用、无真实数据），
  # 须在静态/动态白名单判断之前短路，否则会被盘根(G:\)等规则拦死
  $testArea = Join-Path $script:ToolRoot 'testdata'
  try { $ta = [IO.Path]::GetFullPath($testArea).TrimEnd('\') + '\' } catch { $ta = '' }
  if ($ta -and $fp.StartsWith($ta, 'OrdinalIgnoreCase')) { return $true }
  foreach ($w in ($script:StaticWhitelist + $script:DynamicWhitelist)) {
    try { $we = [IO.Path]::GetFullPath((Expand-EnvPath $w)).TrimEnd('\') + '\' } catch { continue }
    if ($fp.StartsWith($we, 'OrdinalIgnoreCase')) { return $false }  # 目标位于白名单内 → 禁止
    if ($we.StartsWith($fp, 'OrdinalIgnoreCase')) { return $false }  # 目标是白名单祖先(如盘根) → 禁止
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

function New-PlaceholderPage {
  # 附加功能 Tab 占位页（提交6 填充）
  param([string]$Text, [string]$Msg)
  $p = New-Object System.Windows.Forms.TabPage
  $p.Text = $Text
  $p.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Bg)
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $Msg
  $l.Font = New-Object System.Drawing.Font($script:Theme.FontUi,12)
  $l.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $l.AutoSize = $true
  $l.Location = New-Object System.Drawing.Point(24, 30)
  $p.Controls.Add($l)
  return $p
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

function New-SpacePage {
  $p = New-Object System.Windows.Forms.TabPage
  $p.Text = '空间分析'
  $p.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Bg)
  $p.Width = 1200

  $top = New-Object System.Windows.Forms.Panel
  $top.Dock = 'Top'; $top.Height = 44; $top.BackColor = [System.Drawing.Color]::White

  $lblDrv2 = New-Object System.Windows.Forms.Label
  $lblDrv2.Text = '磁盘:'; $lblDrv2.Location = New-Object System.Drawing.Point(12, 13); $lblDrv2.AutoSize = $true
  $top.Controls.Add($lblDrv2)
  $script:CmbSpaceDrive = New-Object System.Windows.Forms.ComboBox
  $script:CmbSpaceDrive.Location = New-Object System.Drawing.Point(52, 10); $script:CmbSpaceDrive.Width = 66
  foreach ($d in (Get-FixedDrives)) { $null = $script:CmbSpaceDrive.Items.Add($d) }
  if ($script:CmbSpaceDrive.Items.Count -gt 0) { $script:CmbSpaceDrive.SelectedIndex = 0 }
  $top.Controls.Add($script:CmbSpaceDrive)

  $script:BtnSpaceScan = New-ModernButton
  $script:BtnSpaceScan.Text = '开始扫描'
  $script:BtnSpaceScan.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $script:BtnSpaceScan.ForeColor = [System.Drawing.Color]::White; $script:BtnSpaceScan.FlatStyle = 'Flat'
  $script:BtnSpaceScan.Location = New-Object System.Drawing.Point(126, 8); $script:BtnSpaceScan.Size = New-Object System.Drawing.Size(90, 28)
  $top.Controls.Add($script:BtnSpaceScan)
  $script:BtnSpaceStop = New-ModernButton
  $script:BtnSpaceStop.Text = '停止'
  $script:BtnSpaceStop.Location = New-Object System.Drawing.Point(222, 8); $script:BtnSpaceStop.Size = New-Object System.Drawing.Size(60, 28); $script:BtnSpaceStop.Enabled = $false
  $top.Controls.Add($script:BtnSpaceStop)
  $script:BtnSpaceUp = New-ModernButton
  $script:BtnSpaceUp.Text = '上级目录'
  $script:BtnSpaceUp.Location = New-Object System.Drawing.Point(288, 8); $script:BtnSpaceUp.Size = New-Object System.Drawing.Size(76, 28); $script:BtnSpaceUp.Enabled = $false
  $top.Controls.Add($script:BtnSpaceUp)
  $script:ProgSpace = New-ModernProgressBar
  $script:ProgSpace.Location = New-Object System.Drawing.Point(372, 13); $script:ProgSpace.Size = New-Object System.Drawing.Size(200, 16)
  $top.Controls.Add($script:ProgSpace)
  $script:LblSpaceStatus = New-Object System.Windows.Forms.Label
  $script:LblSpaceStatus.Text = '就绪'; $script:LblSpaceStatus.Location = New-Object System.Drawing.Point(580, 14); $script:LblSpaceStatus.AutoSize = $true
  $top.Controls.Add($script:LblSpaceStatus)

  $script:LblSpacePath = New-Object System.Windows.Forms.Label
  $script:LblSpacePath.Text = '（扫描后双击目录逐级下钻）'
  $script:LblSpacePath.Font = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Bold)
  $script:LblSpacePath.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $script:LblSpacePath.Location = New-Object System.Drawing.Point(592, 14)
  $script:LblSpacePath.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $script:LblSpacePath.AutoEllipsis = $true
  $top.Controls.Add($script:LblSpacePath)

  $script:LvSpace = New-Object System.Windows.Forms.ListView
  $script:LvSpace.Dock = 'Fill'
  $script:LvSpace.View = 'Details'; $script:LvSpace.FullRowSelect = $true; $script:LvSpace.GridLines = $false; $script:LvSpace.HideSelection = $false
  $script:LvSpace.UseCompatibleStateImageBehavior = $false
  $null = $script:LvSpace.Columns.Add('名称', 260)
  $null = $script:LvSpace.Columns.Add('总占用', 110)
  $null = $script:LvSpace.Columns.Add('占比', 70)
  $null = $script:LvSpace.Columns.Add('自身文件', 110)
  $null = $script:LvSpace.Columns.Add('完整路径', 540)

  $foot = New-Object System.Windows.Forms.Panel
  $foot.Dock = 'Bottom'; $foot.Height = 48; $foot.BackColor = [System.Drawing.Color]::White
  $foot.Width = 1200
  $script:LblSpaceHint = New-Object System.Windows.Forms.Label
  $script:LblSpaceHint.Text = '双击行进入目录；右键可打开/复制/删除到回收站。'
  $script:LblSpaceHint.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $script:LblSpaceHint.Location = New-Object System.Drawing.Point(12, 15); $script:LblSpaceHint.AutoSize = $true
  $foot.Controls.Add($script:LblSpaceHint)
  $script:BtnSpaceDel = New-ModernButton
  $script:BtnSpaceDel.Text = '删除选中(回收站)'
  $script:BtnSpaceDel.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Red)
  $script:BtnSpaceDel.ForeColor = [System.Drawing.Color]::White; $script:BtnSpaceDel.FlatStyle = 'Flat'
  $script:BtnSpaceDel.Location = New-Object System.Drawing.Point(1030, 9); $script:BtnSpaceDel.Size = New-Object System.Drawing.Size(140, 30)
  $script:BtnSpaceDel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $foot.Controls.Add($script:BtnSpaceDel)

  $p.Controls.Add($foot)
  $p.Controls.Add($top)
  $p.Controls.Add($script:LvSpace)

  $menuSp = New-Object System.Windows.Forms.ContextMenuStrip
  $miSpOpen = New-Object System.Windows.Forms.ToolStripMenuItem('打开所在文件夹')
  $miSpCopy = New-Object System.Windows.Forms.ToolStripMenuItem('复制路径')
  $miSpDel = New-Object System.Windows.Forms.ToolStripMenuItem('删除到回收站')
  $null = $menuSp.Items.Add($miSpOpen); $null = $menuSp.Items.Add($miSpCopy); $null = $menuSp.Items.Add($miSpDel)
  $script:LvSpace.ContextMenuStrip = $menuSp

  $script:SpaceOwn = $null     # Dictionary[dir] = 直接文件字节
  $script:SpaceTotal = $null   # Dictionary[dir] = 含子孙合计字节
  $script:SpaceDir = $null     # 当前浏览目录

  function script:Space-FillChildren {
    param([string]$Dir)
    if (-not $script:SpaceTotal) { return }
    if (-not $script:SpaceTotal.ContainsKey($Dir)) { return }
    $script:SpaceDir = $Dir
    $script:LblSpacePath.Text = $Dir
    $dirTotal = $script:SpaceTotal[$Dir]
    $script:BtnSpaceUp.Enabled = ($Dir.LastIndexOf('\') -gt 2)
    $script:LvSpace.BeginUpdate()
    $script:LvSpace.Items.Clear()
    $kids = New-Object System.Collections.Generic.List[object]
    foreach ($k in $script:SpaceTotal.Keys) {
      if ($k.Length -gt $Dir.Length -and $k.StartsWith($Dir, 'OrdinalIgnoreCase')) {
        $rest = $k.Substring($Dir.Length)
        if ($rest.StartsWith('\') -and ($rest.IndexOf('\', 1) -lt 0)) {
          $kids.Add([pscustomobject]@{ Path = $k; Name = $rest.Substring(1) })
        }
      }
    }
    foreach ($kd in ($kids | Sort-Object { -$script:SpaceTotal[$_.Path] })) {
      $tot = $script:SpaceTotal[$kd.Path]
      $ownB = if ($script:SpaceOwn.ContainsKey($kd.Path)) { $script:SpaceOwn[$kd.Path] } else { 0L }
      $pct = if ($dirTotal -gt 0) { ('{0:P1}' -f ($tot / $dirTotal)) } else { '' }
      $li = [System.Windows.Forms.ListViewItem]::new([string[]]@($kd.Name, (Format-Bytes $tot), $pct, (Format-Bytes $ownB), $kd.Path))
      $li.Tag = $kd.Path
      if ($tot -gt 1GB) { $li.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Red) }
      elseif ($tot -gt 100MB) { $li.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Yellow) }
      else { $li.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Green) }
      $null = $script:LvSpace.Items.Add($li)
    }
    $script:LvSpace.EndUpdate()
    $script:LblSpaceStatus.Text = ('当前目录合计: {0}' -f (Format-Bytes $dirTotal))
  }

  $script:SpaceWorker = New-Object System.ComponentModel.BackgroundWorker
  $script:SpaceWorker.WorkerSupportsCancellation = $true
  $script:SpaceWorker.WorkerReportsProgress = $true
  $spaceDoWork = {
    param($s, $e)
    $own = Get-DirSizes -Root ([string]$e.Argument) -W $s
    if ($s.CancellationPending) { $e.Cancel = $true; return }
    $e.Result = @{ Own = $own; Total = (Get-MergedDirTotals $own) }
  }
  Register-WorkerBody -Worker $script:SpaceWorker -Name 'Space' -ScriptBlock $spaceDoWork
  $script:SpaceWorker.add_ProgressChanged({
    param($s, $e)
    $script:LblSpaceStatus.Text = [string]$e.UserState
  })
  $script:SpaceWorker.add_RunWorkerCompleted({
    param($s, $e)
    $script:BtnSpaceScan.Enabled = $true; $script:BtnSpaceStop.Enabled = $false
    $script:ProgSpace.Style = 'Continuous'; $script:ProgSpace.Value = 0
    if ($e.Error) { $script:LblSpaceStatus.Text = '扫描出错'; Log-Line ('空间分析出错: ' + $e.Error.Message); return }
    if ($e.Cancelled) { $script:LblSpaceStatus.Text = '已取消'; return }
    $script:SpaceOwn = $e.Result.Own
    $script:SpaceTotal = $e.Result.Total
    $root = [string]$script:CmbSpaceDrive.SelectedItem + '\'
    if (-not $script:SpaceTotal.ContainsKey($root)) { $root = $root.TrimEnd('\') }
    Space-FillChildren $root
    Log-Line ('空间分析完成: {0} 共 {1} 个目录' -f $script:CmbSpaceDrive.SelectedItem, $script:SpaceTotal.Count)
  })

  $script:BtnSpaceScan.add_Click({
    $drive = [string]$script:CmbSpaceDrive.SelectedItem
    if (-not $drive) {
      try { [System.Windows.Forms.MessageBox]::Show('请先选择磁盘。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $script:BtnSpaceScan.Enabled = $false; $script:BtnSpaceStop.Enabled = $true
    $script:ProgSpace.Style = 'Marquee'; $script:ProgSpace.MarqueeAnimationSpeed = 30
    $script:LblSpaceStatus.Text = '扫描中...'
    $script:LvSpace.Items.Clear(); $script:SpaceOwn = $null; $script:SpaceTotal = $null
    Log-Line ('空间分析扫描开始: ' + $drive)
    $script:SpaceWorker.RunWorkerAsync(($drive + '\'))
  })
  $script:BtnSpaceStop.add_Click({ $script:SpaceWorker.CancelAsync() })
  $script:BtnSpaceUp.add_Click({
    if ($script:SpaceDir) {
      $pi = $script:SpaceDir.LastIndexOf('\')
      if ($pi -gt 2) {
        $up = $script:SpaceDir.Substring(0, $pi)
        if (-not $up.EndsWith('\')) { $up += '\' }
        Space-FillChildren $up
      } elseif ($pi -eq 2) {
        Space-FillChildren ($script:SpaceDir.Substring(0, 3))
      }
    }
  })
  $script:LvSpace.add_DoubleClick({
    if ($script:LvSpace.SelectedItems.Count -gt 0) {
      $path = [string]$script:LvSpace.SelectedItems[0].Tag
      if ($script:SpaceTotal -and $script:SpaceTotal.ContainsKey($path)) { Space-FillChildren $path }
    }
  })
  $miSpOpen.add_Click({
    if ($script:LvSpace.SelectedItems.Count -gt 0) { Open-InExplorer -Path ([string]$script:LvSpace.SelectedItems[0].Tag) -Select }
  })
  $miSpCopy.add_Click({
    if ($script:LvSpace.SelectedItems.Count -gt 0) {
      try { [System.Windows.Forms.Clipboard]::SetText([string]$script:LvSpace.SelectedItems[0].Tag) } catch { }
    }
  })
  $script:BtnSpaceDel.add_Click({
    $sel = @($script:LvSpace.SelectedItems)
    if ($sel.Count -eq 0) {
      try { [System.Windows.Forms.MessageBox]::Show('请先选择要删除的目录。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(('确定将选中的 {0} 个目录删除到回收站？' -f $sel.Count), '确认删除', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $rel = 0L; $ok = 0
    foreach ($li in $sel) {
      $path = [string]$li.Tag
      $b = Remove-UserPathToRecycle $path
      if ($b -gt 0) { $ok++; $rel += $b }
      # 从索引中移除该目录及其子孙，并把释放量从各级祖先合计中扣减
      try {
        foreach ($k in @($script:SpaceTotal.Keys)) {
          if ($k -eq $path -or $k.StartsWith($path + '\', 'OrdinalIgnoreCase')) {
            $script:SpaceTotal.Remove($k)
            if ($script:SpaceOwn.ContainsKey($k)) { $script:SpaceOwn.Remove($k) }
          }
        }
        $cur = $path
        while ($true) {
          $pi = $cur.LastIndexOf('\')
          if ($pi -lt 2) { break }
          $cur = $cur.Substring(0, $pi)
          if ($script:SpaceTotal.ContainsKey($cur)) { $script:SpaceTotal[$cur] -= $b }
          if ($cur.EndsWith('\')) { break }
        }
      } catch { }
    }
    Log-Line ('空间分析删除: 成功 {0}/{1}, 释放 {2}' -f $ok, $sel.Count, (Format-Bytes $rel))
    if ($script:SpaceDir) { Space-FillChildren $script:SpaceDir }
    try {
      [System.Windows.Forms.MessageBox]::Show(('已删除 {0} 个目录，释放 {1}；占用/受保护自动跳过。' -f $ok, (Format-Bytes $rel)), '完成', 'OK', 'Information')
    } catch { }
  })
  $miSpDel.add_Click({ $script:BtnSpaceDel.PerformClick() })

  return $p
}

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

function New-LargeFilesPage {
  $p = New-Object System.Windows.Forms.TabPage
  $p.Text = '大文件'
  $p.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Bg)
  # 先按设计宽度设置：底部操作条及其右锚定删除按钮首次布局按真实宽度计算
  $p.Width = 1200

  $top = New-Object System.Windows.Forms.Panel
  $top.Dock = 'Top'; $top.Height = 44; $top.BackColor = [System.Drawing.Color]::White

  $lblDrv = New-Object System.Windows.Forms.Label
  $lblDrv.Text = '磁盘:'; $lblDrv.Location = New-Object System.Drawing.Point(12, 13); $lblDrv.AutoSize = $true
  $top.Controls.Add($lblDrv)
  $script:CmbDrive = New-Object System.Windows.Forms.ComboBox
  $script:CmbDrive.Location = New-Object System.Drawing.Point(52, 10); $script:CmbDrive.Width = 66
  foreach ($d in (Get-FixedDrives)) { $null = $script:CmbDrive.Items.Add($d) }
  if ($script:CmbDrive.Items.Count -gt 0) { $script:CmbDrive.SelectedIndex = 0 }
  $top.Controls.Add($script:CmbDrive)

  $lblTh = New-Object System.Windows.Forms.Label
  $lblTh.Text = '最小大小:'; $lblTh.Location = New-Object System.Drawing.Point(130, 13); $lblTh.AutoSize = $true
  $top.Controls.Add($lblTh)
  $script:CmbTh = New-Object System.Windows.Forms.ComboBox
  $script:CmbTh.Location = New-Object System.Drawing.Point(196, 10); $script:CmbTh.Width = 90
  $null = $script:CmbTh.Items.Add('100 MB'); $null = $script:CmbTh.Items.Add('300 MB'); $null = $script:CmbTh.Items.Add('500 MB'); $null = $script:CmbTh.Items.Add('1 GB')
  $script:CmbTh.SelectedIndex = 0
  $top.Controls.Add($script:CmbTh)

  $script:BtnScanL = New-ModernButton
  $script:BtnScanL.Text = '开始扫描'
  $script:BtnScanL.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $script:BtnScanL.ForeColor = [System.Drawing.Color]::White; $script:BtnScanL.FlatStyle = 'Flat'
  $script:BtnScanL.Location = New-Object System.Drawing.Point(300, 8); $script:BtnScanL.Size = New-Object System.Drawing.Size(90, 28)
  $top.Controls.Add($script:BtnScanL)
  $script:BtnStopL = New-ModernButton
  $script:BtnStopL.Text = '停止'
  $script:BtnStopL.Location = New-Object System.Drawing.Point(396, 8); $script:BtnStopL.Size = New-Object System.Drawing.Size(60, 28); $script:BtnStopL.Enabled = $false
  $top.Controls.Add($script:BtnStopL)
  $script:ProgL = New-ModernProgressBar
  $script:ProgL.Location = New-Object System.Drawing.Point(466, 13); $script:ProgL.Size = New-Object System.Drawing.Size(220, 16)
  $top.Controls.Add($script:ProgL)
  $script:LblL = New-Object System.Windows.Forms.Label
  $script:LblL.Text = '就绪'; $script:LblL.Location = New-Object System.Drawing.Point(694, 14); $script:LblL.AutoSize = $true
  $top.Controls.Add($script:LblL)

  $script:LvLarge = New-Object System.Windows.Forms.ListView
  $script:LvLarge.Dock = 'Fill'
  $script:LvLarge.View = 'Details'; $script:LvLarge.FullRowSelect = $true; $script:LvLarge.GridLines = $false; $script:LvLarge.HideSelection = $false
  $script:LvLarge.UseCompatibleStateImageBehavior = $false
  $null = $script:LvLarge.Columns.Add('名称', 220)
  $null = $script:LvLarge.Columns.Add('大小', 90)
  $null = $script:LvLarge.Columns.Add('修改时间', 130)
  $null = $script:LvLarge.Columns.Add('路径', 560)

  $foot = New-Object System.Windows.Forms.Panel
  $foot.Dock = 'Bottom'; $foot.Height = 48; $foot.BackColor = [System.Drawing.Color]::White
  # 先按设计宽度设置（与主窗 1200 一致）：右锚定删除按钮首次布局时按真实右缘计算
  $foot.Width = 1200
  $script:LblLTotal = New-Object System.Windows.Forms.Label
  $script:LblLTotal.Text = '共 0 个文件'
  $script:LblLTotal.Font = New-Object System.Drawing.Font($script:Theme.FontUi,10, [System.Drawing.FontStyle]::Bold)
  $script:LblLTotal.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $script:LblLTotal.Location = New-Object System.Drawing.Point(12, 14); $script:LblLTotal.AutoSize = $true
  $foot.Controls.Add($script:LblLTotal)
  $script:BtnDelL = New-ModernButton
  $script:BtnDelL.Text = '删除选中(回收站)'
  $script:BtnDelL.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Red)
  $script:BtnDelL.ForeColor = [System.Drawing.Color]::White; $script:BtnDelL.FlatStyle = 'Flat'
  $script:BtnDelL.Location = New-Object System.Drawing.Point(1030, 9); $script:BtnDelL.Size = New-Object System.Drawing.Size(140, 30)
  $script:BtnDelL.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $foot.Controls.Add($script:BtnDelL)

  $p.Controls.Add($foot)
  $p.Controls.Add($top)
  $p.Controls.Add($script:LvLarge)

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $miOpen = New-Object System.Windows.Forms.ToolStripMenuItem('打开所在文件夹')
  $miCopy = New-Object System.Windows.Forms.ToolStripMenuItem('复制路径')
  $miDelL = New-Object System.Windows.Forms.ToolStripMenuItem('删除到回收站')
  $null = $menu.Items.Add($miOpen); $null = $menu.Items.Add($miCopy); $null = $menu.Items.Add($miDelL)
  $script:LvLarge.ContextMenuStrip = $menu

  $script:LfWorker = New-Object System.ComponentModel.BackgroundWorker
  $script:LfWorker.WorkerSupportsCancellation = $true
  $script:LfWorker.WorkerReportsProgress = $true
  $lfDoWork = {
    param($s, $e)
    $a = $e.Argument
    $list = Get-LargeFiles -Root $a.Root -Threshold $a.Threshold -W $s
    if ($s.CancellationPending) { $e.Cancel = $true; return }
    $e.Result = $list
  }
  Register-WorkerBody -Worker $script:LfWorker -Name 'Lf' -ScriptBlock $lfDoWork
  $script:LfWorker.add_ProgressChanged({
    param($s, $e)
    $script:LblL.Text = [string]$e.UserState
  })
  $script:LfWorker.add_RunWorkerCompleted({
    param($s, $e)
    $script:BtnScanL.Enabled = $true; $script:BtnStopL.Enabled = $false
    $script:ProgL.Style = 'Continuous'; $script:ProgL.Value = 0
    if ($e.Cancelled) { $script:LblL.Text = '已取消'; return }
    $rows = @($e.Result)
    $script:LvLarge.BeginUpdate(); $script:LvLarge.Items.Clear()
    $totalBytes = 0L
    foreach ($r in $rows) {
      $totalBytes += [long]$r.Size
      $li = [System.Windows.Forms.ListViewItem]::new([string[]]@($r.Name, (Format-Bytes $r.Size), $r.Modified.ToString('yyyy-MM-dd HH:mm'), $r.Path))
      $li.Tag = $r
      $null = $script:LvLarge.Items.Add($li)
    }
    $script:LvLarge.EndUpdate()
    $script:LblLTotal.Text = ('共 {0} 个文件 / {1}' -f $rows.Count, (Format-Bytes $totalBytes))
    $script:LblL.Text = '完成'
    Log-Line ('大文件扫描完成: {0} 个' -f $rows.Count)
  })

  $script:BtnScanL.add_Click({
    $drive = [string]$script:CmbDrive.SelectedItem
    if (-not $drive) {
      try { [System.Windows.Forms.MessageBox]::Show('请先选择磁盘。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $mb = switch ([string]$script:CmbTh.SelectedItem) { '300 MB' { 300 } '500 MB' { 500 } '1 GB' { 1024 } default { 100 } }
    $script:BtnScanL.Enabled = $false; $script:BtnStopL.Enabled = $true
    $script:ProgL.Style = 'Marquee'; $script:ProgL.MarqueeAnimationSpeed = 30
    $script:LblL.Text = '扫描中...'
    $script:LvLarge.Items.Clear(); $script:LblLTotal.Text = '共 0 个文件'
    Log-Line ('大文件扫描开始: {0} >= {1}' -f $drive, $script:CmbTh.SelectedItem)
    $script:LfWorker.RunWorkerAsync(@{ Root = ($drive + '\'); Threshold = ([long]$mb * 1024 * 1024) })
  })
  $script:BtnStopL.add_Click({ $script:LfWorker.CancelAsync() })
  $miOpen.add_Click({
    if ($script:LvLarge.SelectedItems.Count -gt 0) { Open-InExplorer -Path $script:LvLarge.SelectedItems[0].Tag.Path -Select }
  })
  $miCopy.add_Click({
    if ($script:LvLarge.SelectedItems.Count -gt 0) { try { [System.Windows.Forms.Clipboard]::SetText([string]$script:LvLarge.SelectedItems[0].Tag.Path) } catch { } }
  })
  $script:BtnDelL.add_Click({
    $sel = @($script:LvLarge.SelectedItems | ForEach-Object { $_.Tag })
    if ($sel.Count -eq 0) {
      try { [System.Windows.Forms.MessageBox]::Show('请先选择要删除的大文件。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(('确定将选中的 {0} 个大文件删除到回收站？' -f $sel.Count), '确认删除', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $rel = 0L; $ok = 0
    foreach ($it in $sel) {
      $b = Remove-UserPathToRecycle $it.Path
      if ($b -gt 0) { $ok++; $rel += $b }
    }
    Log-Line ('大文件删除: 成功 {0}/{1}, 释放 {2}' -f $ok, $sel.Count, (Format-Bytes $rel))
    foreach ($li in @($script:LvLarge.SelectedItems)) { $script:LvLarge.Items.Remove($li) }
    $totalBytes = 0L
    foreach ($li2 in $script:LvLarge.Items) { if ($li2.Tag) { $totalBytes += [long]$li2.Tag.Size } }
    $script:LblLTotal.Text = ('共 {0} 个文件 / {1}' -f $script:LvLarge.Items.Count, (Format-Bytes $totalBytes))
    try {
      [System.Windows.Forms.MessageBox]::Show(('已删除 {0} 个大文件，释放 {1}；被占用/受保护的文件自动跳过。' -f $ok, (Format-Bytes $rel)), '完成', 'OK', 'Information')
    } catch { }
  })
  $miDelL.add_Click({ $script:BtnDelL.PerformClick() })

  return $p
}

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

function New-SoftwarePage {
  $p = New-Object System.Windows.Forms.TabPage
  $p.Text = '软件占用'
  $p.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Bg)

  $top = New-Object System.Windows.Forms.Panel
  $top.Dock = 'Top'; $top.Height = 44; $top.BackColor = [System.Drawing.Color]::White

  $btnSoftRefresh = New-ModernButton
  $btnSoftRefresh.Text = '刷新列表'
  $btnSoftRefresh.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $btnSoftRefresh.ForeColor = [System.Drawing.Color]::White; $btnSoftRefresh.FlatStyle = 'Flat'
  $btnSoftRefresh.Location = New-Object System.Drawing.Point(12, 8); $btnSoftRefresh.Size = New-Object System.Drawing.Size(90, 28)
  $top.Controls.Add($btnSoftRefresh)
  $script:BtnSoftReal = New-ModernButton
  $script:BtnSoftReal.Text = '计算实际占用'
  $script:BtnSoftReal.Location = New-Object System.Drawing.Point(108, 8); $script:BtnSoftReal.Size = New-Object System.Drawing.Size(120, 28)
  $top.Controls.Add($script:BtnSoftReal)
  $script:LblSoft = New-Object System.Windows.Forms.Label
  $script:LblSoft.Text = '信息展示为主，不提供卸载。'
  $script:LblSoft.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Disabled)
  $script:LblSoft.Location = New-Object System.Drawing.Point(240, 14); $script:LblSoft.AutoSize = $true
  $top.Controls.Add($script:LblSoft)

  $script:LvSoft = New-Object System.Windows.Forms.ListView
  $script:LvSoft.Dock = 'Fill'
  $script:LvSoft.View = 'Details'; $script:LvSoft.FullRowSelect = $true; $script:LvSoft.GridLines = $false; $script:LvSoft.HideSelection = $false
  $script:LvSoft.UseCompatibleStateImageBehavior = $false
  $null = $script:LvSoft.Columns.Add('名称', 200)
  $null = $script:LvSoft.Columns.Add('发布者', 150)
  $null = $script:LvSoft.Columns.Add('版本', 110)
  $null = $script:LvSoft.Columns.Add('安装位置', 320)
  $null = $script:LvSoft.Columns.Add('注册大小', 80)
  $null = $script:LvSoft.Columns.Add('实际占用', 90)

  $menuS = New-Object System.Windows.Forms.ContextMenuStrip
  $miSoftOpen = New-Object System.Windows.Forms.ToolStripMenuItem('打开安装目录')
  $miSoftCopy = New-Object System.Windows.Forms.ToolStripMenuItem('复制安装路径')
  $null = $menuS.Items.Add($miSoftOpen); $null = $menuS.Items.Add($miSoftCopy)
  $script:LvSoft.ContextMenuStrip = $menuS

  $p.Controls.Add($top)
  $p.Controls.Add($script:LvSoft)

  function script:Fill-SoftwareList {
    $script:LvSoft.BeginUpdate(); $script:LvSoft.Items.Clear()
    foreach ($s in (Get-InstalledSoftware)) {
      $realTxt = if ($s.RealBytes -gt 0) { Format-Bytes $s.RealBytes } else { '' }
      $regTxt = if ($s.RegKB -gt 0) { Format-Bytes ($s.RegKB * 1024) } else { '' }
      $li = [System.Windows.Forms.ListViewItem]::new([string[]]@($s.Name, $s.Publisher, $s.Version, $s.Location, $regTxt, $realTxt))
      $li.Tag = $s
      $null = $script:LvSoft.Items.Add($li)
    }
    $script:LvSoft.EndUpdate()
    $script:LblSoft.Text = ('共 {0} 个已安装软件' -f $script:LvSoft.Items.Count)
  }

  $script:SoftWorker = New-Object System.ComponentModel.BackgroundWorker
  $softDoWork = {
    param($s, $e)
    $row = $e.Argument
    $bytes = 0L
    if ($row.Location -and (Test-Path -LiteralPath $row.Location)) {
      try { $bytes = Measure-DirBytes $row.Location } catch { $bytes = 0L }
    }
    $e.Result = @{ Row = $row; Bytes = $bytes }
  }
  Register-WorkerBody -Worker $script:SoftWorker -Name 'Soft' -ScriptBlock $softDoWork
  $script:SoftWorker.add_RunWorkerCompleted({
    param($s, $e)
    $script:BtnSoftReal.Enabled = $true
    $r = $e.Result
    $r.Row.RealBytes = $r.Bytes
    foreach ($li in $script:LvSoft.Items) {
      if ($li.Tag -eq $r.Row) {
        $li.SubItems[5].Text = if ($r.Bytes -gt 0) { Format-Bytes $r.Bytes } else { '（不可测/无位置）' }
        break
      }
    }
    Log-Line ('实际占用: {0} = {1}' -f $r.Row.Name, (Format-Bytes $r.Bytes))
  })

  $btnSoftRefresh.add_Click({ Fill-SoftwareList; Log-Line ('软件列表已刷新: {0} 项' -f $script:LvSoft.Items.Count) })
  $script:BtnSoftReal.add_Click({
    if ($script:LvSoft.SelectedItems.Count -eq 0) {
      try { [System.Windows.Forms.MessageBox]::Show('请先选择要计算占用的一项软件。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $row = $script:LvSoft.SelectedItems[0].Tag
    if (-not $row.Location -or -not (Test-Path -LiteralPath $row.Location)) {
      try { [System.Windows.Forms.MessageBox]::Show('该项未记录安装位置，无法计算实际占用。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $script:BtnSoftReal.Enabled = $false
    $script:SoftWorker.RunWorkerAsync($row)
  })
  $miSoftOpen.add_Click({
    if ($script:LvSoft.SelectedItems.Count -gt 0 -and $script:LvSoft.SelectedItems[0].Tag.Location) {
      Open-InExplorer -Path $script:LvSoft.SelectedItems[0].Tag.Location
    }
  })
  $miSoftCopy.add_Click({
    if ($script:LvSoft.SelectedItems.Count -gt 0) { try { [System.Windows.Forms.Clipboard]::SetText([string]$script:LvSoft.SelectedItems[0].Tag.Location) } catch { } }
  })

  Fill-SoftwareList
  return $p
}

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

function New-DupeFilesPage {
  $p = New-Object System.Windows.Forms.TabPage
  $p.Text = '重复文件'
  $p.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Bg)
  # 先按设计宽度设置：底部操作条及其右锚定删除按钮首次布局按真实宽度计算
  $p.Width = 1200

  $top = New-Object System.Windows.Forms.Panel
  $top.Dock = 'Top'; $top.Height = 44; $top.BackColor = [System.Drawing.Color]::White

  $lblDupDir = New-Object System.Windows.Forms.Label
  $lblDupDir.Text = '目录:'; $lblDupDir.Location = New-Object System.Drawing.Point(12, 14); $lblDupDir.AutoSize = $true
  $top.Controls.Add($lblDupDir)
  $script:TxtDupDir = New-Object System.Windows.Forms.TextBox
  $script:TxtDupDir.Text = $env:USERPROFILE
  $script:TxtDupDir.Location = New-Object System.Drawing.Point(50, 11); $script:TxtDupDir.Width = 330
  $top.Controls.Add($script:TxtDupDir)
  $btnDupBrowse = New-ModernButton
  $btnDupBrowse.Text = '浏览'
  $btnDupBrowse.Location = New-Object System.Drawing.Point(386, 9); $btnDupBrowse.Size = New-Object System.Drawing.Size(60, 26)
  $top.Controls.Add($btnDupBrowse)
  $script:BtnDupScan = New-ModernButton
  $script:BtnDupScan.Text = '开始检测'
  $script:BtnDupScan.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $script:BtnDupScan.ForeColor = [System.Drawing.Color]::White; $script:BtnDupScan.FlatStyle = 'Flat'
  $script:BtnDupScan.Location = New-Object System.Drawing.Point(452, 8); $script:BtnDupScan.Size = New-Object System.Drawing.Size(90, 28)
  $top.Controls.Add($script:BtnDupScan)
  $script:BtnDupStop = New-ModernButton
  $script:BtnDupStop.Text = '停止'
  $script:BtnDupStop.Location = New-Object System.Drawing.Point(548, 8); $script:BtnDupStop.Size = New-Object System.Drawing.Size(60, 28); $script:BtnDupStop.Enabled = $false
  $top.Controls.Add($script:BtnDupStop)
  $script:ProgD = New-ModernProgressBar
  $script:ProgD.Location = New-Object System.Drawing.Point(618, 13); $script:ProgD.Size = New-Object System.Drawing.Size(200, 16)
  $top.Controls.Add($script:ProgD)
  $script:LblD = New-Object System.Windows.Forms.Label
  $script:LblD.Text = '就绪'; $script:LblD.Location = New-Object System.Drawing.Point(826, 14); $script:LblD.AutoSize = $true
  $top.Controls.Add($script:LblD)

  $script:LvDup = New-Object System.Windows.Forms.ListView
  $script:LvDup.Dock = 'Fill'
  $script:LvDup.View = 'Details'; $script:LvDup.FullRowSelect = $true; $script:LvDup.GridLines = $false; $script:LvDup.HideSelection = $false
  $script:LvDup.CheckBoxes = $true
  $script:LvDup.UseCompatibleStateImageBehavior = $false
  $null = $script:LvDup.Columns.Add('组', 50)
  $null = $script:LvDup.Columns.Add('大小', 90)
  $null = $script:LvDup.Columns.Add('状态', 70)
  $null = $script:LvDup.Columns.Add('路径', 660)

  $foot = New-Object System.Windows.Forms.Panel
  $foot.Dock = 'Bottom'; $foot.Height = 48; $foot.BackColor = [System.Drawing.Color]::White
  # 先按设计宽度设置（与主窗 1200 一致）：右锚定删除按钮首次布局时按真实右缘计算
  $foot.Width = 1200
  $script:LblDupInfo = New-Object System.Windows.Forms.Label
  $script:LblDupInfo.Text = '默认每组保留 1 个副本，其余已勾选待删除。'
  $script:LblDupInfo.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $script:LblDupInfo.Location = New-Object System.Drawing.Point(12, 15); $script:LblDupInfo.AutoSize = $true
  $foot.Controls.Add($script:LblDupInfo)
  $script:BtnDupDel = New-ModernButton
  $script:BtnDupDel.Text = '删除勾选(回收站)'
  $script:BtnDupDel.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Red)
  $script:BtnDupDel.ForeColor = [System.Drawing.Color]::White; $script:BtnDupDel.FlatStyle = 'Flat'
  $script:BtnDupDel.Location = New-Object System.Drawing.Point(1030, 9); $script:BtnDupDel.Size = New-Object System.Drawing.Size(140, 30)
  $script:BtnDupDel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $foot.Controls.Add($script:BtnDupDel)

  $p.Controls.Add($foot)
  $p.Controls.Add($top)
  $p.Controls.Add($script:LvDup)

  $script:DupWorker = New-Object System.ComponentModel.BackgroundWorker
  $script:DupWorker.WorkerSupportsCancellation = $true
  $script:DupWorker.WorkerReportsProgress = $true
  $dupDoWork = {
    param($s, $e)
    $groups = Get-DupeGroups -Root ([string]$e.Argument) -W $s
    if ($s.CancellationPending) { $e.Cancel = $true; return }
    $e.Result = $groups
  }
  Register-WorkerBody -Worker $script:DupWorker -Name 'Dup' -ScriptBlock $dupDoWork
  $script:DupWorker.add_ProgressChanged({
    param($s, $e)
    $script:ProgD.Value = [Math]::Min(100, $e.ProgressPercentage)
    $script:LblD.Text = [string]$e.UserState
  })
  $script:DupWorker.add_RunWorkerCompleted({
    param($s, $e)
    $script:BtnDupScan.Enabled = $true; $script:BtnDupStop.Enabled = $false
    $script:ProgD.Style = 'Continuous'; $script:ProgD.Value = 0
    if ($e.Cancelled) { $script:LblD.Text = '已取消'; return }
    $rows = @($e.Result)
    $script:LvDup.BeginUpdate(); $script:LvDup.Items.Clear()
    foreach ($r in $rows) {
      $keepTxt = if ($r.Keep) { '保留' } else { '待删' }
      $li = [System.Windows.Forms.ListViewItem]::new([string[]]@([string]$r.Group, (Format-Bytes $r.Size), $keepTxt, $r.Path))
      $li.Tag = $r
      $li.Checked = -not $r.Keep
      $li.ForeColor = if ($r.Keep) { [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Green) } else { [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text) }
      $li.BackColor = if ($r.Keep) { [System.Drawing.ColorTranslator]::FromHtml('#E8F5E9') } else { [System.Drawing.ColorTranslator]::FromHtml('#FFF8E1') }
      $null = $script:LvDup.Items.Add($li)
    }
    $script:LvDup.EndUpdate()
    $grp = @($rows | ForEach-Object { $_.Group } | Sort-Object -Unique).Count
    $script:LblDupInfo.Text = ('发现 {0} 组重复文件，共 {1} 个副本（每组保留 1 个）' -f $grp, $rows.Count)
    $script:LblD.Text = '完成'
    Log-Line ('重复文件检测完成: {0} 组 / {1} 文件' -f $grp, $rows.Count)
  })

  $btnDupBrowse.add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = '选择要检测重复文件的目录'
    $d.SelectedPath = $script:TxtDupDir.Text
    if ($d.ShowDialog() -eq 'OK') { $script:TxtDupDir.Text = $d.SelectedPath }
  })
  $script:BtnDupScan.add_Click({
    $root = $script:TxtDupDir.Text.Trim()
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
      try { [System.Windows.Forms.MessageBox]::Show('请输入存在的目录。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $script:BtnDupScan.Enabled = $false; $script:BtnDupStop.Enabled = $true
    $script:ProgD.Style = 'Marquee'; $script:ProgD.MarqueeAnimationSpeed = 30
    $script:LblD.Text = '检测中...'
    $script:LvDup.Items.Clear()
    Log-Line ('重复文件检测开始: ' + $root)
    $script:DupWorker.RunWorkerAsync($root)
  })
  $script:BtnDupStop.add_Click({ $script:DupWorker.CancelAsync() })
  $script:BtnDupDel.add_Click({
    $sel = @($script:LvDup.CheckedItems | ForEach-Object { $_.Tag })
    if ($sel.Count -eq 0) {
      try { [System.Windows.Forms.MessageBox]::Show('没有勾选要删除的文件。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(('确定将 {0} 个重复文件删除到回收站？（每组至少保留 1 个副本，请勿取消"保留"项）' -f $sel.Count), '确认删除', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $rel = 0L; $ok = 0
    foreach ($it in $sel) {
      $b = Remove-UserPathToRecycle $it.Path
      if ($b -gt 0) { $ok++; $rel += $b }
    }
    Log-Line ('重复文件删除: 成功 {0}/{1}, 释放 {2}' -f $ok, $sel.Count, (Format-Bytes $rel))
    foreach ($li in @($script:LvDup.CheckedItems)) { $script:LvDup.Items.Remove($li) }
    try {
      [System.Windows.Forms.MessageBox]::Show(('已删除 {0} 个重复文件，释放 {1}；占用/受保护自动跳过。' -f $ok, (Format-Bytes $rel)), '完成', 'OK', 'Information')
    } catch { }
  })

  return $p
}

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

function New-RestorePage {
  $p = New-Object System.Windows.Forms.TabPage
  $p.Text = '还原点'
  $p.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Bg)

  $script:RPBanner = New-Object System.Windows.Forms.Panel
  $script:RPBanner.Dock = 'Top'; $script:RPBanner.Height = 40; $script:RPBanner.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Yellow)
  $script:LblRPStatus = New-Object System.Windows.Forms.Label
  $script:LblRPStatus.Text = '检测中...'
  $script:LblRPStatus.Font = New-Object System.Drawing.Font($script:Theme.FontUi,10, [System.Drawing.FontStyle]::Bold)
  $script:LblRPStatus.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $script:LblRPStatus.Location = New-Object System.Drawing.Point(12, 10); $script:LblRPStatus.AutoSize = $true
  $script:RPBanner.Controls.Add($script:LblRPStatus)

  $top = New-Object System.Windows.Forms.Panel
  $top.Dock = 'Top'; $top.Height = 44; $top.BackColor = [System.Drawing.Color]::White
  $btnRPRefresh = New-ModernButton
  $btnRPRefresh.Text = '刷新'
  $btnRPRefresh.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $btnRPRefresh.ForeColor = [System.Drawing.Color]::White; $btnRPRefresh.FlatStyle = 'Flat'
  $btnRPRefresh.Location = New-Object System.Drawing.Point(12, 8); $btnRPRefresh.Size = New-Object System.Drawing.Size(70, 28)
  $top.Controls.Add($btnRPRefresh)
  $script:BtnRPDelete = New-ModernButton
  $script:BtnRPDelete.Text = '删除旧还原点(保留最近3个)'
  $script:BtnRPDelete.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Red)
  $script:BtnRPDelete.ForeColor = [System.Drawing.Color]::White; $script:BtnRPDelete.FlatStyle = 'Flat'
  $script:BtnRPDelete.Location = New-Object System.Drawing.Point(88, 8); $script:BtnRPDelete.Size = New-Object System.Drawing.Size(190, 28)
  $top.Controls.Add($script:BtnRPDelete)

  $script:LvRP = New-Object System.Windows.Forms.ListView
  $script:LvRP.Dock = 'Fill'
  $script:LvRP.View = 'Details'; $script:LvRP.FullRowSelect = $true; $script:LvRP.GridLines = $false; $script:LvRP.HideSelection = $false
  $script:LvRP.UseCompatibleStateImageBehavior = $false
  $null = $script:LvRP.Columns.Add('序号', 70)
  $null = $script:LvRP.Columns.Add('创建时间', 150)
  $null = $script:LvRP.Columns.Add('描述', 400)

  $p.Controls.Add($top)
  $p.Controls.Add($script:RPBanner)
  $p.Controls.Add($script:LvRP)

  function script:Fill-RestoreList {
    $script:LvRP.BeginUpdate(); $script:LvRP.Items.Clear()
    $pts = Get-RestorePoints
    if ($pts.Count -eq 0) {
      $script:LblRPStatus.Text = '系统还原不可用或无还原点（本机服务未启用）'
      $script:RPBanner.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Yellow)
      $script:BtnRPDelete.Enabled = $false
    } else {
      foreach ($rp in ($pts | Sort-Object CreationTime -Descending)) {
        # CreationTime 可能是 WMI 字符串日期（如 20260924...+480），须先转 DateTime
        try {
          $dt = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$rp.CreationTime)
        } catch {
          try { $dt = [datetime]$rp.CreationTime } catch { $dt = $null }
        }
        $ctStr = if ($dt) { $dt.ToString('yyyy-MM-dd HH:mm') } else { [string]$rp.CreationTime }
        $li = [System.Windows.Forms.ListViewItem]::new([string[]]@([string]$rp.SequenceNumber, $ctStr, [string]$rp.Description))
        $li.Tag = $rp
        $null = $script:LvRP.Items.Add($li)
      }
      $script:LblRPStatus.Text = ('系统还原可用：共 {0} 个还原点' -f $pts.Count)
      $script:RPBanner.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Green)
      $script:BtnRPDelete.Enabled = $pts.Count -gt 3
    }
    $script:LvRP.EndUpdate()
  }

  $btnRPRefresh.add_Click({ Fill-RestoreList })
  $script:BtnRPDelete.add_Click({
    $r1 = [System.Windows.Forms.MessageBox]::Show('删除旧还原点后无法恢复被删除的系统快照！确定继续？', '危险操作', 'YesNo', 'Warning')
    if ($r1 -ne 'Yes') { return }
    $r2 = [System.Windows.Forms.MessageBox]::Show('再次确认：将删除除最近 3 个外的全部还原点？', '最终确认', 'YesNo', 'Warning')
    if ($r2 -ne 'Yes') { return }
    $del = Remove-OldRestorePoints
    Log-Line ('还原点清理: 删除 {0} 个' -f $del)
    Fill-RestoreList
    try { [System.Windows.Forms.MessageBox]::Show(('已删除 {0} 个旧还原点。' -f $del), '完成', 'OK', 'Information') } catch { }
  })

  Fill-RestoreList
  return $p
}

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

function New-StartupPage {
  $p = New-Object System.Windows.Forms.TabPage
  $p.Text = '启动项'
  $p.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Bg)

  $top = New-Object System.Windows.Forms.Panel
  $top.Dock = 'Top'; $top.Height = 44; $top.BackColor = [System.Drawing.Color]::White

  $btnStRefresh = New-ModernButton
  $btnStRefresh.Text = '刷新'
  $btnStRefresh.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $btnStRefresh.ForeColor = [System.Drawing.Color]::White; $btnStRefresh.FlatStyle = 'Flat'
  $btnStRefresh.Location = New-Object System.Drawing.Point(12, 8); $btnStRefresh.Size = New-Object System.Drawing.Size(70, 28)
  $top.Controls.Add($btnStRefresh)
  $btnStOpen = New-ModernButton
  $btnStOpen.Text = '打开启动文件夹'
  $btnStOpen.Location = New-Object System.Drawing.Point(88, 8); $btnStOpen.Size = New-Object System.Drawing.Size(120, 28)
  $top.Controls.Add($btnStOpen)
  $btnStBackup = New-ModernButton
  $btnStBackup.Text = '备份注册表项(.reg)'
  $btnStBackup.Location = New-Object System.Drawing.Point(214, 8); $btnStBackup.Size = New-Object System.Drawing.Size(140, 28)
  $top.Controls.Add($btnStBackup)
  $script:LblSt = New-Object System.Windows.Forms.Label
  $script:LblSt.Text = '信息展示为主；修改请用系统"任务管理器>启动"或 msconfig。'
  $script:LblSt.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Disabled)
  $script:LblSt.Location = New-Object System.Drawing.Point(364, 14); $script:LblSt.AutoSize = $true
  $top.Controls.Add($script:LblSt)

  $script:LvStart = New-Object System.Windows.Forms.ListView
  $script:LvStart.Dock = 'Fill'
  $script:LvStart.View = 'Details'; $script:LvStart.FullRowSelect = $true; $script:LvStart.GridLines = $false; $script:LvStart.HideSelection = $false
  $script:LvStart.UseCompatibleStateImageBehavior = $false
  $null = $script:LvStart.Columns.Add('来源', 130)
  $null = $script:LvStart.Columns.Add('名称', 200)
  $null = $script:LvStart.Columns.Add('状态', 60)
  $null = $script:LvStart.Columns.Add('命令', 560)

  $menuSt = New-Object System.Windows.Forms.ContextMenuStrip
  $miStCopy = New-Object System.Windows.Forms.ToolStripMenuItem('复制命令')
  $null = $menuSt.Items.Add($miStCopy)
  $script:LvStart.ContextMenuStrip = $menuSt

  $p.Controls.Add($top)
  $p.Controls.Add($script:LvStart)

  function script:Fill-StartupList {
    $script:LvStart.BeginUpdate(); $script:LvStart.Items.Clear()
    foreach ($s in (Get-StartupItems)) {
      $li = [System.Windows.Forms.ListViewItem]::new([string[]]@($s.Source, $s.Name, $s.Status, $s.Command))
      $li.Tag = $s
      $null = $script:LvStart.Items.Add($li)
    }
    $script:LvStart.EndUpdate()
    $script:LblSt.Text = ('共 {0} 个启动项' -f $script:LvStart.Items.Count)
  }

  $btnStRefresh.add_Click({ Fill-StartupList })
  $btnStOpen.add_Click({
    try { Start-Process explorer.exe -ArgumentList ($env:APPDATA + '\Microsoft\Windows\Start Menu\Programs\Startup') } catch { }
  })
  $btnStBackup.add_Click({
    $files = Backup-StartupReg
    if ($files.Count -gt 0) {
      Log-Line ('启动项备份: ' + ($files -join '; '))
      try { [System.Windows.Forms.MessageBox]::Show(('已备份到: ' + ($files -join "`r`n")), '备份完成', 'OK', 'Information') } catch { }
    } else {
      try { [System.Windows.Forms.MessageBox]::Show('备份失败（注册表导出未生成文件）。', '提示', 'OK', 'Warning') } catch { }
    }
  })
  $miStCopy.add_Click({
    if ($script:LvStart.SelectedItems.Count -gt 0) { try { [System.Windows.Forms.Clipboard]::SetText([string]$script:LvStart.SelectedItems[0].Tag.Command) } catch { } }
  })

  Fill-StartupList
  return $p
}
#endregion

#region 主窗口（橙色主题完整界面）
function New-MainWindow {
  $f = New-Object System.Windows.Forms.Form
  $f.Text = 'DiskCleanerPro - C 盘智能清理工具'
  $f.ClientSize = New-Object System.Drawing.Size(1200, 800)
  $f.MinimumSize = New-Object System.Drawing.Size(960, 640)
  $f.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Bg)
  $f.StartPosition = 'CenterScreen'
  $f.Font = New-Object System.Drawing.Font($script:Theme.FontUi, 9)
  # 程序图标：代码绘制橙色圆角方块 + 白色对勾（无图片资源文件）
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
  $f.Icon = [System.Drawing.Icon]::FromHandle($iconBmp.GetHicon())
  $ipen.Dispose(); $ib.Dispose(); $ip.Dispose(); $ig.Dispose(); $iconBmp.Dispose()

  # ============ 顶部横幅 ============
  $banner = New-Object System.Windows.Forms.Panel
  $banner.Dock = 'Top'
  $banner.Height = 100
  # 先按设计宽度设置：右锚定子控件首次布局时才能按真实右缘计算（否则按默认 200 宽算出负留白→被推到屏外）
  $banner.Width = $f.ClientSize.Width
  $banner.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Banner)
  # 横幅渐变：深橙 → 亮橙（LinearGradientBrush 自上而下）
  $banner.add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $rect = $s.ClientRectangle
    $c1 = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Banner)
    $c2 = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Secondary)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 90.0)
    $g.FillRectangle($brush, $rect)
    $brush.Dispose()
  })

  $title = New-Object System.Windows.Forms.Label
  $title.Text = 'DiskCleanerPro  C 盘智能清理工具'
  $title.Font = New-Object System.Drawing.Font($script:Theme.FontUi,20, [System.Drawing.FontStyle]::Bold)
  $title.ForeColor = [System.Drawing.Color]::White
  $title.Location = New-Object System.Drawing.Point(20, 10)
  $title.AutoSize = $true
  $banner.Controls.Add($title)

  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $adminBadge = New-Object System.Windows.Forms.Label
  $adminBadge.Text = if ($isAdmin) { '管理员模式: 已启用' } else { '普通模式（建议以管理员运行）' }
  $adminBadge.Font = New-Object System.Drawing.Font($script:Theme.FontUi,9, [System.Drawing.FontStyle]::Bold)
  $adminBadge.ForeColor = [System.Drawing.Color]::White
  $adminBadge.Location = New-Object System.Drawing.Point(20, 54)
  $adminBadge.AutoSize = $true
  $banner.Controls.Add($adminBadge)

  $script:DiskInfo = New-Object System.Windows.Forms.Label
  $script:DiskInfo.Text = '磁盘信息加载中...'
  $script:DiskInfo.Font = New-Object System.Drawing.Font($script:Theme.FontUi,9)
  $script:DiskInfo.ForeColor = [System.Drawing.Color]::White
  $script:DiskInfo.AutoSize = $true
  $script:DiskInfo.Location = New-Object System.Drawing.Point(940, 54)
  $script:DiskInfo.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $banner.Controls.Add($script:DiskInfo)

  $script:DiskBar = New-ModernProgressBar -Fill '#FFFFFF' -Track '#D84315'
  # 进度条左|右锚定：左右留白各 12px（第3行，避开第1行标题/第2行徽标与磁盘信息），缩小时拉伸
  $script:DiskBar.Location = New-Object System.Drawing.Point(12, 73)
  $script:DiskBar.Size = New-Object System.Drawing.Size(1100, 18)
  $script:DiskBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $script:DiskBar.Style = 'Continuous'
  $banner.Controls.Add($script:DiskBar)

  $script:BtnScan = New-ModernButton
  $script:BtnScan.Text = '立即重新扫描'
  $script:BtnScan.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Secondary)
  $script:BtnScan.ForeColor = [System.Drawing.Color]::White
  $script:BtnScan.FlatStyle = 'Flat'
  $script:BtnScan.Location = New-Object System.Drawing.Point(820, 12)
  $script:BtnScan.Size = New-Object System.Drawing.Size(110, 30)
  $script:BtnScan.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $banner.Controls.Add($script:BtnScan)

  $btnClearCache = New-ModernButton
  $btnClearCache.Text = '清空扫描缓存'
  $btnClearCache.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Secondary)
  $btnClearCache.ForeColor = [System.Drawing.Color]::White
  $btnClearCache.FlatStyle = 'Flat'
  $btnClearCache.Location = New-Object System.Drawing.Point(930, 12)
  $btnClearCache.Size = New-Object System.Drawing.Size(110, 30)
  $btnClearCache.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $banner.Controls.Add($btnClearCache)

  $script:BtnCancelScan = New-ModernButton
  $script:BtnCancelScan.Text = '取消扫描'
  $script:BtnCancelScan.BackColor = [System.Drawing.Color]::Gray
  $script:BtnCancelScan.ForeColor = [System.Drawing.Color]::White
  $script:BtnCancelScan.FlatStyle = 'Flat'
  $script:BtnCancelScan.Location = New-Object System.Drawing.Point(1050, 12)
  $script:BtnCancelScan.Size = New-Object System.Drawing.Size(90, 30)
  $script:BtnCancelScan.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $script:BtnCancelScan.Enabled = $false
  $banner.Controls.Add($script:BtnCancelScan)

  # ============ 底部日志 ============
  $script:LogBox = New-Object System.Windows.Forms.RichTextBox
  $script:LogBox.Dock = 'Bottom'
  $script:LogBox.Height = 150
  $script:LogBox.ReadOnly = $true
  $script:LogBox.BackColor = [System.Drawing.Color]::White
  $script:LogBox.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
  $script:LogBox.BorderStyle = 'FixedSingle'

  function script:Log-Line {
    param([string]$Msg)
    try {
      $script:LogBox.AppendText((Get-Date -Format 'HH:mm:ss') + '  ' + $Msg + "`r`n")
      $script:LogBox.SelectionStart = $script:LogBox.TextLength
      $script:LogBox.ScrollToCaret()
    } catch { }
    Write-CleanLog $Msg
  }

  # ============ 主 TabControl ============
  $tabs = New-Object System.Windows.Forms.TabControl
  $tabs.Dock = 'Fill'
  # 先按设计宽度设置：其下所有 TabPage 在加入前都能按真实宽度布局，锚定子控件不会按默认 200 宽算错
  $tabs.Width = $f.ClientSize.Width
  # 自绘页签头：选中页白底 + 顶部橙色下划线高亮，未选中浅橙灰字（Win11 风格）
  $tabs.DrawMode = 'OwnerDrawFixed'
  $tabs.SizeMode = 'Fixed'
  $tabs.ItemSize = New-Object System.Drawing.Size(112, 32)
  $tabs.add_DrawItem({
    param($s, $e)
    $tc = [System.Windows.Forms.TabControl]$s
    $idx = $e.Index
    $rect = $tc.GetTabRect($idx)
    $sel = ($idx -eq $tc.SelectedIndex)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $back = if ($sel) { [System.Drawing.Color]::White } else { [System.Drawing.ColorTranslator]::FromHtml('#FBE7CC') }
    $brush = New-Object System.Drawing.SolidBrush($back)
    $g.FillRectangle($brush, $rect)
    $brush.Dispose()
    if ($sel) {
      $barBrush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary))
      $g.FillRectangle($barBrush, $rect.X, $rect.Y + 2, $rect.Width, 3)
      $barBrush.Dispose()
    }
    $txtColor = if ($sel) { [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary) } else { [System.Drawing.ColorTranslator]::FromHtml('#9E9E9E') }
    $font = if ($sel) { New-Object System.Drawing.Font($script:Theme.FontUi, 10, [System.Drawing.FontStyle]::Bold) } else { New-Object System.Drawing.Font($script:Theme.FontUi, 10) }
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $textBrush = New-Object System.Drawing.SolidBrush($txtColor)
    $rectF = New-Object System.Drawing.RectangleF($rect.X, $rect.Y, $rect.Width, $rect.Height)
    $g.DrawString($tc.TabPages[$idx].Text, $font, $textBrush, $rectF, $fmt)
    $textBrush.Dispose(); $fmt.Dispose(); $font.Dispose()
  })

  # ===== Tab1 缓存清理 =====
  $tabClean = New-Object System.Windows.Forms.TabPage
  $tabClean.Text = '缓存清理'
  $tabClean.Width = $f.ClientSize.Width
  $tabClean.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Bg)

  # 底部操作条（先加入 Dock，占位）
  $actionBar = New-Object System.Windows.Forms.Panel
  $actionBar.Dock = 'Bottom'
  $actionBar.Height = 140
  # 先按设计宽度设置：右锚定/拉伸子控件首次布局时按真实右缘计算
  $actionBar.Width = $f.ClientSize.Width
  $actionBar.BackColor = [System.Drawing.Color]::White

  $script:TotalLabel = New-Object System.Windows.Forms.Label
  $script:TotalLabel.Text = '合计可释放: 0 B'
  $script:TotalLabel.Font = New-Object System.Drawing.Font($script:Theme.FontUi,13, [System.Drawing.FontStyle]::Bold)
  $script:TotalLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $script:TotalLabel.Location = New-Object System.Drawing.Point(14, 12)
  $script:TotalLabel.AutoSize = $true
  $actionBar.Controls.Add($script:TotalLabel)

  $btnAll = New-ModernButton
  $btnAll.Text = '全选'
  $btnAll.Location = New-Object System.Drawing.Point(12, 52)
  $btnAll.Size = New-Object System.Drawing.Size(72, 30)
  $actionBar.Controls.Add($btnAll)

  $btnNone = New-ModernButton
  $btnNone.Text = '全不选'
  $btnNone.Location = New-Object System.Drawing.Point(90, 52)
  $btnNone.Size = New-Object System.Drawing.Size(72, 30)
  $actionBar.Controls.Add($btnNone)

  $btnLow = New-ModernButton
  $btnLow.Text = '仅低风险'
  $btnLow.Location = New-Object System.Drawing.Point(168, 52)
  $btnLow.Size = New-Object System.Drawing.Size(88, 30)
  $actionBar.Controls.Add($btnLow)

  $btnSafe = New-ModernButton
  $btnSafe.Text = '一键清理安全项'
  $btnSafe.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Green)
  $btnSafe.ForeColor = [System.Drawing.Color]::White
  $btnSafe.FlatStyle = 'Flat'
  $btnSafe.Location = New-Object System.Drawing.Point(262, 52)
  $btnSafe.Size = New-Object System.Drawing.Size(120, 30)
  $actionBar.Controls.Add($btnSafe)

  $rbRecycle = New-Object System.Windows.Forms.RadioButton
  $rbRecycle.Text = '移到回收站 (可恢复)'
  $rbRecycle.Checked = $true
  $rbRecycle.Location = New-Object System.Drawing.Point(250, 12)
  $rbRecycle.AutoSize = $true
  $actionBar.Controls.Add($rbRecycle)

  $script:RbPermanent = New-Object System.Windows.Forms.RadioButton
  $script:RbPermanent.Text = '永久删除 (不可恢复)'
  $script:RbPermanent.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Red)
  $script:RbPermanent.Location = New-Object System.Drawing.Point(430, 12)
  $script:RbPermanent.AutoSize = $true
  $actionBar.Controls.Add($script:RbPermanent)

  $script:BtnClean = New-ModernButton
  $script:BtnClean.Text = '开始清理'
  $script:BtnClean.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $script:BtnClean.ForeColor = [System.Drawing.Color]::White
  $script:BtnClean.Font = New-Object System.Drawing.Font($script:Theme.FontUi,12, [System.Drawing.FontStyle]::Bold)
  $script:BtnClean.FlatStyle = 'Flat'
  $script:BtnClean.Location = New-Object System.Drawing.Point(940, 12)
  $script:BtnClean.Size = New-Object System.Drawing.Size(140, 56)
  $script:BtnClean.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $actionBar.Controls.Add($script:BtnClean)

  $script:BtnCancelClean = New-ModernButton
  $script:BtnCancelClean.Text = '取消'
  $script:BtnCancelClean.Location = New-Object System.Drawing.Point(860, 12)
  $script:BtnCancelClean.Size = New-Object System.Drawing.Size(70, 56)
  $script:BtnCancelClean.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $script:BtnCancelClean.Enabled = $false
  $actionBar.Controls.Add($script:BtnCancelClean)

  $script:CleanBar = New-ModernProgressBar
  # 进度条左|右锚定：左右留白各 12px（第3行），缩小时拉伸
  $script:CleanBar.Location = New-Object System.Drawing.Point(12, 122)
  $script:CleanBar.Size = New-Object System.Drawing.Size(1100, 16)
  $script:CleanBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $actionBar.Controls.Add($script:CleanBar)

  $script:CleanStatus = New-Object System.Windows.Forms.Label
  $script:CleanStatus.Text = '就绪'
  $script:CleanStatus.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $script:CleanStatus.Location = New-Object System.Drawing.Point(430, 100)
  $script:CleanStatus.AutoSize = $true
  $actionBar.Controls.Add($script:CleanStatus)

  # 右侧详情面板
  $detailPanel = New-Object DiskCleaner.CardPanel
  $detailPanel.Dock = 'Right'
  $detailPanel.Width = 260
  $detailPanel.BackColor = [System.Drawing.Color]::White
  $detailPanel.Radius = 6

  $script:DetailTitle = New-Object System.Windows.Forms.Label
  $script:DetailTitle.Text = '项目说明'
  $script:DetailTitle.Font = New-Object System.Drawing.Font($script:Theme.FontUi,11, [System.Drawing.FontStyle]::Bold)
  $script:DetailTitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $script:DetailTitle.Location = New-Object System.Drawing.Point(12, 10)
  $script:DetailTitle.AutoSize = $true
  $detailPanel.Controls.Add($script:DetailTitle)

  $script:DetailName = New-Object System.Windows.Forms.Label
  $script:DetailName.Text = '（选择左侧清理项）'
  $script:DetailName.Font = New-Object System.Drawing.Font($script:Theme.FontUi,10, [System.Drawing.FontStyle]::Bold)
  $script:DetailName.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $script:DetailName.Location = New-Object System.Drawing.Point(12, 40)
  $script:DetailName.MaximumSize = New-Object System.Drawing.Size(236, 0)
  $script:DetailName.AutoSize = $true
  $detailPanel.Controls.Add($script:DetailName)

  $script:DetailRisk = New-Object System.Windows.Forms.Label
  $script:DetailRisk.Text = ''
  $script:DetailRisk.Font = New-Object System.Drawing.Font($script:Theme.FontUi,10, [System.Drawing.FontStyle]::Bold)
  $script:DetailRisk.Location = New-Object System.Drawing.Point(12, 68)
  $script:DetailRisk.AutoSize = $true
  $detailPanel.Controls.Add($script:DetailRisk)

  $script:DetailDesc = New-Object System.Windows.Forms.Label
  $script:DetailDesc.Text = ''
  $script:DetailDesc.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $script:DetailDesc.Location = New-Object System.Drawing.Point(12, 96)
  $script:DetailDesc.MaximumSize = New-Object System.Drawing.Size(236, 0)
  $script:DetailDesc.AutoSize = $true
  $detailPanel.Controls.Add($script:DetailDesc)

  $script:DetailPath = New-Object System.Windows.Forms.Label
  $script:DetailPath.Text = ''
  $script:DetailPath.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Disabled)
  $script:DetailPath.Font = New-Object System.Drawing.Font('Consolas', 8)
  $script:DetailPath.Location = New-Object System.Drawing.Point(12, 190)
  $script:DetailPath.MaximumSize = New-Object System.Drawing.Size(236, 0)
  $script:DetailPath.AutoSize = $true
  $detailPanel.Controls.Add($script:DetailPath)

  # 清理项列表（最后加入 Dock，占满剩余空间）
  $script:MainListView = New-Object System.Windows.Forms.ListView
  $script:MainListView.Dock = 'Fill'
  $script:MainListView.View = 'Details'
  $script:MainListView.CheckBoxes = $true
  $script:MainListView.FullRowSelect = $true
  $script:MainListView.GridLines = $false
  $script:MainListView.HideSelection = $false
  $script:MainListView.UseCompatibleStateImageBehavior = $false
  $null = $script:MainListView.Columns.Add('名称', 300)
  $null = $script:MainListView.Columns.Add('大小', 100)
  $null = $script:MainListView.Columns.Add('风险', 80)
  $null = $script:MainListView.Columns.Add('说明', 480)

  $tabClean.Controls.Add($actionBar)
  $tabClean.Controls.Add($detailPanel)
  $tabClean.Controls.Add($script:MainListView)
  $tabs.Controls.Add($tabClean)

  # ===== Tab2-7 附加功能页 =====
  $tabs.Controls.Add((New-SpacePage))
  $tabs.Controls.Add((New-LargeFilesPage))
  $tabs.Controls.Add((New-SoftwarePage))
  $tabs.Controls.Add((New-DupeFilesPage))
  $tabs.Controls.Add((New-RestorePage))
  $tabs.Controls.Add((New-StartupPage))

  $f.Controls.Add($banner)
  $f.Controls.Add($script:LogBox)
  $f.Controls.Add($tabs)

  # ============ 逻辑函数 ============
  $script:SuppressPrompt = $false

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

  function script:Update-Total {
    $total = 0L
    foreach ($li in $script:MainListView.Items) {
      if ($li.Checked -and $li.Tag) { $total += [long]$li.Tag.Size }
    }
    $script:TotalLabel.Text = '合计可释放: ' + (Format-Bytes $total)
  }

  # ===== 扫描 worker =====
  $script:ScanWorker = New-Object System.ComponentModel.BackgroundWorker
  $script:ScanWorker.WorkerReportsProgress = $true
  $script:ScanWorker.WorkerSupportsCancellation = $true
  $scanDoWork = {
    param($s, $e)
    $items = Load-CleanupItems
    $rows = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($it in $items) {
      if ($s.CancellationPending) { $e.Cancel = $true; return }
      $size = Get-ItemSize $it
      $rows.Add([pscustomobject]@{ Item = $it; Size = $size })
      $n++
      $s.ReportProgress([int](100.0 * $n / $items.Count), $it.name)
    }
    $e.Result = @{ Rows = $rows }
  }
  Register-WorkerBody -Worker $script:ScanWorker -Name 'Scan' -ScriptBlock $scanDoWork
  $script:ScanWorker.add_ProgressChanged({
    param($s, $e)
    $script:DiskBar.Value = [Math]::Min(100, $e.ProgressPercentage)
    $script:DiskInfo.Text = ('扫描中... ' + [string]$e.UserState + '  (' + $e.ProgressPercentage + '%)')
  })
  $script:ScanWorker.add_RunWorkerCompleted({
    param($s, $e)
    $script:BtnScan.Enabled = $true
    $script:BtnCancelScan.Enabled = $false
    if ($e.Error) {
      $script:DiskInfo.Text = '扫描出错'
      Log-Line ('扫描出错: ' + $e.Error.Message)
      return
    }
    if ($e.Cancelled) {
      Log-Line '扫描已取消'
      $script:DiskInfo.Text = '扫描已取消'
      return
    }
    $script:MainListView.BeginUpdate()
    $script:MainListView.Items.Clear()
    $script:MainListView.Groups.Clear()
    $groups = @{}
    foreach ($row in $e.Result.Rows) {
      $it = $row.Item; $size = [long]$row.Size
      $li = [System.Windows.Forms.ListViewItem]::new([string[]]@($it.name, (Format-Bytes $size), (Get-RiskText $it.risk), $it.desc))
      $li.Tag = [pscustomobject]@{ Item = $it; Size = $size }
      $li.ForeColor = [System.Drawing.ColorTranslator]::FromHtml((Get-RiskColor $it.risk))
      $li.BackColor = [System.Drawing.ColorTranslator]::FromHtml((Get-RiskBackColor $it.risk))
      $catKey = switch ($it.category) {
        'system'  { '系统' }
        'browser' { '浏览器' }
        'dev'     { '开发工具' }
        default   { '常用软件' }
      }
      if (-not $groups.ContainsKey($catKey)) {
        $g = New-Object System.Windows.Forms.ListViewGroup($catKey)
        $script:MainListView.Groups.Add($g)
        $groups[$catKey] = $g
      }
      $li.Group = $groups[$catKey]
      $li.Checked = [bool]$it.defaultChecked
      $null = $script:MainListView.Items.Add($li)
    }
    $script:MainListView.EndUpdate()
    Save-SizeCache
    Update-Total
    Refresh-DiskInfo
    Log-Line ('扫描完成: 共 ' + $script:MainListView.Items.Count + ' 项清理目标')
  })

  function script:Start-Scan {
    $script:BtnScan.Enabled = $false
    $script:BtnCancelScan.Enabled = $true
    $script:MainListView.Items.Clear()
    $script:MainListView.Groups.Clear()
    Update-Total
    Log-Line '开始扫描清理项大小（未缓存项首次较慢）...'
    $script:ScanWorker.RunWorkerAsync()
  }

  # ===== 清理 worker =====
  $script:CleanWorker = New-Object System.ComponentModel.BackgroundWorker
  $script:CleanWorker.WorkerSupportsCancellation = $true
  $script:CleanWorker.WorkerReportsProgress = $true
  $cleanDoWork = {
    param($s, $e)
    $arg = $e.Argument
    $mode = $arg.Mode
    $totalPlanned = 0L; $totalReleased = 0L; $skippedTotal = 0; $done = 0
    foreach ($it in $arg.Items) {
      if ($s.CancellationPending) { $e.Cancel = $true; break }
      $planned = Get-ItemSize $it -Force
      $r = Invoke-SafeDelete $it $mode
      $totalPlanned += [long]$planned
      $totalReleased += [long]$r.Released
      $skippedTotal += [int]$r.Skipped
      $done++
      $s.ReportProgress([int](100.0 * $done / $arg.Items.Count), ('{0}  释放 {1}' -f $it.name, (Format-Bytes $r.Released)))
    }
    $e.Result = @{ Planned = $totalPlanned; Released = $totalReleased; Skipped = $skippedTotal }
  }
  Register-WorkerBody -Worker $script:CleanWorker -Name 'Clean' -ScriptBlock $cleanDoWork
  $script:CleanWorker.add_ProgressChanged({
    param($s, $e)
    $script:CleanBar.Value = [Math]::Min(100, $e.ProgressPercentage)
    $st = [string]$e.UserState
    if ($st.Length -gt 32) { $st = $st.Substring(0, 32) + '...' }
    $script:CleanStatus.Text = '清理中... ' + $st
    Log-Line ('清理: ' + [string]$e.UserState)
  })
  $script:CleanWorker.add_RunWorkerCompleted({
    param($s, $e)
    $script:CleanBar.Value = 0
    $script:BtnClean.Enabled = $true
    $script:BtnCancelClean.Enabled = $false
    if ($e.Error) {
      $script:CleanStatus.Text = '清理出错'
      Log-Line ('清理出错: ' + $e.Error.Message)
      return
    }
    if ($e.Cancelled) {
      $script:CleanStatus.Text = '已取消'
      Log-Line '清理已取消（已完成部分保留）'
    } else {
      $res = $e.Result
      $script:CleanStatus.Text = '清理完成'
      Log-Line ('清理完成: 计划释放 ' + (Format-Bytes $res.Planned) + ' / 实际释放 ' + (Format-Bytes $res.Released) + ' / 跳过 ' + $res.Skipped)
      try {
        [System.Windows.Forms.MessageBox]::Show(
          ('清理完成' + "`r`n`r`n计划释放: {0}`r`n实际释放: {1}`r`n跳过占用/受保护: {2}" -f (Format-Bytes $res.Planned), (Format-Bytes $res.Released), $res.Skipped),
          '清理结果', 'OK', 'Information')
      } catch { }
    }
    Refresh-DiskInfo
    Update-Total
  })

  # ============ 事件 ============
  $script:MainListView.add_ItemCheck({
    param($s, $e)
    if ($script:SuppressPrompt) { return }
    if ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked) {
      $li = $script:MainListView.Items[$e.Index]
      if ($li.Tag -and $li.Tag.Item.risk -eq 'red') {
        $r = [System.Windows.Forms.MessageBox]::Show(('「' + $li.Text + '」风险较高，可能涉及个人数据。确定勾选清理吗？'), '风险确认', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.NewValue = [System.Windows.Forms.CheckState]::Unchecked }
      }
    }
  })
  $script:MainListView.add_ItemChecked({ param($s, $e) Update-Total })
  $script:MainListView.add_SelectedIndexChanged({
    if ($script:MainListView.SelectedItems.Count -gt 0) {
      $li = $script:MainListView.SelectedItems[0]
      if ($li.Tag) {
        $it = $li.Tag.Item
        $script:DetailName.Text = $it.name
        $script:DetailRisk.Text = '风险: ' + (Get-RiskText $it.risk)
        $script:DetailRisk.ForeColor = [System.Drawing.ColorTranslator]::FromHtml((Get-RiskColor $it.risk))
        $script:DetailDesc.Text = $it.desc
        $script:DetailPath.Text = ($it.paths -join "`r`n")
      }
    }
  })

  $script:BtnScan.add_Click({ Start-Scan })
  $btnClearCache.add_Click({
    $script:SizeCache = @{}
    $p = Join-Path $script:DataDir 'size-cache.json'
    if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    Log-Line '已清空扫描缓存，下次扫描全量实测'
    Start-Scan
  })
  $script:BtnCancelScan.add_Click({ $script:ScanWorker.CancelAsync() })

  $btnAll.add_Click({
    $script:SuppressPrompt = $true
    try { foreach ($li in $script:MainListView.Items) { $li.Checked = $true } } finally { $script:SuppressPrompt = $false }
  })
  $btnNone.add_Click({
    $script:SuppressPrompt = $true
    try { foreach ($li in $script:MainListView.Items) { $li.Checked = $false } } finally { $script:SuppressPrompt = $false }
  })
  $btnLow.add_Click({
    $script:SuppressPrompt = $true
    try { foreach ($li in $script:MainListView.Items) { $li.Checked = ($li.Tag -and $li.Tag.Item.risk -eq 'green') } } finally { $script:SuppressPrompt = $false }
  })
  $btnSafe.add_Click({
    # 一键清理安全项 = 绿 + 黄（排除红）
    $script:SuppressPrompt = $true
    try { foreach ($li in $script:MainListView.Items) { $li.Checked = ($li.Tag -and $li.Tag.Item.risk -ne 'red') } } finally { $script:SuppressPrompt = $false }
  })

  $script:RbPermanent.add_CheckedChanged({
    if ($script:RbPermanent.Checked) {
      $script:Settings.DeleteMode = 'Permanent'
      Save-Settings
      try {
        [System.Windows.Forms.MessageBox]::Show('你已切换到【永久删除】模式：清理后文件无法从回收站恢复，请谨慎操作！', '警告', 'OK', 'Warning')
      } catch { }
    } else {
      $script:Settings.DeleteMode = 'Recycle'
      Save-Settings
    }
  })

  $script:BtnClean.add_Click({
    $checked = @($script:MainListView.Items | Where-Object { $_.Checked -and $_.Tag } | ForEach-Object { $_.Tag.Item })
    if ($checked.Count -eq 0) {
      try { [System.Windows.Forms.MessageBox]::Show('请先勾选要清理的项目。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $mode = if ($script:RbPermanent.Checked) { 'Permanent' } else { 'Recycle' }
    if ($mode -eq 'Permanent') {
      $r = [System.Windows.Forms.MessageBox]::Show('你选择了【永久删除】！文件将无法从回收站恢复。确认继续？', '危险操作', 'YesNo', 'Warning')
      if ($r -ne 'Yes') { return }
    }
    $reds = @($checked | Where-Object { $_.risk -eq 'red' })
    if ($reds.Count -gt 0) {
      $names = ($reds | ForEach-Object { $_.name }) -join '、'
      $r = [System.Windows.Forms.MessageBox]::Show(('以下高风险项将被清理（可能影响个人数据）：' + $names + "`r`n`r`n确认继续？"), '高风险确认', 'YesNo', 'Warning')
      if ($r -ne 'Yes') { return }
    }
    $script:BtnClean.Enabled = $false
    $script:BtnCancelClean.Enabled = $true
    $script:CleanBar.Value = 0
    $script:CleanStatus.Text = '清理中...'
    $modeText = if ($mode -eq 'Permanent') { '永久删除' } else { '回收站' }
    Log-Line ('开始清理: ' + $checked.Count + ' 项, 模式=' + $modeText)
    $script:CleanWorker.RunWorkerAsync(@{ Items = $checked; Mode = $mode })
  })
  $script:BtnCancelClean.add_Click({ $script:CleanWorker.CancelAsync() })

  # 恢复上次删除模式
  Load-Settings
  if ($script:Settings.DeleteMode -eq 'Permanent') { $script:RbPermanent.Checked = $true }

  $f.add_Shown({
    Refresh-DiskInfo
    Log-Line '工具已就绪。勾选要清理的项目后点击「开始清理」；删除默认进回收站可恢复。'
    Start-Scan
  })

  return $f
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
$form = New-MainWindow
[System.Windows.Forms.Application]::Run($form)
#endregion
