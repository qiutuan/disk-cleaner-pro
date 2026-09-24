# ============================================================
#  DiskCleanerPro - C 盘智能清理工具
#  PowerShell + WPF（Fluent 浅色主题，纯代码绘制，无图片资源）
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
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic   # 回收站删除 API
Add-Type -AssemblyName PresentationFramework    # WPF 界面（v1.3.0）
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
#endregion

#region 全局异常兜底（程序绝不闪退）
[AppDomain]::CurrentDomain.add_UnhandledException({
  param($s, $e)
  Write-CleanLog ("UnhandledException: " + $e.ExceptionObject.ToString())
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

function Add-WpfSortHeader {
  # WPF 表头点击排序助手（WinForms 时代的 Register-ColumnSort/LvSorter 已随 v1.3.0 移除）。
  # 点击排序列在 升序↔降序 间切换；排序参数打包进表头自身 Tag，点击时从事件参数读取，
  # 不依赖函数局部变量闭包（WPF 事件回调拿不到定义时所在函数的局部作用域，只能经 $script: / Tag 传参）。
  #  - $Header  : 表头 TextBlock（挂 MouseLeftButtonDown）
  #  - $VarName : script 作用域中保存"当前行数据数组"的变量名（排序后写回）
  #  - $Key     : scriptblock，输入一行数据返回排序键（数字键自动按数值排；字符串/日期按文本排）
  #  - $Render  : scriptblock，无参；按当前行数组重渲染列表
  param(
    [System.Windows.Controls.TextBlock]$Header,
    [string]$VarName,
    [scriptblock]$Key,
    [scriptblock]$Render
  )
  $Header.Cursor = [System.Windows.Input.Cursors]::Hand
  $Header.ToolTip = '点击排序'
  $Header.Tag = [pscustomobject]@{ State = 0; Var = $VarName; Key = $Key; Render = $Render }
  $Header.Add_MouseLeftButtonDown({
    param($s, $e)
    try {
      $cfg = $s.Tag
      $rows = @((Get-Variable -Name $cfg.Var -Scope Script -ErrorAction SilentlyContinue).Value)
      if ($rows.Count -le 1) { return }
      # Sort-Object 对 -Property 脚本块在自己的会话状态里求值，拿不到本回调的局部变量 $cfg，
      # 排序键经 $script:SortKey 中转（脚本作用域对 cmdlet 调用的脚本块始终可见）。
      $script:SortKey = $cfg.Key
      $asc = ($cfg.State -ne 1)
      $sorted = if ($asc) {
        @($rows | Sort-Object -Property { & $script:SortKey $_ })
      } else {
        @($rows | Sort-Object -Property { & $script:SortKey $_ } -Descending)
      }
      Set-Variable -Name $cfg.Var -Scope Script -Value $sorted
      $cfg.State = if ($asc) { 1 } else { -1 }
      & ($cfg.Render)
    } catch { Log-Line ('表头排序出错: ' + $_.Exception.Message) }
  })
}

function New-CleanPage {
  # ===== 布局：左列表 | 右详情 260px =====
  $g = New-Object System.Windows.Controls.Grid
  $null = $g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $colD = New-Object System.Windows.Controls.ColumnDefinition
  $colD.Width = [System.Windows.GridLength]::new(260)
  $null = $g.ColumnDefinitions.Add($colD)

  # 左：分组列表（ScrollViewer > StackPanel）
  $scroll = New-Object System.Windows.Controls.ScrollViewer
  $scroll.VerticalScrollBarVisibility = 'Auto'
  $scroll.HorizontalScrollBarVisibility = 'Disabled'
  $scroll.Background = (New-WpfBrush '#FFFFFF')
  $script:CleanList = New-Object System.Windows.Controls.StackPanel
  $scroll.Content = $script:CleanList
  $null = $g.Children.Add($scroll)

  # 右：详情面板
  $detail = New-Object System.Windows.Controls.Border
  $detail.Background = (New-WpfBrush '#FFFFFF')
  $detail.BorderBrush = (New-WpfBrush $script:Theme.CardLine)
  $detail.BorderThickness = (New-WpfThickness 1 0 0 0)
  $dp = New-Object System.Windows.Controls.StackPanel
  $dp.Margin = (New-WpfThickness 16 14 16 14)
  $script:DetailTitle = New-Object System.Windows.Controls.TextBlock
  $script:DetailTitle.Text = '项目说明'
  $script:DetailTitle.FontSize = 15
  $script:DetailTitle.FontWeight = [System.Windows.FontWeights]::Bold
  $script:DetailTitle.Foreground = (New-WpfBrush $script:Theme.Primary)
  $script:DetailName = New-Object System.Windows.Controls.TextBlock
  $script:DetailName.Text = '（选择左侧清理项）'
  $script:DetailName.FontSize = 14
  $script:DetailName.FontWeight = [System.Windows.FontWeights]::Bold
  $script:DetailName.TextWrapping = 'Wrap'
  $script:DetailName.Margin = (New-WpfThickness 0 14 0 0)
  $script:DetailRisk = New-Object System.Windows.Controls.TextBlock
  $script:DetailRisk.Text = ''
  $script:DetailRisk.FontSize = 13
  $script:DetailRisk.FontWeight = [System.Windows.FontWeights]::Bold
  $script:DetailRisk.Margin = (New-WpfThickness 0 10 0 0)
  $script:DetailDesc = New-Object System.Windows.Controls.TextBlock
  $script:DetailDesc.Text = ''
  $script:DetailDesc.TextWrapping = 'Wrap'
  $script:DetailDesc.FontSize = 13
  $script:DetailDesc.Margin = (New-WpfThickness 0 12 0 0)
  $script:DetailPath = New-Object System.Windows.Controls.TextBlock
  $script:DetailPath.Text = ''
  $script:DetailPath.TextWrapping = 'Wrap'
  $script:DetailPath.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
  $script:DetailPath.FontSize = 11
  $script:DetailPath.Foreground = (New-WpfBrush $script:Theme.Disabled)
  $script:DetailPath.Margin = (New-WpfThickness 0 14 0 0)
  $null = $dp.Children.Add($script:DetailTitle)
  $null = $dp.Children.Add($script:DetailName)
  $null = $dp.Children.Add($script:DetailRisk)
  $null = $dp.Children.Add($script:DetailDesc)
  $null = $dp.Children.Add($script:DetailPath)
  $detail.Child = $dp
  [System.Windows.Controls.Grid]::SetColumn($detail, 1)
  $null = $g.Children.Add($detail)

  # ===== 状态 =====
  $script:SuppressPrompt = $false
  $script:CleanCheckboxes = @()

  # ===== 行构造助手（勾选框 / 风险色 / 悬停 / 详情） =====
  function script:New-CleanRow {
    param($It, [long]$Size)
    $row = New-Object System.Windows.Controls.Border
    $row.Tag = [pscustomobject]@{ Item = $It; Size = $Size }
    $row.Background = (New-WpfBrush '#FFFFFF')
    $row.BorderBrush = (New-WpfBrush '#F0F1F3')
    $row.BorderThickness = (New-WpfThickness 0 0 0 1)
    $row.Padding = (New-WpfThickness 12 6 12 6)
    $row.Cursor = [System.Windows.Input.Cursors]::Hand
    $ig = New-Object System.Windows.Controls.Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::new(26)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(320)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::new(90)
    $null = $ig.ColumnDefinitions.Add($c0); $null = $ig.ColumnDefinitions.Add($c1)
    $null = $ig.ColumnDefinitions.Add($c2); $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Tag = $row.Tag
    $cb.VerticalAlignment = 'Center'
    $cb.IsChecked = [bool]$It.defaultChecked
    $cb.Add_Checked({
      param($s, $e)
      if ($script:SuppressPrompt) { return }
      if ($s.Tag -and $s.Tag.Item.risk -eq 'red') {
        $r = [System.Windows.MessageBox]::Show(('「' + $s.Tag.Item.name + '」风险较高，可能涉及个人数据。确定勾选清理吗？'), '风险确认', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($r -ne [System.Windows.MessageBoxResult]::Yes) { $s.IsChecked = $false; return }
      }
      Update-Total
    })
    $cb.Add_Unchecked({ param($s, $e) Update-Total })
    $null = $ig.Children.Add($cb)

    $nm = New-Object System.Windows.Controls.TextBlock
    $nm.Text = $It.name
    $nm.VerticalAlignment = 'Center'
    $nm.FontSize = 13
    $nm.TextTrimming = 'CharacterEllipsis'
    $nm.Foreground = (New-WpfBrush (Get-RiskColor $It.risk))
    [System.Windows.Controls.Grid]::SetColumn($nm, 1)
    $null = $ig.Children.Add($nm)

    $sz = New-Object System.Windows.Controls.TextBlock
    $sz.Text = Format-Bytes $Size
    $sz.HorizontalAlignment = 'Right'
    $sz.VerticalAlignment = 'Center'
    $sz.FontSize = 12
    $sz.Foreground = (New-WpfBrush $script:Theme.SubText)
    [System.Windows.Controls.Grid]::SetColumn($sz, 2)
    $null = $ig.Children.Add($sz)

    $bt = New-Object System.Windows.Controls.TextBlock
    $bt.Text = Get-RiskText $It.risk
    $bt.FontSize = 11
    $bt.Foreground = (New-WpfBrush (Get-RiskColor $It.risk))
    $badge = New-Object System.Windows.Controls.Border
    $badge.Background = (New-WpfBrush (Get-RiskBackColor $It.risk))
    $badge.CornerRadius = [System.Windows.CornerRadius]::new(3)
    $badge.Padding = (New-WpfThickness 7 1 7 1)
    $badge.HorizontalAlignment = 'Left'
    $badge.VerticalAlignment = 'Center'
    $badge.Child = $bt
    [System.Windows.Controls.Grid]::SetColumn($badge, 3)
    $null = $ig.Children.Add($badge)

    $row.Child = $ig
    $row.Add_MouseEnter({ param($s, $e) try { $s.Background = (New-WpfBrush '#F4F5F7') } catch { } })
    $row.Add_MouseLeave({ param($s, $e) try { $s.Background = (New-WpfBrush '#FFFFFF') } catch { } })
    $row.Add_MouseLeftButtonUp({
      param($s, $e)
      try {
        if ($s.Tag) {
          $it = $s.Tag.Item
          $script:DetailName.Text = $it.name
          $script:DetailRisk.Text = '风险: ' + (Get-RiskText $it.risk)
          $script:DetailRisk.Foreground = (New-WpfBrush (Get-RiskColor $it.risk))
          $script:DetailDesc.Text = $it.desc
          $script:DetailPath.Text = ($it.paths -join "`r`n")
        }
      } catch { }
    })
    $script:CleanCheckboxes += $cb
    return $row
  }

  # ===== 合计 =====
  function script:Update-Total {
    $total = 0L
    foreach ($cb in $script:CleanCheckboxes) {
      if ($cb.IsChecked -and $cb.Tag) { $total += [long]$cb.Tag.Size }
    }
    $script:TotalLabel.Text = '合计可释放: ' + (Format-Bytes $total)
  }

  # ===== 扫描 worker（Register-WorkerBody 桥接 runspace，与旧版同构） =====
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
    try {
      $script:DiskBar.Value = [Math]::Min(100, $e.ProgressPercentage)
      $script:DiskInfo.Text = ('扫描中... ' + [string]$e.UserState + '  (' + $e.ProgressPercentage + '%)')
    } catch { }
  })
  $script:ScanWorker.add_RunWorkerCompleted({
    param($s, $e)
    try {
      $script:BtnScan.IsEnabled = $true
      $script:BtnCancelScan.IsEnabled = $false
      if ($e.Error) { $script:DiskInfo.Text = '扫描出错'; Log-Line ('扫描出错: ' + $e.Error.Message); return }
      if ($e.Cancelled) { Log-Line '扫描已取消'; $script:DiskInfo.Text = '扫描已取消'; return }
      # 重建分组列表
      $script:CleanList.Children.Clear()
      $script:CleanCheckboxes = @()
      $catMap = @{ system = '系统'; browser = '浏览器'; dev = '开发工具'; privacy = '隐私清理' }
      $groups = @{}
      foreach ($row in $e.Result.Rows) {
        $it = $row.Item; $size = [long]$row.Size
        $catKey = if ($catMap.ContainsKey([string]$it.category)) { $catMap[[string]$it.category] } else { '常用软件' }
        if (-not $groups.ContainsKey($catKey)) {
          $hdr = New-Object System.Windows.Controls.Border
          $hdr.Background = (New-WpfBrush '#F8F9FA')
          $hdr.Padding = (New-WpfThickness 12 6 12 6)
          $ht = New-Object System.Windows.Controls.TextBlock
          $ht.Text = $catKey
          $ht.FontSize = 12
          $ht.FontWeight = [System.Windows.FontWeights]::Bold
          $ht.Foreground = (New-WpfBrush $script:Theme.SubText)
          $hdr.Child = $ht
          $panel = New-Object System.Windows.Controls.StackPanel
          $groups[$catKey] = @{ Header = $hdr; Panel = $panel }
          $null = $script:CleanList.Children.Add($hdr)
          $null = $script:CleanList.Children.Add($panel)
        }
        $rb = New-CleanRow -It $it -Size $size
        $null = $groups[$catKey].Panel.Children.Add($rb)
      }
      Save-SizeCache
      Update-Total
      Refresh-DiskInfo
      Log-Line ('扫描完成: 共 ' + $script:CleanCheckboxes.Count + ' 项清理目标')
    } catch { Log-Line ('扫描完成处理出错: ' + $_.Exception.Message) }
  })

  function script:Start-Scan {
    $script:BtnScan.IsEnabled = $false
    $script:BtnCancelScan.IsEnabled = $true
    $script:CleanList.Children.Clear()
    $script:CleanCheckboxes = @()
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
    $cancelled = $false
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($it in $arg.Items) {
      if ($s.CancellationPending) { $cancelled = $true; break }
      $planned = Get-ItemSize $it -Force
      $r = Invoke-SafeDelete $it $mode
      $totalPlanned += [long]$planned
      $totalReleased += [long]$r.Released
      $skippedTotal += [int]$r.Skipped
      $rows.Add([pscustomobject]@{
        Name = [string]$it.name; Category = [string]$it.category; Risk = [string]$it.risk
        Size = [long]$planned; Released = [long]$r.Released; Skipped = [int]$r.Skipped
      })
      $done++
      $s.ReportProgress([int](100.0 * $done / $arg.Items.Count), ('{0}  释放 {1}' -f $it.name, (Format-Bytes $r.Released)))
    }
    # 注意：不设 $e.Cancel —— 取消标志随 Result 带回，保证"取消也导出已完成部分"
    $e.Result = @{ Planned = $totalPlanned; Released = $totalReleased; Skipped = $skippedTotal; Details = $rows; Cancelled = $cancelled }
  }
  Register-WorkerBody -Worker $script:CleanWorker -Name 'Clean' -ScriptBlock $cleanDoWork
  $script:CleanWorker.add_ProgressChanged({
    param($s, $e)
    try {
      $script:CleanBar.Value = [Math]::Min(100, $e.ProgressPercentage)
      $st = [string]$e.UserState
      if ($st.Length -gt 32) { $st = $st.Substring(0, 32) + '...' }
      $script:CleanStatus.Text = '清理中... ' + $st
      Log-Line ('清理: ' + [string]$e.UserState)
    } catch { }
  })
  $script:CleanWorker.add_RunWorkerCompleted({
    param($s, $e)
    try {
      $script:CleanBar.Value = 0
      $script:BtnClean.IsEnabled = $true
      $script:BtnCancelClean.IsEnabled = $false
      if ($e.Error) { $script:CleanStatus.Text = '清理出错'; Log-Line ('清理出错: ' + $e.Error.Message); return }
      # 取消标志在 Result.Cancelled 里；Cancelled=true 时访问 e.Result 会抛异常
      try { $res = $e.Result } catch { return }
      if ($res.Cancelled) {
        $script:CleanStatus.Text = '已取消'
        Log-Line '清理已取消（已完成部分保留）'
        if ($res.Details -and $res.Details.Count -gt 0) {
          $rep2 = Export-CleanReport -Details $res.Details -Planned $res.Planned -Released $res.Released -Skipped $res.Skipped -Mode $script:Settings.DeleteMode -Note '已取消，仅含完成部分'
          if ($rep2) { Log-Line ('清理报告已导出: ' + $rep2) }
        }
      } else {
        $script:CleanStatus.Text = '清理完成'
        Log-Line ('清理完成: 计划释放 ' + (Format-Bytes $res.Planned) + ' / 实际释放 ' + (Format-Bytes $res.Released) + ' / 跳过 ' + $res.Skipped)
        $rep = Export-CleanReport -Details $res.Details -Planned $res.Planned -Released $res.Released -Skipped $res.Skipped -Mode $script:Settings.DeleteMode
        if ($rep) { Log-Line ('清理报告已导出: ' + $rep) }
        try {
          $null = [System.Windows.MessageBox]::Show(
            ('清理完成' + "`n`n计划释放: {0}`n实际释放: {1}`n跳过占用/受保护: {2}" -f (Format-Bytes $res.Planned), (Format-Bytes $res.Released), $res.Skipped),
            '清理结果', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        } catch { }
      }
      Refresh-DiskInfo
      Update-Total
    } catch { Log-Line ('清理完成处理出错: ' + $_.Exception.Message) }
  })

  return $g
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
  # 布局：工具栏 44 | 表头+列表 | 页脚 44
  $g = New-Object System.Windows.Controls.Grid
  $r0 = New-Object System.Windows.Controls.RowDefinition; $r0.Height = [System.Windows.GridLength]::new(44)
  $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = [System.Windows.GridLength]::new(44)
  $null = $g.RowDefinitions.Add($r0); $null = $g.RowDefinitions.Add($r1); $null = $g.RowDefinitions.Add($r2)

  # ===== 工具栏 =====
  $top = New-Object System.Windows.Controls.Border
  $top.Background = (New-WpfBrush '#FFFFFF')
  $top.BorderBrush = (New-WpfBrush $script:Theme.CardLine)
  $top.BorderThickness = (New-WpfThickness 0 0 0 1)
  $tg = New-Object System.Windows.Controls.Grid
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))  # auto
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))  # drive combo
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))  # prog
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))  # status
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))  # path *
  $lblD = New-Object System.Windows.Controls.TextBlock
  $lblD.Text = '磁盘:'; $lblD.VerticalAlignment = 'Center'; $lblD.Margin = (New-WpfThickness 12 0 0 0)
  $null = $tg.Children.Add($lblD)
  $script:CmbSpaceDrive = New-Object System.Windows.Controls.ComboBox
  $script:CmbSpaceDrive.Width = 66; $script:CmbSpaceDrive.VerticalAlignment = 'Center'; $script:CmbSpaceDrive.Margin = (New-WpfThickness 8 0 0 0)
  foreach ($d in (Get-FixedDrives)) { $null = $script:CmbSpaceDrive.Items.Add($d) }
  if ($script:CmbSpaceDrive.Items.Count -gt 0) { $script:CmbSpaceDrive.SelectedIndex = 0 }
  [System.Windows.Controls.Grid]::SetColumn($script:CmbSpaceDrive, 1); $null = $tg.Children.Add($script:CmbSpaceDrive)
  $script:BtnSpaceScan = New-Object System.Windows.Controls.Button
  $script:BtnSpaceScan.Content = '开始扫描'; $script:BtnSpaceScan.Margin = (New-WpfThickness 10 0 0 0)
  $script:BtnSpaceScan.Background = (New-WpfBrush $script:Theme.Primary); $script:BtnSpaceScan.Foreground = (New-WpfBrush '#FFFFFF')
  $script:BtnSpaceScan.Padding = (New-WpfThickness 12 4 12 4)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnSpaceScan, 2); $null = $tg.Children.Add($script:BtnSpaceScan)
  $script:BtnSpaceStop = New-Object System.Windows.Controls.Button
  $script:BtnSpaceStop.Content = '停止'; $script:BtnSpaceStop.IsEnabled = $false; $script:BtnSpaceStop.Margin = (New-WpfThickness 8 0 0 0)
  $script:BtnSpaceStop.Padding = (New-WpfThickness 10 4 10 4)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnSpaceStop, 3); $null = $tg.Children.Add($script:BtnSpaceStop)
  $script:BtnSpaceUp = New-Object System.Windows.Controls.Button
  $script:BtnSpaceUp.Content = '上级目录'; $script:BtnSpaceUp.IsEnabled = $false; $script:BtnSpaceUp.Margin = (New-WpfThickness 8 0 0 0)
  $script:BtnSpaceUp.Padding = (New-WpfThickness 10 4 10 4)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnSpaceUp, 4); $null = $tg.Children.Add($script:BtnSpaceUp)
  $script:ProgSpace = New-Object System.Windows.Controls.ProgressBar
  $script:ProgSpace.Width = 200; $script:ProgSpace.Height = 8; $script:ProgSpace.VerticalAlignment = 'Center'; $script:ProgSpace.Margin = (New-WpfThickness 14 0 0 0)
  $script:ProgSpace.Foreground = (New-WpfBrush $script:Theme.Primary); $script:ProgSpace.Background = (New-WpfBrush '#EEF0F2')
  [System.Windows.Controls.Grid]::SetColumn($script:ProgSpace, 5); $null = $tg.Children.Add($script:ProgSpace)
  $script:LblSpaceStatus = New-Object System.Windows.Controls.TextBlock
  $script:LblSpaceStatus.Text = '就绪'; $script:LblSpaceStatus.VerticalAlignment = 'Center'; $script:LblSpaceStatus.Margin = (New-WpfThickness 12 0 0 0)
  $script:LblSpaceStatus.Foreground = (New-WpfBrush $script:Theme.SubText); $script:LblSpaceStatus.FontSize = 12
  [System.Windows.Controls.Grid]::SetColumn($script:LblSpaceStatus, 6); $null = $tg.Children.Add($script:LblSpaceStatus)
  $script:LblSpacePath = New-Object System.Windows.Controls.TextBlock
  $script:LblSpacePath.Text = '（扫描后双击目录逐级下钻）'
  $script:LblSpacePath.VerticalAlignment = 'Center'; $script:LblSpacePath.Margin = (New-WpfThickness 16 0 12 0)
  $script:LblSpacePath.Foreground = (New-WpfBrush $script:Theme.Primary); $script:LblSpacePath.FontSize = 12
  $script:LblSpacePath.TextTrimming = 'CharacterEllipsis'
  [System.Windows.Controls.Grid]::SetColumn($script:LblSpacePath, 7); $null = $tg.Children.Add($script:LblSpacePath)
  $top.Child = $tg
  [System.Windows.Controls.Grid]::SetRow($top, 0); $null = $g.Children.Add($top)

  # ===== 表头 + 列表 =====
  $mid = New-Object System.Windows.Controls.Grid
  $mh = New-Object System.Windows.Controls.RowDefinition; $mh.Height = [System.Windows.GridLength]::new(30)
  $ml = New-Object System.Windows.Controls.RowDefinition; $ml.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $null = $mid.RowDefinitions.Add($mh); $null = $mid.RowDefinitions.Add($ml)
  $hdr = New-Object System.Windows.Controls.Border
  $hdr.Background = (New-WpfBrush '#F8F9FA'); $hdr.BorderBrush = (New-WpfBrush '#F0F1F3'); $hdr.BorderThickness = (New-WpfThickness 0 0 0 1)
  $hg = New-Object System.Windows.Controls.Grid
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(110)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[2].Width = [System.Windows.GridLength]::new(80)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[3].Width = [System.Windows.GridLength]::new(110)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[4].Width = [System.Windows.GridLength]::new(220)
  $hdrCols = @('名称', '总占用', '占比', '自身文件', '完整路径')
  for ($ci = 0; $ci -lt $hdrCols.Count; $ci++) {
    $ht = New-Object System.Windows.Controls.TextBlock
    $ht.Text = $hdrCols[$ci]; $ht.FontSize = 11; $ht.FontWeight = [System.Windows.FontWeights]::Bold
    $ht.Foreground = (New-WpfBrush $script:Theme.SubText); $ht.VerticalAlignment = 'Center'
    $ht.Margin = (New-WpfThickness 12 0 6 0)
    [System.Windows.Controls.Grid]::SetColumn($ht, $ci)
    $null = $hg.Children.Add($ht)
  }
  $hdr.Child = $hg
  [System.Windows.Controls.Grid]::SetRow($hdr, 0); $null = $mid.Children.Add($hdr)
  $scroll = New-Object System.Windows.Controls.ScrollViewer
  $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
  $scroll.Background = (New-WpfBrush '#FFFFFF')
  $script:SpaceList = New-Object System.Windows.Controls.StackPanel
  $scroll.Content = $script:SpaceList
  [System.Windows.Controls.Grid]::SetRow($scroll, 1); $null = $mid.Children.Add($scroll)
  [System.Windows.Controls.Grid]::SetRow($mid, 1); $null = $g.Children.Add($mid)

  # ===== 页脚 =====
  $foot = New-Object System.Windows.Controls.Border
  $foot.Background = (New-WpfBrush '#FFFFFF'); $foot.BorderBrush = (New-WpfBrush $script:Theme.CardLine); $foot.BorderThickness = (New-WpfThickness 0 1 0 0)
  $fg = New-Object System.Windows.Controls.Grid
  $null = $fg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $fg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $hint = New-Object System.Windows.Controls.TextBlock
  $hint.Text = '双击行进入目录；右键可打开/复制/删除到回收站。'
  $hint.VerticalAlignment = 'Center'; $hint.Margin = (New-WpfThickness 12 0 0 0); $hint.FontSize = 12
  $hint.Foreground = (New-WpfBrush $script:Theme.SubText)
  $null = $fg.Children.Add($hint)
  $script:BtnSpaceDel = New-Object System.Windows.Controls.Button
  $script:BtnSpaceDel.Content = '删除选中(回收站)'
  $script:BtnSpaceDel.Background = (New-WpfBrush $script:Theme.Red); $script:BtnSpaceDel.Foreground = (New-WpfBrush '#FFFFFF')
  $script:BtnSpaceDel.Padding = (New-WpfThickness 12 4 12 4); $script:BtnSpaceDel.HorizontalAlignment = 'Right'; $script:BtnSpaceDel.Margin = (New-WpfThickness 0 0 12 0)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnSpaceDel, 1); $null = $fg.Children.Add($script:BtnSpaceDel)
  $foot.Child = $fg
  [System.Windows.Controls.Grid]::SetRow($foot, 2); $null = $g.Children.Add($foot)

  # ===== 状态 =====
  $script:SpaceOwn = $null    # Dictionary[dir] = 直接文件字节
  $script:SpaceTotal = $null  # Dictionary[dir] = 含子孙合计字节
  $script:SpaceDir = $null    # 当前浏览目录
  $script:SpaceSel = $null    # 选中目录路径

  # ===== 行助手（5 列 + 右键菜单 + 双击下钻） =====
  function script:New-SpaceRow {
    param([string]$Path, [long]$Total, [long]$Own, [long]$DirTotal)
    $name = Split-Path $Path -Leaf
    if (-not $name) { $name = $Path }
    $pct = if ($DirTotal -gt 0) { '{0:P1}' -f ($Total / [double]$DirTotal) } else { '' }
    $col = if ($Total -gt 1GB) { $script:Theme.Red } elseif ($Total -gt 100MB) { $script:Theme.Yellow } else { $script:Theme.Green }
    $row = New-Object System.Windows.Controls.Border
    $row.Tag = $Path
    $row.Background = (New-WpfBrush '#FFFFFF')
    $row.BorderBrush = (New-WpfBrush '#F0F1F3'); $row.BorderThickness = (New-WpfThickness 0 0 0 1)
    $row.Padding = (New-WpfThickness 12 6 12 6)
    $ig = New-Object System.Windows.Controls.Grid
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(110)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[2].Width = [System.Windows.GridLength]::new(80)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[3].Width = [System.Windows.GridLength]::new(110)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[4].Width = [System.Windows.GridLength]::new(220)
    $tName = New-Object System.Windows.Controls.TextBlock
    $tName.Text = $name; $tName.FontSize = 13; $tName.VerticalAlignment = 'Center'; $tName.TextTrimming = 'CharacterEllipsis'
    $tName.Foreground = (New-WpfBrush $col)
    $null = $ig.Children.Add($tName)
    $tTot = New-Object System.Windows.Controls.TextBlock
    $tTot.Text = Format-Bytes $Total; $tTot.FontSize = 12; $tTot.VerticalAlignment = 'Center'; $tTot.HorizontalAlignment = 'Right'
    $tTot.Foreground = (New-WpfBrush $script:Theme.Text); [System.Windows.Controls.Grid]::SetColumn($tTot, 1); $null = $ig.Children.Add($tTot)
    $tPct = New-Object System.Windows.Controls.TextBlock
    $tPct.Text = $pct; $tPct.FontSize = 12; $tPct.VerticalAlignment = 'Center'; $tPct.HorizontalAlignment = 'Right'
    $tPct.Foreground = (New-WpfBrush $script:Theme.SubText); [System.Windows.Controls.Grid]::SetColumn($tPct, 2); $null = $ig.Children.Add($tPct)
    $tOwn = New-Object System.Windows.Controls.TextBlock
    $tOwn.Text = Format-Bytes $Own; $tOwn.FontSize = 12; $tOwn.VerticalAlignment = 'Center'; $tOwn.HorizontalAlignment = 'Right'
    $tOwn.Foreground = (New-WpfBrush $script:Theme.SubText); [System.Windows.Controls.Grid]::SetColumn($tOwn, 3); $null = $ig.Children.Add($tOwn)
    $tPath = New-Object System.Windows.Controls.TextBlock
    $tPath.Text = $Path; $tPath.FontSize = 11; $tPath.VerticalAlignment = 'Center'; $tPath.TextTrimming = 'CharacterEllipsis'
    $tPath.Foreground = (New-WpfBrush $script:Theme.Disabled); [System.Windows.Controls.Grid]::SetColumn($tPath, 4); $null = $ig.Children.Add($tPath)
    $row.Child = $ig
    # 悬停 / 选中
    $row.Add_MouseEnter({ param($s, $e) try { if ($s.Tag -ne $script:SpaceSel) { $s.Background = (New-WpfBrush '#F4F5F7') } } catch { } })
    $row.Add_MouseLeave({ param($s, $e) try { if ($s.Tag -ne $script:SpaceSel) { $s.Background = (New-WpfBrush '#FFFFFF') } } catch { } })
    $row.Add_MouseLeftButtonDown({
      param($s, $e)
      try {
        # Border 无 MouseDoubleClick（仅 Control 有），双击用 ClickCount==2 判定
        if ($e.ClickCount -eq 2) {
          $p = [string]$s.Tag
          if ($script:SpaceTotal -and $script:SpaceTotal.ContainsKey($p)) { Space-FillChildren $p }
          return
        }
        $script:SpaceSel = [string]$s.Tag
        foreach ($ch in $script:SpaceList.Children) {
          if ($ch -is [System.Windows.Controls.Border] -and $ch.Tag) {
            $ch.Background = (New-WpfBrush $(if ($ch.Tag -eq $script:SpaceSel) { '#EAF3FF' } else { '#FFFFFF' }))
          }
        }
      } catch { }
    })
    # 右键菜单（每行独立实例；路径经 MenuItem.Tag 传递——事件回调拿不到函数局部变量闭包）
    $menu = New-Object System.Windows.Controls.ContextMenu
    $miOpen = New-Object System.Windows.Controls.MenuItem; $miOpen.Header = '打开所在文件夹'; $miOpen.Tag = $Path
    $miOpen.Add_Click({ $p = [string]$_.Source.Tag; Open-InExplorer -Path $p -Select })
    $miCopy = New-Object System.Windows.Controls.MenuItem; $miCopy.Header = '复制路径'; $miCopy.Tag = $Path
    $miCopy.Add_Click({ try { [System.Windows.Clipboard]::SetText([string]$_.Source.Tag) } catch { } })
    $miDel = New-Object System.Windows.Controls.MenuItem; $miDel.Header = '删除到回收站'; $miDel.Tag = $Path
    $miDel.Add_Click({ Remove-SpaceDirs -Paths @([string]$_.Source.Tag) })
    $null = $menu.Items.Add($miOpen); $null = $menu.Items.Add($miCopy); $null = $menu.Items.Add($miDel)
    $row.ContextMenu = $menu
    return $row
  }

  # ===== 填充子目录 =====
  function script:Space-FillChildren {
    param([string]$Dir)
    if (-not $script:SpaceTotal -or -not $script:SpaceTotal.ContainsKey($Dir)) { return }
    $script:SpaceDir = $Dir
    $script:SpaceSel = $null
    $script:LblSpacePath.Text = $Dir
    $dirTotal = $script:SpaceTotal[$Dir]
    $script:BtnSpaceUp.IsEnabled = ($Dir.LastIndexOf('\') -gt 2)
    $script:SpaceList.Children.Clear()
    # 归一化 base（容忍 Dir 带/不带尾反斜杠）：child = base + 恰好一段无反斜杠后缀
    $base = $Dir.TrimEnd('\') + '\'
    $kids = New-Object System.Collections.Generic.List[object]
    foreach ($k in $script:SpaceTotal.Keys) {
      if ($k.Length -gt $base.Length -and $k.StartsWith($base, 'OrdinalIgnoreCase')) {
        $rest = $k.Substring($base.Length)
        if ($rest -and ($rest.IndexOf('\') -lt 0)) {
          $kids.Add([pscustomobject]@{ Path = $k })
        }
      }
    }
    foreach ($kd in ($kids | Sort-Object { -$script:SpaceTotal[$_.Path] })) {
      $tot = $script:SpaceTotal[$kd.Path]
      $ownB = if ($script:SpaceOwn.ContainsKey($kd.Path)) { $script:SpaceOwn[$kd.Path] } else { 0L }
      $null = $script:SpaceList.Children.Add((New-SpaceRow -Path $kd.Path -Total $tot -Own $ownB -DirTotal $dirTotal))
    }
    $script:LblSpaceStatus.Text = ('当前目录合计: {0}' -f (Format-Bytes $dirTotal))
  }

  # ===== 删除（右键 / 页脚按钮共用；成功才同步索引） =====
  function script:Remove-SpaceDirs {
    param([string[]]$Paths)
    if ($Paths.Count -eq 0) { return }
    $r = [System.Windows.MessageBox]::Show(('确定将选中的 {0} 个目录删除到回收站？' -f $Paths.Count), '确认删除', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $rel = 0L; $ok = 0
    foreach ($path in $Paths) {
      $existed = Test-Path -LiteralPath $path
      $b = Remove-UserPathToRecycle $path
      if (-not ($existed -and -not (Test-Path -LiteralPath $path))) { continue }
      $ok++; $rel += $b
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
    Log-Line ('空间分析删除: 成功 {0}/{1}, 释放 {2}' -f $ok, $Paths.Count, (Format-Bytes $rel))
    if ($script:SpaceDir) { Space-FillChildren $script:SpaceDir }
    try {
      $null = [System.Windows.MessageBox]::Show(('已删除 {0} 个目录，释放 {1}；占用/受保护自动跳过。' -f $ok, (Format-Bytes $rel)), '完成', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    } catch { }
  }

  # ===== 扫描 worker =====
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
    try { $script:LblSpaceStatus.Text = [string]$e.UserState } catch { }
  })
  $script:SpaceWorker.add_RunWorkerCompleted({
    param($s, $e)
    try {
      $script:BtnSpaceScan.IsEnabled = $true; $script:BtnSpaceStop.IsEnabled = $false
      $script:ProgSpace.IsIndeterminate = $false; $script:ProgSpace.Value = 0
      if ($e.Error) { $script:LblSpaceStatus.Text = '扫描出错'; Log-Line ('空间分析出错: ' + $e.Error.Message); return }
      if ($e.Cancelled) { $script:LblSpaceStatus.Text = '已取消'; return }
      $script:SpaceOwn = $e.Result.Own
      $script:SpaceTotal = $e.Result.Total
      $root = [string]$script:CmbSpaceDrive.SelectedItem + '\'
      if (-not $script:SpaceTotal.ContainsKey($root)) { $root = $root.TrimEnd('\') }
      Space-FillChildren $root
      Log-Line ('空间分析完成: {0} 共 {1} 个目录' -f $script:CmbSpaceDrive.SelectedItem, $script:SpaceTotal.Count)
    } catch { Log-Line ('空间分析完成处理出错: ' + $_.Exception.Message) }
  })

  $script:BtnSpaceScan.Add_Click({
    $drive = [string]$script:CmbSpaceDrive.SelectedItem
    if (-not $drive) {
      try { $null = [System.Windows.MessageBox]::Show('请先选择磁盘。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
      return
    }
    $script:BtnSpaceScan.IsEnabled = $false; $script:BtnSpaceStop.IsEnabled = $true
    $script:ProgSpace.IsIndeterminate = $true
    $script:LblSpaceStatus.Text = '扫描中...'
    $script:SpaceList.Children.Clear(); $script:SpaceOwn = $null; $script:SpaceTotal = $null; $script:SpaceDir = $null
    Log-Line ('空间分析扫描开始: ' + $drive)
    $script:SpaceWorker.RunWorkerAsync(($drive + '\'))
  })
  $script:BtnSpaceStop.Add_Click({ if ($script:SpaceWorker) { $script:SpaceWorker.CancelAsync() } })
  $script:BtnSpaceUp.Add_Click({
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
  $script:BtnSpaceDel.Add_Click({
    $sel = @($script:SpaceList.Children | Where-Object { $_ -is [System.Windows.Controls.Border] -and $_.Tag -and $_.Tag -eq $script:SpaceSel } | ForEach-Object { [string]$_.Tag })
    if ($sel.Count -eq 0) {
      try { $null = [System.Windows.MessageBox]::Show('请先点击选中要删除的目录。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
      return
    }
    Remove-SpaceDirs -Paths $sel
  })

  return $g
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
  # 布局：工具栏 44 | 表头+列表 | 页脚 44；单选行 + 右键菜单 + 表头点击排序
  $g = New-Object System.Windows.Controls.Grid
  $r0 = New-Object System.Windows.Controls.RowDefinition; $r0.Height = [System.Windows.GridLength]::new(44)
  $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = [System.Windows.GridLength]::new(44)
  $null = $g.RowDefinitions.Add($r0); $null = $g.RowDefinitions.Add($r1); $null = $g.RowDefinitions.Add($r2)

  # ===== 工具栏 =====
  $top = New-Object System.Windows.Controls.Border
  $top.Background = (New-WpfBrush '#FFFFFF'); $top.BorderBrush = (New-WpfBrush $script:Theme.CardLine); $top.BorderThickness = (New-WpfThickness 0 0 0 1)
  $tg = New-Object System.Windows.Controls.Grid
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 磁盘标签
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 磁盘框
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 阈值标签
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 阈值框
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 扫描
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 停止
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 进度
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 状态 *
  $lblD = New-Object System.Windows.Controls.TextBlock
  $lblD.Text = '磁盘:'; $lblD.VerticalAlignment = 'Center'; $lblD.Margin = (New-WpfThickness 12 0 0 0)
  $null = $tg.Children.Add($lblD)
  $script:CmbDriveL = New-Object System.Windows.Controls.ComboBox
  $script:CmbDriveL.Width = 66; $script:CmbDriveL.VerticalAlignment = 'Center'; $script:CmbDriveL.Margin = (New-WpfThickness 8 0 0 0)
  foreach ($d in (Get-FixedDrives)) { $null = $script:CmbDriveL.Items.Add($d) }
  if ($script:CmbDriveL.Items.Count -gt 0) { $script:CmbDriveL.SelectedIndex = 0 }
  [System.Windows.Controls.Grid]::SetColumn($script:CmbDriveL, 1); $null = $tg.Children.Add($script:CmbDriveL)
  $lblTh = New-Object System.Windows.Controls.TextBlock
  $lblTh.Text = '最小大小:'; $lblTh.VerticalAlignment = 'Center'; $lblTh.Margin = (New-WpfThickness 14 0 0 0)
  [System.Windows.Controls.Grid]::SetColumn($lblTh, 2); $null = $tg.Children.Add($lblTh)
  $script:CmbThL = New-Object System.Windows.Controls.ComboBox
  $script:CmbThL.Width = 88; $script:CmbThL.VerticalAlignment = 'Center'; $script:CmbThL.Margin = (New-WpfThickness 8 0 0 0)
  $null = $script:CmbThL.Items.Add('100 MB'); $null = $script:CmbThL.Items.Add('300 MB'); $null = $script:CmbThL.Items.Add('500 MB'); $null = $script:CmbThL.Items.Add('1 GB')
  $script:CmbThL.SelectedIndex = 0
  [System.Windows.Controls.Grid]::SetColumn($script:CmbThL, 3); $null = $tg.Children.Add($script:CmbThL)
  $script:BtnScanL = New-Object System.Windows.Controls.Button
  $script:BtnScanL.Content = '开始扫描'; $script:BtnScanL.Margin = (New-WpfThickness 12 0 0 0)
  $script:BtnScanL.Background = (New-WpfBrush $script:Theme.Primary); $script:BtnScanL.Foreground = (New-WpfBrush '#FFFFFF')
  $script:BtnScanL.Padding = (New-WpfThickness 12 4 12 4)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnScanL, 4); $null = $tg.Children.Add($script:BtnScanL)
  $script:BtnStopL = New-Object System.Windows.Controls.Button
  $script:BtnStopL.Content = '停止'; $script:BtnStopL.IsEnabled = $false; $script:BtnStopL.Margin = (New-WpfThickness 8 0 0 0)
  $script:BtnStopL.Padding = (New-WpfThickness 10 4 10 4)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnStopL, 5); $null = $tg.Children.Add($script:BtnStopL)
  $script:ProgL = New-Object System.Windows.Controls.ProgressBar
  $script:ProgL.Width = 200; $script:ProgL.Height = 8; $script:ProgL.VerticalAlignment = 'Center'; $script:ProgL.Margin = (New-WpfThickness 14 0 0 0)
  $script:ProgL.Foreground = (New-WpfBrush $script:Theme.Primary); $script:ProgL.Background = (New-WpfBrush '#EEF0F2')
  [System.Windows.Controls.Grid]::SetColumn($script:ProgL, 6); $null = $tg.Children.Add($script:ProgL)
  $script:LblL = New-Object System.Windows.Controls.TextBlock
  $script:LblL.Text = '就绪'; $script:LblL.VerticalAlignment = 'Center'; $script:LblL.Margin = (New-WpfThickness 12 0 0 0)
  $script:LblL.Foreground = (New-WpfBrush $script:Theme.SubText); $script:LblL.FontSize = 12
  [System.Windows.Controls.Grid]::SetColumn($script:LblL, 7); $null = $tg.Children.Add($script:LblL)
  $top.Child = $tg
  [System.Windows.Controls.Grid]::SetRow($top, 0); $null = $g.Children.Add($top)

  # ===== 表头 + 列表 =====
  $mid = New-Object System.Windows.Controls.Grid
  $mh = New-Object System.Windows.Controls.RowDefinition; $mh.Height = [System.Windows.GridLength]::new(30)
  $ml = New-Object System.Windows.Controls.RowDefinition; $ml.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $null = $mid.RowDefinitions.Add($mh); $null = $mid.RowDefinitions.Add($ml)
  $hdr = New-Object System.Windows.Controls.Border
  $hdr.Background = (New-WpfBrush '#F8F9FA'); $hdr.BorderBrush = (New-WpfBrush '#F0F1F3'); $hdr.BorderThickness = (New-WpfThickness 0 0 0 1)
  $hg = New-Object System.Windows.Controls.Grid
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))                       # 名称 *
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(110)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[2].Width = [System.Windows.GridLength]::new(150)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))                       # 路径 *
  $hCols = @('名称', '大小', '修改时间', '路径')
  $hKeys = @(
    { param($r) $r.Name },
    { param($r) $r.Size },
    { param($r) $r.Modified },
    { param($r) $r.Path }
  )
  $script:LfSort = @()
  for ($ci = 0; $ci -lt $hCols.Count; $ci++) {
    $ht = New-Object System.Windows.Controls.TextBlock
    $ht.Text = $hCols[$ci]; $ht.FontSize = 11; $ht.FontWeight = [System.Windows.FontWeights]::Bold
    $ht.Foreground = (New-WpfBrush $script:Theme.SubText); $ht.VerticalAlignment = 'Center'
    $ht.Margin = (New-WpfThickness 12 0 6 0)
    [System.Windows.Controls.Grid]::SetColumn($ht, $ci)
    $null = $hg.Children.Add($ht)
    Add-WpfSortHeader -Header $ht -VarName 'LfRows' -Key $hKeys[$ci] -Render { script:Render-Lf }
    $script:LfSort += $ht
  }
  $hdr.Child = $hg
  [System.Windows.Controls.Grid]::SetRow($hdr, 0); $null = $mid.Children.Add($hdr)
  $scroll = New-Object System.Windows.Controls.ScrollViewer
  $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
  $scroll.Background = (New-WpfBrush '#FFFFFF')
  $script:LfList = New-Object System.Windows.Controls.StackPanel
  $scroll.Content = $script:LfList
  [System.Windows.Controls.Grid]::SetRow($scroll, 1); $null = $mid.Children.Add($scroll)
  [System.Windows.Controls.Grid]::SetRow($mid, 1); $null = $g.Children.Add($mid)

  # ===== 页脚 =====
  $foot = New-Object System.Windows.Controls.Border
  $foot.Background = (New-WpfBrush '#FFFFFF'); $foot.BorderBrush = (New-WpfBrush $script:Theme.CardLine); $foot.BorderThickness = (New-WpfThickness 0 1 0 0)
  $fg = New-Object System.Windows.Controls.Grid
  $null = $fg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $fg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $script:LblLTotal = New-Object System.Windows.Controls.TextBlock
  $script:LblLTotal.Text = '共 0 个文件'; $script:LblLTotal.VerticalAlignment = 'Center'; $script:LblLTotal.Margin = (New-WpfThickness 12 0 0 0)
  $script:LblLTotal.FontSize = 12; $script:LblLTotal.FontWeight = [System.Windows.FontWeights]::Bold
  $script:LblLTotal.Foreground = (New-WpfBrush $script:Theme.Primary)
  $null = $fg.Children.Add($script:LblLTotal)
  $script:BtnDelL = New-Object System.Windows.Controls.Button
  $script:BtnDelL.Content = '删除选中(回收站)'
  $script:BtnDelL.Background = (New-WpfBrush $script:Theme.Red); $script:BtnDelL.Foreground = (New-WpfBrush '#FFFFFF')
  $script:BtnDelL.Padding = (New-WpfThickness 12 4 12 4); $script:BtnDelL.HorizontalAlignment = 'Right'; $script:BtnDelL.Margin = (New-WpfThickness 0 0 12 0)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnDelL, 1); $null = $fg.Children.Add($script:BtnDelL)
  $foot.Child = $fg
  [System.Windows.Controls.Grid]::SetRow($foot, 2); $null = $g.Children.Add($foot)

  # ===== 状态 =====
  $script:LfRows = @()   # 当前行数据（排序/删除都写回这里，Render 以其为准）
  $script:LfSel = $null  # 选中的文件路径

  # ===== 行助手（4 列 + 单选高亮 + 右键菜单） =====
  function script:New-LfRow {
    param($It)
    $row = New-Object System.Windows.Controls.Border
    $row.Tag = $It
    $row.Background = (New-WpfBrush $(if ($It.Path -eq $script:LfSel) { '#EAF3FF' } else { '#FFFFFF' }))
    $row.BorderBrush = (New-WpfBrush '#F0F1F3'); $row.BorderThickness = (New-WpfThickness 0 0 0 1)
    $row.Padding = (New-WpfThickness 12 5 12 5)
    $ig = New-Object System.Windows.Controls.Grid
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(110)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[2].Width = [System.Windows.GridLength]::new(150)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $tName = New-Object System.Windows.Controls.TextBlock
    $tName.Text = $It.Name; $tName.FontSize = 13; $tName.VerticalAlignment = 'Center'; $tName.TextTrimming = 'CharacterEllipsis'
    $null = $ig.Children.Add($tName)
    $tSize = New-Object System.Windows.Controls.TextBlock
    $tSize.Text = Format-Bytes $It.Size; $tSize.FontSize = 12; $tSize.VerticalAlignment = 'Center'; $tSize.HorizontalAlignment = 'Right'
    $tSize.Foreground = (New-WpfBrush $script:Theme.Text); [System.Windows.Controls.Grid]::SetColumn($tSize, 1); $null = $ig.Children.Add($tSize)
    $tMod = New-Object System.Windows.Controls.TextBlock
    $tMod.Text = $It.Modified.ToString('yyyy-MM-dd HH:mm'); $tMod.FontSize = 12; $tMod.VerticalAlignment = 'Center'
    $tMod.Foreground = (New-WpfBrush $script:Theme.SubText); [System.Windows.Controls.Grid]::SetColumn($tMod, 2); $null = $ig.Children.Add($tMod)
    $tPath = New-Object System.Windows.Controls.TextBlock
    $tPath.Text = $It.Path; $tPath.FontSize = 11; $tPath.VerticalAlignment = 'Center'; $tPath.TextTrimming = 'CharacterEllipsis'
    $tPath.Foreground = (New-WpfBrush $script:Theme.Disabled); [System.Windows.Controls.Grid]::SetColumn($tPath, 3); $null = $ig.Children.Add($tPath)
    $row.Child = $ig
    $row.Add_MouseEnter({ param($s, $e) try { if ($s.Tag.Path -ne $script:LfSel) { $s.Background = (New-WpfBrush '#F4F5F7') } } catch { } })
    $row.Add_MouseLeave({ param($s, $e) try { if ($s.Tag.Path -ne $script:LfSel) { $s.Background = (New-WpfBrush '#FFFFFF') } } catch { } })
    $row.Add_MouseLeftButtonDown({
      param($s, $e)
      try {
        $script:LfSel = [string]$s.Tag.Path
        foreach ($ch in $script:LfList.Children) {
          if ($ch -is [System.Windows.Controls.Border] -and $ch.Tag) {
            $ch.Background = (New-WpfBrush $(if ($ch.Tag.Path -eq $script:LfSel) { '#EAF3FF' } else { '#FFFFFF' }))
          }
        }
      } catch { }
    })
    $menu = New-Object System.Windows.Controls.ContextMenu
    $miOpen = New-Object System.Windows.Controls.MenuItem; $miOpen.Header = '打开所在文件夹'; $miOpen.Tag = $It
    $miOpen.Add_Click({ $it = $_.Source.Tag; Open-InExplorer -Path $it.Path -Select })
    $miCopy = New-Object System.Windows.Controls.MenuItem; $miCopy.Header = '复制路径'; $miCopy.Tag = $It
    $miCopy.Add_Click({ $it = $_.Source.Tag; try { [System.Windows.Clipboard]::SetText([string]$it.Path) } catch { } })
    $miDel = New-Object System.Windows.Controls.MenuItem; $miDel.Header = '删除到回收站'; $miDel.Tag = $It
    $miDel.Add_Click({ Remove-LfFiles -Paths @([string]$_.Source.Tag.Path) })
    $null = $menu.Items.Add($miOpen); $null = $menu.Items.Add($miCopy); $null = $menu.Items.Add($miDel)
    $row.ContextMenu = $menu
    return $row
  }

  # ===== 渲染（以 LfRows 为准；供扫描完成/排序/删除后刷新） =====
  function script:Render-Lf {
    $script:LfList.Children.Clear()
    foreach ($r in $script:LfRows) { $null = $script:LfList.Children.Add((New-LfRow -It $r)) }
    $totalBytes = 0L
    foreach ($r in $script:LfRows) { $totalBytes += [long]$r.Size }
    $script:LblLTotal.Text = ('共 {0} 个文件 / {1}' -f $script:LfRows.Count, (Format-Bytes $totalBytes))
  }

  # ===== 删除（右键 / 页脚共用；以"删前存在删后不在"判成功） =====
  function script:Remove-LfFiles {
    param([string[]]$Paths)
    if ($Paths.Count -eq 0) { return }
    $r = [System.Windows.MessageBox]::Show(('确定将选中的 {0} 个大文件删除到回收站？' -f $Paths.Count), '确认删除', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $rel = 0L; $ok = 0; $gone = @()
    foreach ($p in $Paths) {
      $existed = Test-Path -LiteralPath $p
      $b = Remove-UserPathToRecycle $p
      if ($existed -and -not (Test-Path -LiteralPath $p)) { $ok++; $rel += $b; $gone += $p }
    }
    Log-Line ('大文件删除: 成功 {0}/{1}, 释放 {2}' -f $ok, $Paths.Count, (Format-Bytes $rel))
    if ($gone.Count -gt 0) {
      $script:LfRows = @($script:LfRows | Where-Object { $gone -notcontains $_.Path })
      if ($script:LfSel -and ($gone -contains $script:LfSel)) { $script:LfSel = $null }
      Render-Lf
    }
    try {
      $null = [System.Windows.MessageBox]::Show(('已删除 {0} 个大文件，释放 {1}；被占用/受保护的文件自动跳过。' -f $ok, (Format-Bytes $rel)), '完成', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    } catch { }
  }

  # ===== 扫描 worker =====
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
    try { $script:LblL.Text = [string]$e.UserState } catch { }
  })
  $script:LfWorker.add_RunWorkerCompleted({
    param($s, $e)
    try {
      $script:BtnScanL.IsEnabled = $true; $script:BtnStopL.IsEnabled = $false
      $script:ProgL.IsIndeterminate = $false; $script:ProgL.Value = 0
      if ($e.Error) { $script:LblL.Text = '扫描出错'; Log-Line ('大文件扫描出错: ' + $e.Error.Message); return }
      if ($e.Cancelled) { $script:LblL.Text = '已取消'; return }
      $script:LfRows = @($e.Result)
      $script:LfSel = $null
      Render-Lf
      $script:LblL.Text = '完成'
      Log-Line ('大文件扫描完成: {0} 个' -f $script:LfRows.Count)
    } catch { Log-Line ('大文件完成处理出错: ' + $_.Exception.Message) }
  })

  $script:BtnScanL.Add_Click({
    $drive = [string]$script:CmbDriveL.SelectedItem
    if (-not $drive) {
      try { $null = [System.Windows.MessageBox]::Show('请先选择磁盘。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
      return
    }
    $mb = switch ([string]$script:CmbThL.SelectedItem) { '300 MB' { 300 } '500 MB' { 500 } '1 GB' { 1024 } default { 100 } }
    $script:BtnScanL.IsEnabled = $false; $script:BtnStopL.IsEnabled = $true
    $script:ProgL.IsIndeterminate = $true; $script:LblL.Text = '扫描中...'
    $script:LfList.Children.Clear(); $script:LfRows = @(); $script:LfSel = $null
    $script:LblLTotal.Text = '共 0 个文件'
    Log-Line ('大文件扫描开始: {0} >= {1}' -f $drive, $script:CmbThL.SelectedItem)
    $script:LfWorker.RunWorkerAsync(@{ Root = ($drive + '\'); Threshold = ([long]$mb * 1024 * 1024) })
  })
  $script:BtnStopL.Add_Click({ if ($script:LfWorker) { $script:LfWorker.CancelAsync() } })
  $script:BtnDelL.Add_Click({
    if (-not $script:LfSel) {
      try { $null = [System.Windows.MessageBox]::Show('请先点击选中要删除的大文件。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
      return
    }
    Remove-LfFiles -Paths @($script:LfSel)
  })

  return $g
}

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

function New-EmptyDirPage {
  # 布局：工具栏 44 | 表头+列表 | 页脚 44
  $g = New-Object System.Windows.Controls.Grid
  $r0 = New-Object System.Windows.Controls.RowDefinition; $r0.Height = [System.Windows.GridLength]::new(44)
  $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = [System.Windows.GridLength]::new(44)
  $null = $g.RowDefinitions.Add($r0); $null = $g.RowDefinitions.Add($r1); $null = $g.RowDefinitions.Add($r2)

  # ===== 工具栏 =====
  $top = New-Object System.Windows.Controls.Border
  $top.Background = (New-WpfBrush '#FFFFFF'); $top.BorderBrush = (New-WpfBrush $script:Theme.CardLine); $top.BorderThickness = (New-WpfThickness 0 0 0 1)
  $tg = New-Object System.Windows.Controls.Grid
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $lblD = New-Object System.Windows.Controls.TextBlock
  $lblD.Text = '磁盘:'; $lblD.VerticalAlignment = 'Center'; $lblD.Margin = (New-WpfThickness 12 0 0 0)
  $null = $tg.Children.Add($lblD)
  $script:CmbDriveE = New-Object System.Windows.Controls.ComboBox
  $script:CmbDriveE.Width = 66; $script:CmbDriveE.VerticalAlignment = 'Center'; $script:CmbDriveE.Margin = (New-WpfThickness 8 0 0 0)
  foreach ($d in (Get-FixedDrives)) { $null = $script:CmbDriveE.Items.Add($d) }
  if ($script:CmbDriveE.Items.Count -gt 0) { $script:CmbDriveE.SelectedIndex = 0 }
  [System.Windows.Controls.Grid]::SetColumn($script:CmbDriveE, 1); $null = $tg.Children.Add($script:CmbDriveE)
  $script:BtnScanE = New-Object System.Windows.Controls.Button
  $script:BtnScanE.Content = '开始扫描'; $script:BtnScanE.Margin = (New-WpfThickness 10 0 0 0)
  $script:BtnScanE.Background = (New-WpfBrush $script:Theme.Primary); $script:BtnScanE.Foreground = (New-WpfBrush '#FFFFFF')
  $script:BtnScanE.Padding = (New-WpfThickness 12 4 12 4)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnScanE, 2); $null = $tg.Children.Add($script:BtnScanE)
  $script:BtnStopE = New-Object System.Windows.Controls.Button
  $script:BtnStopE.Content = '停止'; $script:BtnStopE.IsEnabled = $false; $script:BtnStopE.Margin = (New-WpfThickness 8 0 0 0)
  $script:BtnStopE.Padding = (New-WpfThickness 10 4 10 4)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnStopE, 3); $null = $tg.Children.Add($script:BtnStopE)
  $script:ProgE = New-Object System.Windows.Controls.ProgressBar
  $script:ProgE.Width = 200; $script:ProgE.Height = 8; $script:ProgE.VerticalAlignment = 'Center'; $script:ProgE.Margin = (New-WpfThickness 14 0 0 0)
  $script:ProgE.Foreground = (New-WpfBrush $script:Theme.Primary); $script:ProgE.Background = (New-WpfBrush '#EEF0F2')
  [System.Windows.Controls.Grid]::SetColumn($script:ProgE, 4); $null = $tg.Children.Add($script:ProgE)
  $script:LblE = New-Object System.Windows.Controls.TextBlock
  $script:LblE.Text = '就绪'; $script:LblE.VerticalAlignment = 'Center'; $script:LblE.Margin = (New-WpfThickness 12 0 0 0)
  $script:LblE.Foreground = (New-WpfBrush $script:Theme.SubText); $script:LblE.FontSize = 12
  [System.Windows.Controls.Grid]::SetColumn($script:LblE, 5); $null = $tg.Children.Add($script:LblE)
  $hint = New-Object System.Windows.Controls.TextBlock
  $hint.Text = '空子树只显示顶端目录，删除时整棵空目录树一并进回收站'
  $hint.VerticalAlignment = 'Center'; $hint.Margin = (New-WpfThickness 16 0 12 0); $hint.FontSize = 11
  $hint.Foreground = (New-WpfBrush $script:Theme.Disabled); $hint.TextTrimming = 'CharacterEllipsis'
  [System.Windows.Controls.Grid]::SetColumn($hint, 6); $null = $tg.Children.Add($hint)
  $sp = New-Object System.Windows.Controls.TextBlock; [System.Windows.Controls.Grid]::SetColumn($sp, 7); $null = $tg.Children.Add($sp)
  $top.Child = $tg
  [System.Windows.Controls.Grid]::SetRow($top, 0); $null = $g.Children.Add($top)

  # ===== 表头 + 列表 =====
  $mid = New-Object System.Windows.Controls.Grid
  $mh = New-Object System.Windows.Controls.RowDefinition; $mh.Height = [System.Windows.GridLength]::new(30)
  $ml = New-Object System.Windows.Controls.RowDefinition; $ml.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $null = $mid.RowDefinitions.Add($mh); $null = $mid.RowDefinitions.Add($ml)
  $hdr = New-Object System.Windows.Controls.Border
  $hdr.Background = (New-WpfBrush '#F8F9FA'); $hdr.BorderBrush = (New-WpfBrush '#F0F1F3'); $hdr.BorderThickness = (New-WpfThickness 0 0 0 1)
  $hg = New-Object System.Windows.Controls.Grid
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new(26)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(240)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $h1 = New-Object System.Windows.Controls.TextBlock
  $h1.Text = '名称'; $h1.FontSize = 11; $h1.FontWeight = [System.Windows.FontWeights]::Bold
  $h1.Foreground = (New-WpfBrush $script:Theme.SubText); $h1.VerticalAlignment = 'Center'; $h1.Margin = (New-WpfThickness 6 0 0 0)
  [System.Windows.Controls.Grid]::SetColumn($h1, 1); $null = $hg.Children.Add($h1)
  $h2 = New-Object System.Windows.Controls.TextBlock
  $h2.Text = '完整路径'; $h2.FontSize = 11; $h2.FontWeight = [System.Windows.FontWeights]::Bold
  $h2.Foreground = (New-WpfBrush $script:Theme.SubText); $h2.VerticalAlignment = 'Center'; $h2.Margin = (New-WpfThickness 12 0 0 0)
  [System.Windows.Controls.Grid]::SetColumn($h2, 2); $null = $hg.Children.Add($h2)
  $hdr.Child = $hg
  [System.Windows.Controls.Grid]::SetRow($hdr, 0); $null = $mid.Children.Add($hdr)
  $scroll = New-Object System.Windows.Controls.ScrollViewer
  $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
  $scroll.Background = (New-WpfBrush '#FFFFFF')
  $script:EmptyList = New-Object System.Windows.Controls.StackPanel
  $scroll.Content = $script:EmptyList
  [System.Windows.Controls.Grid]::SetRow($scroll, 1); $null = $mid.Children.Add($scroll)
  [System.Windows.Controls.Grid]::SetRow($mid, 1); $null = $g.Children.Add($mid)

  # ===== 页脚 =====
  $foot = New-Object System.Windows.Controls.Border
  $foot.Background = (New-WpfBrush '#FFFFFF'); $foot.BorderBrush = (New-WpfBrush $script:Theme.CardLine); $foot.BorderThickness = (New-WpfThickness 0 1 0 0)
  $fg = New-Object System.Windows.Controls.Grid
  $null = $fg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $fg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $fg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $script:LblETotal = New-Object System.Windows.Controls.TextBlock
  $script:LblETotal.Text = '共 0 个空目录'; $script:LblETotal.VerticalAlignment = 'Center'; $script:LblETotal.Margin = (New-WpfThickness 12 0 0 0)
  $script:LblETotal.FontSize = 12; $script:LblETotal.FontWeight = [System.Windows.FontWeights]::Bold
  $script:LblETotal.Foreground = (New-WpfBrush $script:Theme.Primary)
  $null = $fg.Children.Add($script:LblETotal)
  $script:BtnSelAllE = New-Object System.Windows.Controls.Button
  $script:BtnSelAllE.Content = '全选/反选'; $script:BtnSelAllE.Padding = (New-WpfThickness 12 4 12 4); $script:BtnSelAllE.HorizontalAlignment = 'Right'; $script:BtnSelAllE.Margin = (New-WpfThickness 0 0 8 0)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnSelAllE, 1); $null = $fg.Children.Add($script:BtnSelAllE)
  $script:BtnDelE = New-Object System.Windows.Controls.Button
  $script:BtnDelE.Content = '删除选中(回收站)'
  $script:BtnDelE.Background = (New-WpfBrush $script:Theme.Red); $script:BtnDelE.Foreground = (New-WpfBrush '#FFFFFF')
  $script:BtnDelE.Padding = (New-WpfThickness 12 4 12 4); $script:BtnDelE.HorizontalAlignment = 'Right'; $script:BtnDelE.Margin = (New-WpfThickness 0 0 12 0)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnDelE, 2); $null = $fg.Children.Add($script:BtnDelE)
  $foot.Child = $fg
  [System.Windows.Controls.Grid]::SetRow($foot, 2); $null = $g.Children.Add($foot)

  # ===== 状态 =====
  $script:EmptyCheckboxes = @()

  # ===== 行助手 =====
  function script:New-EmptyRow {
    param($It)
    $row = New-Object System.Windows.Controls.Border
    $row.Tag = $It
    $row.Background = (New-WpfBrush '#FFFFFF'); $row.BorderBrush = (New-WpfBrush '#F0F1F3'); $row.BorderThickness = (New-WpfThickness 0 0 0 1)
    $row.Padding = (New-WpfThickness 12 5 12 5)
    $ig = New-Object System.Windows.Controls.Grid
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new(26)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(240)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Tag = $It; $cb.VerticalAlignment = 'Center'
    $null = $ig.Children.Add($cb)
    $script:EmptyCheckboxes += $cb
    $nm = New-Object System.Windows.Controls.TextBlock
    $nm.Text = $It.Name; $nm.FontSize = 13; $nm.VerticalAlignment = 'Center'; $nm.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetColumn($nm, 1); $null = $ig.Children.Add($nm)
    $tp = New-Object System.Windows.Controls.TextBlock
    $tp.Text = $It.Path; $tp.FontSize = 11; $tp.VerticalAlignment = 'Center'; $tp.TextTrimming = 'CharacterEllipsis'
    $tp.Foreground = (New-WpfBrush $script:Theme.Disabled)
    [System.Windows.Controls.Grid]::SetColumn($tp, 2); $null = $ig.Children.Add($tp)
    $row.Child = $ig
    $row.Add_MouseEnter({ param($s, $e) try { $s.Background = (New-WpfBrush '#F4F5F7') } catch { } })
    $row.Add_MouseLeave({ param($s, $e) try { $s.Background = (New-WpfBrush '#FFFFFF') } catch { } })
    $menu = New-Object System.Windows.Controls.ContextMenu
    $miOpen = New-Object System.Windows.Controls.MenuItem; $miOpen.Header = '打开所在文件夹'; $miOpen.Tag = $It
    $miOpen.Add_Click({ $it = $_.Source.Tag; Open-InExplorer -Path $it.Path -Select })
    $miCopy = New-Object System.Windows.Controls.MenuItem; $miCopy.Header = '复制路径'; $miCopy.Tag = $It
    $miCopy.Add_Click({ $it = $_.Source.Tag; try { [System.Windows.Clipboard]::SetText([string]$it.Path) } catch { } })
    $miDel = New-Object System.Windows.Controls.MenuItem; $miDel.Header = '删除到回收站'; $miDel.Tag = $It
    $miDel.Add_Click({ Remove-EmptyDirs -Items @($_.Source.Tag) })
    $null = $menu.Items.Add($miOpen); $null = $menu.Items.Add($miCopy); $null = $menu.Items.Add($miDel)
    $row.ContextMenu = $menu
    return $row
  }

  # ===== 删除（右键 / 页脚共用；空目录 0 字节，以"删前存在删后不在"判成功） =====
  function script:Remove-EmptyDirs {
    param($Items)
    if ($Items.Count -eq 0) { return }
    $r = [System.Windows.MessageBox]::Show(('确定将勾选的 {0} 个空目录树删除到回收站？' -f $Items.Count), '确认删除', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $ok = 0; $gone = @()
    foreach ($it in $Items) {
      $existed = Test-Path -LiteralPath $it.Path
      $null = Remove-UserPathToRecycle $it.Path
      if ($existed -and -not (Test-Path -LiteralPath $it.Path)) { $ok++; $gone += $it }
    }
    Log-Line ('空文件夹删除: 成功 {0}/{1}' -f $ok, $Items.Count)
    # 从列表移除已删行
    foreach ($g in $gone) {
      $targets = @($script:EmptyList.Children | Where-Object { $_ -is [System.Windows.Controls.Border] -and $_.Tag -and $_.Tag.Path -eq $g.Path })
      foreach ($t in $targets) { $script:EmptyList.Children.Remove($t) }
    }
    $script:LblETotal.Text = ('共 {0} 个空目录' -f ($script:EmptyList.Children | Where-Object { $_ -is [System.Windows.Controls.Border] }).Count)
    try {
      $null = [System.Windows.MessageBox]::Show(('已删除 {0} 个空目录树；被占用/受保护的目录自动跳过。' -f $ok), '完成', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    } catch { }
  }

  # ===== 扫描 worker =====
  $script:EmptyWorker = New-Object System.ComponentModel.BackgroundWorker
  $script:EmptyWorker.WorkerSupportsCancellation = $true
  $script:EmptyWorker.WorkerReportsProgress = $true
  $edDoWork = {
    param($s, $e)
    $a = $e.Argument
    $list = Get-EmptyDirs -Root $a.Root -W $s
    if ($s.CancellationPending) { $e.Cancel = $true; return }
    $e.Result = $list
  }
  Register-WorkerBody -Worker $script:EmptyWorker -Name 'EmptyDir' -ScriptBlock $edDoWork
  $script:EmptyWorker.add_ProgressChanged({
    param($s, $e)
    try { $script:LblE.Text = [string]$e.UserState } catch { }
  })
  $script:EmptyWorker.add_RunWorkerCompleted({
    param($s, $e)
    try {
      $script:BtnScanE.IsEnabled = $true; $script:BtnStopE.IsEnabled = $false
      $script:ProgE.IsIndeterminate = $false; $script:ProgE.Value = 0
      if ($e.Error) { $script:LblE.Text = '扫描出错'; Log-Line ('空文件夹扫描出错: ' + $e.Error.Message); return }
      if ($e.Cancelled) { $script:LblE.Text = '已取消'; return }
      $rows = @($e.Result)
      $script:EmptyList.Children.Clear(); $script:EmptyCheckboxes = @()
      foreach ($r in $rows) { $null = $script:EmptyList.Children.Add((New-EmptyRow -It $r)) }
      $script:LblETotal.Text = ('共 {0} 个空目录' -f $rows.Count)
      $script:LblE.Text = '完成'
      Log-Line ('空文件夹扫描完成: {0} 个空子树' -f $rows.Count)
    } catch { Log-Line ('空文件夹完成处理出错: ' + $_.Exception.Message) }
  })

  $script:BtnScanE.Add_Click({
    $drive = [string]$script:CmbDriveE.SelectedItem
    if (-not $drive) {
      try { $null = [System.Windows.MessageBox]::Show('请先选择磁盘。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
      return
    }
    $script:BtnScanE.IsEnabled = $false; $script:BtnStopE.IsEnabled = $true
    $script:ProgE.IsIndeterminate = $true; $script:LblE.Text = '扫描中...'
    $script:EmptyList.Children.Clear(); $script:EmptyCheckboxes = @(); $script:LblETotal.Text = '共 0 个空目录'
    Log-Line ('空文件夹扫描开始: {0}' -f $drive)
    $script:EmptyWorker.RunWorkerAsync(@{ Root = ($drive + '\') })
  })
  $script:BtnStopE.Add_Click({ if ($script:EmptyWorker) { $script:EmptyWorker.CancelAsync() } })
  $script:BtnSelAllE.Add_Click({
    $allChecked = $true
    foreach ($cb in $script:EmptyCheckboxes) { if (-not $cb.IsChecked) { $allChecked = $false; break } }
    foreach ($cb in $script:EmptyCheckboxes) { $cb.IsChecked = (-not $allChecked) }
  })
  $script:BtnDelE.Add_Click({
    $sel = @($script:EmptyCheckboxes | Where-Object { $_.IsChecked -and $_.Tag } | ForEach-Object { $_.Tag })
    if ($sel.Count -eq 0) {
      try { $null = [System.Windows.MessageBox]::Show('请先勾选要删除的空目录。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
      return
    }
    Remove-EmptyDirs -Items $sel
  })

  return $g
}

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

function New-SysAccelPage {
  # 布局：内存卡片（标题 + 进度条 + 百分比 + 明细 + 操作按钮 + 结果）
  $g = New-Object System.Windows.Controls.Grid
  $card = New-Object System.Windows.Controls.Border
  $card.Background = (New-WpfBrush '#FFFFFF')
  $card.BorderBrush = (New-WpfBrush $script:Theme.CardLine)
  $card.BorderThickness = (New-WpfThickness 1)
  $card.Margin = (New-WpfThickness 16)
  $sp = New-Object System.Windows.Controls.StackPanel
  $sp.Margin = (New-WpfThickness 20 18 20 18)
  $tTitle = New-Object System.Windows.Controls.TextBlock
  $tTitle.Text = '内存占用'
  $tTitle.FontSize = 15; $tTitle.FontWeight = [System.Windows.FontWeights]::Bold
  $tTitle.Foreground = (New-WpfBrush $script:Theme.Primary)
  $null = $sp.Children.Add($tTitle)

  # 进度条 + 百分比
  $row1 = New-Object System.Windows.Controls.Grid
  $null = $row1.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $row1.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $script:MemBar = New-Object System.Windows.Controls.ProgressBar
  $script:MemBar.Height = 10; $script:MemBar.Minimum = 0; $script:MemBar.Maximum = 100; $script:MemBar.Value = 0
  $script:MemBar.Foreground = (New-WpfBrush $script:Theme.Primary); $script:MemBar.Background = (New-WpfBrush '#EEF0F2')
  $script:MemBar.VerticalAlignment = 'Center'; $script:MemBar.Margin = (New-WpfThickness 0 14 0 0)
  $null = $row1.Children.Add($script:MemBar)
  $script:LblMemPct = New-Object System.Windows.Controls.TextBlock
  $script:LblMemPct.Text = '--'
  $script:LblMemPct.FontSize = 26; $script:LblMemPct.FontWeight = [System.Windows.FontWeights]::Bold
  $script:LblMemPct.Foreground = (New-WpfBrush $script:Theme.Primary); $script:LblMemPct.VerticalAlignment = 'Center'
  $script:LblMemPct.Margin = (New-WpfThickness 16 8 0 0)
  [System.Windows.Controls.Grid]::SetColumn($script:LblMemPct, 1); $null = $row1.Children.Add($script:LblMemPct)
  $null = $sp.Children.Add($row1)

  $script:LblMemDetail = New-Object System.Windows.Controls.TextBlock
  $script:LblMemDetail.Text = '已用 -- / 共 --'
  $script:LblMemDetail.Foreground = (New-WpfBrush $script:Theme.SubText); $script:LblMemDetail.FontSize = 12
  $script:LblMemDetail.Margin = (New-WpfThickness 0 8 0 0)
  $null = $sp.Children.Add($script:LblMemDetail)

  # 操作行：清理待机内存 / 修剪工作集 / 管理员提示
  $row2 = New-Object System.Windows.Controls.Grid
  $null = $row2.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $row2.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $row2.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $script:BtnPurgeStandby = New-Object System.Windows.Controls.Button
  $script:BtnPurgeStandby.Content = '清理待机内存'
  $script:BtnPurgeStandby.Background = (New-WpfBrush $script:Theme.Primary); $script:BtnPurgeStandby.Foreground = (New-WpfBrush '#FFFFFF')
  $script:BtnPurgeStandby.Padding = (New-WpfThickness 16 6 16 6); $script:BtnPurgeStandby.Margin = (New-WpfThickness 0 16 0 0)
  $null = $row2.Children.Add($script:BtnPurgeStandby)
  $script:BtnTrimWS = New-Object System.Windows.Controls.Button
  $script:BtnTrimWS.Content = '修剪工作集'
  $script:BtnTrimWS.Background = (New-WpfBrush $script:Theme.Primary); $script:BtnTrimWS.Foreground = (New-WpfBrush '#FFFFFF')
  $script:BtnTrimWS.Padding = (New-WpfThickness 16 6 16 6); $script:BtnTrimWS.Margin = (New-WpfThickness 10 16 0 0)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnTrimWS, 1); $null = $row2.Children.Add($script:BtnTrimWS)
  $script:LblMemAdmin = New-Object System.Windows.Controls.TextBlock
  $script:LblMemAdmin.Text = '需要管理员权限'; $script:LblMemAdmin.VerticalAlignment = 'Center'
  $script:LblMemAdmin.Foreground = (New-WpfBrush $script:Theme.Disabled); $script:LblMemAdmin.FontSize = 12
  $script:LblMemAdmin.Margin = (New-WpfThickness 12 16 0 0)
  [System.Windows.Controls.Grid]::SetColumn($script:LblMemAdmin, 2); $null = $row2.Children.Add($script:LblMemAdmin)
  $null = $sp.Children.Add($row2)

  $script:LblMemResult = New-Object System.Windows.Controls.TextBlock
  $script:LblMemResult.Text = '每 2 秒自动刷新内存占用。'
  $script:LblMemResult.Foreground = (New-WpfBrush $script:Theme.SubText); $script:LblMemResult.FontSize = 12
  $script:LblMemResult.Margin = (New-WpfThickness 0 12 0 0); $script:LblMemResult.TextWrapping = 'Wrap'
  $null = $sp.Children.Add($script:LblMemResult)

  $card.Child = $sp
  $null = $g.Children.Add($card)

  # 每 2 秒刷新内存占用（DispatcherTimer，轻量 P/Invoke，非 WMI）
  $script:MemTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:MemTimer.Interval = [TimeSpan]::FromSeconds(2)
  $script:MemTimer.Add_Tick({
    try {
      $mi = Get-MemoryInfoText
      if ($mi) {
        $script:LblMemPct.Text = ('{0}%' -f $mi.Pct)
        $script:MemBar.Value = [Math]::Min(100, [Math]::Max(0, $mi.Pct))
        $script:LblMemDetail.Text = ('已用 {0} / 共 {1}' -f (Format-Bytes $mi.UsedBytes), (Format-Bytes $mi.TotalBytes))
      }
    } catch { }
  })
  $script:MemTimer.Start()

  $script:BtnPurgeStandby.Add_Click({
    if (-not (Test-IsAdmin)) {
      try { $null = [System.Windows.MessageBox]::Show('清理待机内存需要管理员权限，请以管理员身份运行本工具。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
      return
    }
    try {
      $st = Invoke-MemoryPurge -Command 5
      if ($st -eq 0) { $script:LblMemResult.Text = ('待机内存已清理 {0}' -f (Get-Date -Format 'HH:mm:ss')) }
      else           { $script:LblMemResult.Text = ('清理失败：NTSTATUS 0x{0:X8}' -f $st) }
      Log-Line ('系统加速: 清理待机内存 NTSTATUS=0x{0:X8}' -f $st)
    } catch {
      $script:LblMemResult.Text = '清理失败：系统不支持该调用'
      Log-Line ('系统加速: 清理待机内存异常 ' + $_.Exception.Message)
    }
  })
  $script:BtnTrimWS.Add_Click({
    if (-not (Test-IsAdmin)) {
      try { $null = [System.Windows.MessageBox]::Show('修剪工作集需要管理员权限，请以管理员身份运行本工具。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
      return
    }
    try {
      $st = Invoke-MemoryPurge -Command 3
      if ($st -eq 0) { $script:LblMemResult.Text = ('工作集已修剪 {0}' -f (Get-Date -Format 'HH:mm:ss')) }
      else           { $script:LblMemResult.Text = ('修剪失败：NTSTATUS 0x{0:X8}' -f $st) }
      Log-Line ('系统加速: 修剪工作集 NTSTATUS=0x{0:X8}' -f $st)
    } catch {
      $script:LblMemResult.Text = '修剪失败：系统不支持该调用'
      Log-Line ('系统加速: 修剪工作集异常 ' + $_.Exception.Message)
    }
  })

  return $g
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
  # 布局：工具栏 44 | 表头+列表；信息展示为主，不提供卸载/删除
  $g = New-Object System.Windows.Controls.Grid
  $r0 = New-Object System.Windows.Controls.RowDefinition; $r0.Height = [System.Windows.GridLength]::new(44)
  $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $null = $g.RowDefinitions.Add($r0); $null = $g.RowDefinitions.Add($r1)

  # ===== 工具栏 =====
  $top = New-Object System.Windows.Controls.Border
  $top.Background = (New-WpfBrush '#FFFFFF'); $top.BorderBrush = (New-WpfBrush $script:Theme.CardLine); $top.BorderThickness = (New-WpfThickness 0 0 0 1)
  $tg = New-Object System.Windows.Controls.Grid
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 刷新
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 计算实际占用
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 状态 *
  $btnSoftRefresh = New-Object System.Windows.Controls.Button
  $btnSoftRefresh.Content = '刷新列表'; $btnSoftRefresh.Margin = (New-WpfThickness 12 0 0 0)
  $btnSoftRefresh.Background = (New-WpfBrush $script:Theme.Primary); $btnSoftRefresh.Foreground = (New-WpfBrush '#FFFFFF')
  $btnSoftRefresh.Padding = (New-WpfThickness 12 4 12 4)
  $null = $tg.Children.Add($btnSoftRefresh)
  $script:BtnSoftReal = New-Object System.Windows.Controls.Button
  $script:BtnSoftReal.Content = '计算实际占用'; $script:BtnSoftReal.Margin = (New-WpfThickness 10 0 0 0)
  $script:BtnSoftReal.Padding = (New-WpfThickness 12 4 12 4)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnSoftReal, 1); $null = $tg.Children.Add($script:BtnSoftReal)
  $script:LblSoft = New-Object System.Windows.Controls.TextBlock
  $script:LblSoft.Text = '信息展示为主，不提供卸载。'; $script:LblSoft.VerticalAlignment = 'Center'; $script:LblSoft.Margin = (New-WpfThickness 16 0 12 0)
  $script:LblSoft.Foreground = (New-WpfBrush $script:Theme.Disabled); $script:LblSoft.FontSize = 12
  $script:LblSoft.TextTrimming = 'CharacterEllipsis'
  [System.Windows.Controls.Grid]::SetColumn($script:LblSoft, 2); $null = $tg.Children.Add($script:LblSoft)
  $top.Child = $tg
  [System.Windows.Controls.Grid]::SetRow($top, 0); $null = $g.Children.Add($top)

  # ===== 表头 + 列表 =====
  $mid = New-Object System.Windows.Controls.Grid
  $mh = New-Object System.Windows.Controls.RowDefinition; $mh.Height = [System.Windows.GridLength]::new(30)
  $ml = New-Object System.Windows.Controls.RowDefinition; $ml.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $null = $mid.RowDefinitions.Add($mh); $null = $mid.RowDefinitions.Add($ml)
  $hdr = New-Object System.Windows.Controls.Border
  $hdr.Background = (New-WpfBrush '#F8F9FA'); $hdr.BorderBrush = (New-WpfBrush '#F0F1F3'); $hdr.BorderThickness = (New-WpfThickness 0 0 0 1)
  $hg = New-Object System.Windows.Controls.Grid
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))                       # 名称 *
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(150)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[2].Width = [System.Windows.GridLength]::new(110)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))                       # 安装位置 *
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[4].Width = [System.Windows.GridLength]::new(90)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[5].Width = [System.Windows.GridLength]::new(110)
  $hCols = @('名称', '发布者', '版本', '安装位置', '注册大小', '实际占用')
  $hKeys = @(
    { param($r) $r.Name },
    { param($r) $r.Publisher },
    { param($r) $r.Version },
    { param($r) $r.Location },
    { param($r) $r.RegKB },
    { param($r) $r.RealBytes }
  )
  $script:SoftSort = @()
  for ($ci = 0; $ci -lt $hCols.Count; $ci++) {
    $ht = New-Object System.Windows.Controls.TextBlock
    $ht.Text = $hCols[$ci]; $ht.FontSize = 11; $ht.FontWeight = [System.Windows.FontWeights]::Bold
    $ht.Foreground = (New-WpfBrush $script:Theme.SubText); $ht.VerticalAlignment = 'Center'
    $ht.Margin = (New-WpfThickness 12 0 6 0)
    [System.Windows.Controls.Grid]::SetColumn($ht, $ci)
    $null = $hg.Children.Add($ht)
    Add-WpfSortHeader -Header $ht -VarName 'SoftRows' -Key $hKeys[$ci] -Render { script:Render-Soft }
    $script:SoftSort += $ht
  }
  $hdr.Child = $hg
  [System.Windows.Controls.Grid]::SetRow($hdr, 0); $null = $mid.Children.Add($hdr)
  $scroll = New-Object System.Windows.Controls.ScrollViewer
  $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
  $scroll.Background = (New-WpfBrush '#FFFFFF')
  $script:SoftList = New-Object System.Windows.Controls.StackPanel
  $scroll.Content = $script:SoftList
  [System.Windows.Controls.Grid]::SetRow($scroll, 1); $null = $mid.Children.Add($scroll)
  [System.Windows.Controls.Grid]::SetRow($mid, 1); $null = $g.Children.Add($mid)

  # ===== 状态 =====
  $script:SoftRows = @()   # 当前行数据（刷新/排序/实际占用都写回这里）
  $script:SoftSel = $null  # 选中的行对象

  # ===== 行助手（6 列 + 单选高亮 + 右键菜单） =====
  function script:New-SoftRow {
    param($It)
    $realTxt = if ($It.RealBytes -gt 0) { Format-Bytes $It.RealBytes } else { '' }
    $regTxt = if ($It.RegKB -gt 0) { Format-Bytes ($It.RegKB * 1024) } else { '' }
    $row = New-Object System.Windows.Controls.Border
    $row.Tag = $It
    $row.Background = (New-WpfBrush $(if ($It -eq $script:SoftSel) { '#EAF3FF' } else { '#FFFFFF' }))
    $row.BorderBrush = (New-WpfBrush '#F0F1F3'); $row.BorderThickness = (New-WpfThickness 0 0 0 1)
    $row.Padding = (New-WpfThickness 12 5 12 5)
    $ig = New-Object System.Windows.Controls.Grid
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(150)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[2].Width = [System.Windows.GridLength]::new(110)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[4].Width = [System.Windows.GridLength]::new(90)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[5].Width = [System.Windows.GridLength]::new(110)
    $tName = New-Object System.Windows.Controls.TextBlock
    $tName.Text = $It.Name; $tName.FontSize = 13; $tName.VerticalAlignment = 'Center'; $tName.TextTrimming = 'CharacterEllipsis'
    $null = $ig.Children.Add($tName)
    $tPub = New-Object System.Windows.Controls.TextBlock
    $tPub.Text = $It.Publisher; $tPub.FontSize = 12; $tPub.VerticalAlignment = 'Center'; $tPub.TextTrimming = 'CharacterEllipsis'
    $tPub.Foreground = (New-WpfBrush $script:Theme.SubText); [System.Windows.Controls.Grid]::SetColumn($tPub, 1); $null = $ig.Children.Add($tPub)
    $tVer = New-Object System.Windows.Controls.TextBlock
    $tVer.Text = $It.Version; $tVer.FontSize = 12; $tVer.VerticalAlignment = 'Center'; $tVer.TextTrimming = 'CharacterEllipsis'
    $tVer.Foreground = (New-WpfBrush $script:Theme.SubText); [System.Windows.Controls.Grid]::SetColumn($tVer, 2); $null = $ig.Children.Add($tVer)
    $tLoc = New-Object System.Windows.Controls.TextBlock
    $tLoc.Text = $It.Location; $tLoc.FontSize = 11; $tLoc.VerticalAlignment = 'Center'; $tLoc.TextTrimming = 'CharacterEllipsis'
    $tLoc.Foreground = (New-WpfBrush $script:Theme.Disabled); [System.Windows.Controls.Grid]::SetColumn($tLoc, 3); $null = $ig.Children.Add($tLoc)
    $tReg = New-Object System.Windows.Controls.TextBlock
    $tReg.Text = $regTxt; $tReg.FontSize = 12; $tReg.VerticalAlignment = 'Center'; $tReg.HorizontalAlignment = 'Right'
    $tReg.Foreground = (New-WpfBrush $script:Theme.SubText); [System.Windows.Controls.Grid]::SetColumn($tReg, 4); $null = $ig.Children.Add($tReg)
    $tReal = New-Object System.Windows.Controls.TextBlock
    $tReal.Text = $realTxt; $tReal.FontSize = 12; $tReal.VerticalAlignment = 'Center'; $tReal.HorizontalAlignment = 'Right'
    $tReal.Foreground = (New-WpfBrush $script:Theme.Text); [System.Windows.Controls.Grid]::SetColumn($tReal, 5); $null = $ig.Children.Add($tReal)
    $row.Child = $ig
    $row.Add_MouseEnter({ param($s, $e) try { if ($s.Tag -ne $script:SoftSel) { $s.Background = (New-WpfBrush '#F4F5F7') } } catch { } })
    $row.Add_MouseLeave({ param($s, $e) try { if ($s.Tag -ne $script:SoftSel) { $s.Background = (New-WpfBrush '#FFFFFF') } } catch { } })
    $row.Add_MouseLeftButtonDown({
      param($s, $e)
      try {
        $script:SoftSel = $s.Tag
        foreach ($ch in $script:SoftList.Children) {
          if ($ch -is [System.Windows.Controls.Border] -and $ch.Tag) {
            $ch.Background = (New-WpfBrush $(if ($ch.Tag -eq $script:SoftSel) { '#EAF3FF' } else { '#FFFFFF' }))
          }
        }
      } catch { }
    })
    $menu = New-Object System.Windows.Controls.ContextMenu
    $miOpen = New-Object System.Windows.Controls.MenuItem; $miOpen.Header = '打开安装目录'; $miOpen.Tag = $It
    $miOpen.Add_Click({ $it = $_.Source.Tag; if ($it.Location) { Open-InExplorer -Path $it.Location } })
    $miCopy = New-Object System.Windows.Controls.MenuItem; $miCopy.Header = '复制安装路径'; $miCopy.Tag = $It
    $miCopy.Add_Click({ $it = $_.Source.Tag; try { [System.Windows.Clipboard]::SetText([string]$it.Location) } catch { } })
    $null = $menu.Items.Add($miOpen); $null = $menu.Items.Add($miCopy)
    $row.ContextMenu = $menu
    return $row
  }

  # ===== 渲染（以 SoftRows 为准） =====
  function script:Render-Soft {
    $script:SoftList.Children.Clear()
    foreach ($s in $script:SoftRows) { $null = $script:SoftList.Children.Add((New-SoftRow -It $s)) }
    $script:LblSoft.Text = ('共 {0} 个已安装软件' -f $script:SoftRows.Count)
  }

  # ===== 计算实际占用 worker（单行；行对象跨 runspace 按引用传递，写回即刷新） =====
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
    try {
      $script:BtnSoftReal.IsEnabled = $true
      if ($e.Error) { Log-Line ('实际占用出错: ' + $e.Error.Message); return }
      $r = $e.Result
      if ($r -and $r.Row) {
        $r.Row.RealBytes = $r.Bytes
        Render-Soft
        Log-Line ('实际占用: {0} = {1}' -f $r.Row.Name, (Format-Bytes $r.Bytes))
      }
    } catch { Log-Line ('实际占用完成处理出错: ' + $_.Exception.Message) }
  })

  $btnSoftRefresh.Add_Click({ Fill-SoftwareList; Log-Line ('软件列表已刷新: {0} 项' -f $script:SoftRows.Count) })
  $script:BtnSoftReal.Add_Click({
    if (-not $script:SoftSel) {
      try { $null = [System.Windows.MessageBox]::Show('请先点击选中要计算占用的一项软件。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
      return
    }
    if (-not $script:SoftSel.Location -or -not (Test-Path -LiteralPath $script:SoftSel.Location)) {
      try { $null = [System.Windows.MessageBox]::Show('该项未记录安装位置，无法计算实际占用。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
      return
    }
    $script:BtnSoftReal.IsEnabled = $false
    $script:SoftWorker.RunWorkerAsync($script:SoftSel)
  })

  # ===== 填充列表（构造即刷；供刷新按钮复用） =====
  function script:Fill-SoftwareList {
    $script:SoftRows = @(Get-InstalledSoftware)
    $script:SoftSel = $null
    Render-Soft
  }
  Fill-SoftwareList

  return $g
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
  # 布局：工具栏 44 | 表头+列表 | 页脚 44；勾选行（默认每组保留 1 个）+ 表头点击排序
  $g = New-Object System.Windows.Controls.Grid
  $r0 = New-Object System.Windows.Controls.RowDefinition; $r0.Height = [System.Windows.GridLength]::new(44)
  $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = [System.Windows.GridLength]::new(44)
  $null = $g.RowDefinitions.Add($r0); $null = $g.RowDefinitions.Add($r1); $null = $g.RowDefinitions.Add($r2)

  # ===== 工具栏 =====
  $top = New-Object System.Windows.Controls.Border
  $top.Background = (New-WpfBrush '#FFFFFF'); $top.BorderBrush = (New-WpfBrush $script:Theme.CardLine); $top.BorderThickness = (New-WpfThickness 0 0 0 1)
  $tg = New-Object System.Windows.Controls.Grid
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 目录标签
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 目录框 *
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 浏览
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 开始检测
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 停止
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 进度
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 状态
  $lblDir = New-Object System.Windows.Controls.TextBlock
  $lblDir.Text = '目录:'; $lblDir.VerticalAlignment = 'Center'; $lblDir.Margin = (New-WpfThickness 12 0 0 0)
  $null = $tg.Children.Add($lblDir)
  $script:TxtDupDir = New-Object System.Windows.Controls.TextBox
  $script:TxtDupDir.Text = $env:USERPROFILE; $script:TxtDupDir.VerticalAlignment = 'Center'; $script:TxtDupDir.Margin = (New-WpfThickness 8 0 0 0)
  $script:TxtDupDir.Padding = (New-WpfThickness 4 2 4 2)
  [System.Windows.Controls.Grid]::SetColumn($script:TxtDupDir, 1); $null = $tg.Children.Add($script:TxtDupDir)
  $btnDupBrowse = New-Object System.Windows.Controls.Button
  $btnDupBrowse.Content = '浏览'; $btnDupBrowse.Margin = (New-WpfThickness 8 0 0 0); $btnDupBrowse.Padding = (New-WpfThickness 8 4 8 4)
  [System.Windows.Controls.Grid]::SetColumn($btnDupBrowse, 2); $null = $tg.Children.Add($btnDupBrowse)
  $script:BtnDupScan = New-Object System.Windows.Controls.Button
  $script:BtnDupScan.Content = '开始检测'; $script:BtnDupScan.Margin = (New-WpfThickness 10 0 0 0)
  $script:BtnDupScan.Background = (New-WpfBrush $script:Theme.Primary); $script:BtnDupScan.Foreground = (New-WpfBrush '#FFFFFF')
  $script:BtnDupScan.Padding = (New-WpfThickness 12 4 12 4)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnDupScan, 3); $null = $tg.Children.Add($script:BtnDupScan)
  $script:BtnDupStop = New-Object System.Windows.Controls.Button
  $script:BtnDupStop.Content = '停止'; $script:BtnDupStop.IsEnabled = $false; $script:BtnDupStop.Margin = (New-WpfThickness 8 0 0 0)
  $script:BtnDupStop.Padding = (New-WpfThickness 10 4 10 4)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnDupStop, 4); $null = $tg.Children.Add($script:BtnDupStop)
  $script:ProgD = New-Object System.Windows.Controls.ProgressBar
  $script:ProgD.Width = 200; $script:ProgD.Height = 8; $script:ProgD.VerticalAlignment = 'Center'; $script:ProgD.Margin = (New-WpfThickness 14 0 0 0)
  $script:ProgD.Foreground = (New-WpfBrush $script:Theme.Primary); $script:ProgD.Background = (New-WpfBrush '#EEF0F2')
  [System.Windows.Controls.Grid]::SetColumn($script:ProgD, 5); $null = $tg.Children.Add($script:ProgD)
  $script:LblD = New-Object System.Windows.Controls.TextBlock
  $script:LblD.Text = '就绪'; $script:LblD.VerticalAlignment = 'Center'; $script:LblD.Margin = (New-WpfThickness 12 0 0 0)
  $script:LblD.Foreground = (New-WpfBrush $script:Theme.SubText); $script:LblD.FontSize = 12
  [System.Windows.Controls.Grid]::SetColumn($script:LblD, 6); $null = $tg.Children.Add($script:LblD)
  $top.Child = $tg
  [System.Windows.Controls.Grid]::SetRow($top, 0); $null = $g.Children.Add($top)

  # ===== 表头 + 列表 =====
  $mid = New-Object System.Windows.Controls.Grid
  $mh = New-Object System.Windows.Controls.RowDefinition; $mh.Height = [System.Windows.GridLength]::new(30)
  $ml = New-Object System.Windows.Controls.RowDefinition; $ml.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $null = $mid.RowDefinitions.Add($mh); $null = $mid.RowDefinitions.Add($ml)
  $hdr = New-Object System.Windows.Controls.Border
  $hdr.Background = (New-WpfBrush '#F8F9FA'); $hdr.BorderBrush = (New-WpfBrush '#F0F1F3'); $hdr.BorderThickness = (New-WpfThickness 0 0 0 1)
  $hg = New-Object System.Windows.Controls.Grid
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new(26)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(60)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[2].Width = [System.Windows.GridLength]::new(110)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[3].Width = [System.Windows.GridLength]::new(80)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))   # 路径 *
  $hCols = @('', '组', '大小', '状态', '路径')
  $hKeys = @(
    { param($r) 0 },
    { param($r) $r.Group },
    { param($r) $r.Size },
    { param($r) if ($r.Keep) { 1 } else { 0 } },
    { param($r) $r.Path }
  )
  $script:DupSort = @()
  for ($ci = 1; $ci -lt $hCols.Count; $ci++) {
    $ht = New-Object System.Windows.Controls.TextBlock
    $ht.Text = $hCols[$ci]; $ht.FontSize = 11; $ht.FontWeight = [System.Windows.FontWeights]::Bold
    $ht.Foreground = (New-WpfBrush $script:Theme.SubText); $ht.VerticalAlignment = 'Center'
    $ht.Margin = (New-WpfThickness 12 0 6 0)
    [System.Windows.Controls.Grid]::SetColumn($ht, $ci)
    $null = $hg.Children.Add($ht)
    Add-WpfSortHeader -Header $ht -VarName 'DupRows' -Key $hKeys[$ci] -Render { script:Render-Dup }
    $script:DupSort += $ht
  }
  $hdr.Child = $hg
  [System.Windows.Controls.Grid]::SetRow($hdr, 0); $null = $mid.Children.Add($hdr)
  $scroll = New-Object System.Windows.Controls.ScrollViewer
  $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
  $scroll.Background = (New-WpfBrush '#FFFFFF')
  $script:DupList = New-Object System.Windows.Controls.StackPanel
  $scroll.Content = $script:DupList
  [System.Windows.Controls.Grid]::SetRow($scroll, 1); $null = $mid.Children.Add($scroll)
  [System.Windows.Controls.Grid]::SetRow($mid, 1); $null = $g.Children.Add($mid)

  # ===== 页脚 =====
  $foot = New-Object System.Windows.Controls.Border
  $foot.Background = (New-WpfBrush '#FFFFFF'); $foot.BorderBrush = (New-WpfBrush $script:Theme.CardLine); $foot.BorderThickness = (New-WpfThickness 0 1 0 0)
  $fg = New-Object System.Windows.Controls.Grid
  $null = $fg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $fg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $script:LblDupInfo = New-Object System.Windows.Controls.TextBlock
  $script:LblDupInfo.Text = '默认每组保留 1 个副本，其余已勾选待删除。'
  $script:LblDupInfo.VerticalAlignment = 'Center'; $script:LblDupInfo.Margin = (New-WpfThickness 12 0 0 0); $script:LblDupInfo.FontSize = 12
  $script:LblDupInfo.Foreground = (New-WpfBrush $script:Theme.SubText); $script:LblDupInfo.TextTrimming = 'CharacterEllipsis'
  $null = $fg.Children.Add($script:LblDupInfo)
  $script:BtnDupDel = New-Object System.Windows.Controls.Button
  $script:BtnDupDel.Content = '删除勾选(回收站)'
  $script:BtnDupDel.Background = (New-WpfBrush $script:Theme.Red); $script:BtnDupDel.Foreground = (New-WpfBrush '#FFFFFF')
  $script:BtnDupDel.Padding = (New-WpfThickness 12 4 12 4); $script:BtnDupDel.HorizontalAlignment = 'Right'; $script:BtnDupDel.Margin = (New-WpfThickness 0 0 12 0)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnDupDel, 1); $null = $fg.Children.Add($script:BtnDupDel)
  $foot.Child = $fg
  [System.Windows.Controls.Grid]::SetRow($foot, 2); $null = $g.Children.Add($foot)

  # ===== 状态 =====
  $script:DupRows = @()       # 当前行数据（排序/删除都写回这里）
  $script:DupCheckboxes = @() # 每行勾选框（删除时收集勾选）

  # ===== 行助手（勾选框 + 4 列） =====
  function script:New-DupRow {
    param($It)
    $row = New-Object System.Windows.Controls.Border
    $row.Tag = $It
    $row.Background = (New-WpfBrush '#FFFFFF')
    $row.BorderBrush = (New-WpfBrush '#F0F1F3'); $row.BorderThickness = (New-WpfThickness 0 0 0 1)
    $row.Padding = (New-WpfThickness 12 5 12 5)
    $ig = New-Object System.Windows.Controls.Grid
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new(26)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(60)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[2].Width = [System.Windows.GridLength]::new(110)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[3].Width = [System.Windows.GridLength]::new(80)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Tag = $It; $cb.VerticalAlignment = 'Center'; $cb.IsChecked = (-not $It.Keep)
    $null = $ig.Children.Add($cb)
    $script:DupCheckboxes += $cb
    $tGrp = New-Object System.Windows.Controls.TextBlock
    $tGrp.Text = [string]$It.Group; $tGrp.FontSize = 12; $tGrp.VerticalAlignment = 'Center'
    $tGrp.Foreground = (New-WpfBrush $script:Theme.SubText); [System.Windows.Controls.Grid]::SetColumn($tGrp, 1); $null = $ig.Children.Add($tGrp)
    $tSize = New-Object System.Windows.Controls.TextBlock
    $tSize.Text = Format-Bytes $It.Size; $tSize.FontSize = 12; $tSize.VerticalAlignment = 'Center'; $tSize.HorizontalAlignment = 'Right'
    $tSize.Foreground = (New-WpfBrush $script:Theme.Text); [System.Windows.Controls.Grid]::SetColumn($tSize, 2); $null = $ig.Children.Add($tSize)
    $tSt = New-Object System.Windows.Controls.TextBlock
    $tSt.Text = $(if ($It.Keep) { '保留' } else { '待删' }); $tSt.FontSize = 12; $tSt.VerticalAlignment = 'Center'
    $tSt.Foreground = (New-WpfBrush $(if ($It.Keep) { $script:Theme.Green } else { $script:Theme.Yellow }))
    [System.Windows.Controls.Grid]::SetColumn($tSt, 3); $null = $ig.Children.Add($tSt)
    $tPath = New-Object System.Windows.Controls.TextBlock
    $tPath.Text = $It.Path; $tPath.FontSize = 11; $tPath.VerticalAlignment = 'Center'; $tPath.TextTrimming = 'CharacterEllipsis'
    $tPath.Foreground = (New-WpfBrush $script:Theme.Disabled); [System.Windows.Controls.Grid]::SetColumn($tPath, 4); $null = $ig.Children.Add($tPath)
    $row.Child = $ig
    $row.Add_MouseEnter({ param($s, $e) try { $s.Background = (New-WpfBrush '#F4F5F7') } catch { } })
    $row.Add_MouseLeave({ param($s, $e) try { $s.Background = (New-WpfBrush '#FFFFFF') } catch { } })
    return $row
  }

  # ===== 渲染（以 DupRows 为准） =====
  function script:Render-Dup {
    $script:DupList.Children.Clear(); $script:DupCheckboxes = @()
    foreach ($r in $script:DupRows) { $null = $script:DupList.Children.Add((New-DupRow -It $r)) }
    $grp = @($script:DupRows | ForEach-Object { $_.Group } | Sort-Object -Unique).Count
    $script:LblDupInfo.Text = ('发现 {0} 组重复文件，共 {1} 个副本（每组保留 1 个）' -f $grp, $script:DupRows.Count)
  }

  # ===== 删除（以"删前存在删后不在"判成功；失败行保留在列表） =====
  function script:Remove-DupFiles {
    param($Items)
    if ($Items.Count -eq 0) { return }
    $r = [System.Windows.MessageBox]::Show(('确定将 {0} 个重复文件删除到回收站？（每组至少保留 1 个副本，请勿取消"保留"项）' -f $Items.Count), '确认删除', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $rel = 0L; $ok = 0; $gone = @()
    foreach ($it in $Items) {
      $existed = Test-Path -LiteralPath $it.Path
      $b = Remove-UserPathToRecycle $it.Path
      if ($existed -and -not (Test-Path -LiteralPath $it.Path)) { $ok++; $rel += $b; $gone += $it.Path }
    }
    Log-Line ('重复文件删除: 成功 {0}/{1}, 释放 {2}' -f $ok, $Items.Count, (Format-Bytes $rel))
    if ($gone.Count -gt 0) {
      $script:DupRows = @($script:DupRows | Where-Object { $gone -notcontains $_.Path })
      Render-Dup
    }
    try {
      $null = [System.Windows.MessageBox]::Show(('已删除 {0} 个重复文件，释放 {1}；占用/受保护自动跳过。' -f $ok, (Format-Bytes $rel)), '完成', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    } catch { }
  }

  # ===== 检测 worker =====
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
    try { $script:LblD.Text = [string]$e.UserState } catch { }
  })
  $script:DupWorker.add_RunWorkerCompleted({
    param($s, $e)
    try {
      $script:BtnDupScan.IsEnabled = $true; $script:BtnDupStop.IsEnabled = $false
      $script:ProgD.IsIndeterminate = $false; $script:ProgD.Value = 0
      if ($e.Error) { $script:LblD.Text = '检测出错'; Log-Line ('重复文件检测出错: ' + $e.Error.Message); return }
      if ($e.Cancelled) { $script:LblD.Text = '已取消'; return }
      $script:DupRows = @($e.Result)
      Render-Dup
      $script:LblD.Text = '完成'
      $grp = @($script:DupRows | ForEach-Object { $_.Group } | Sort-Object -Unique).Count
      Log-Line ('重复文件检测完成: {0} 组 / {1} 文件' -f $grp, $script:DupRows.Count)
    } catch { Log-Line ('重复文件完成处理出错: ' + $_.Exception.Message) }
  })

  $btnDupBrowse.Add_Click({
    try {
      $d = New-Object Microsoft.Win32.OpenFolderDialog
      $d.Title = '选择要检测重复文件的目录'
      if ($script:TxtDupDir.Text) { $d.InitialDirectory = $script:TxtDupDir.Text }
      if ($d.ShowDialog()) { $script:TxtDupDir.Text = $d.FolderName }
    } catch { }
  })
  $script:BtnDupScan.Add_Click({
    $root = $script:TxtDupDir.Text.Trim()
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
      try { $null = [System.Windows.MessageBox]::Show('请输入存在的目录。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
      return
    }
    $script:BtnDupScan.IsEnabled = $false; $script:BtnDupStop.IsEnabled = $true
    $script:ProgD.IsIndeterminate = $true; $script:LblD.Text = '检测中...'
    $script:DupList.Children.Clear(); $script:DupRows = @(); $script:DupCheckboxes = @()
    $script:LblDupInfo.Text = '默认每组保留 1 个副本，其余已勾选待删除。'
    Log-Line ('重复文件检测开始: ' + $root)
    $script:DupWorker.RunWorkerAsync($root)
  })
  $script:BtnDupStop.Add_Click({ if ($script:DupWorker) { $script:DupWorker.CancelAsync() } })
  $script:BtnDupDel.Add_Click({
    $sel = @($script:DupCheckboxes | Where-Object { $_.IsChecked -and $_.Tag } | ForEach-Object { $_.Tag })
    if ($sel.Count -eq 0) {
      try { $null = [System.Windows.MessageBox]::Show('没有勾选要删除的文件。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
      return
    }
    Remove-DupFiles -Items $sel
  })

  return $g
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
  # 布局：工具栏 44（刷新 / 删除旧还原点 / 状态）| 表头+列表
  $g = New-Object System.Windows.Controls.Grid
  $r0 = New-Object System.Windows.Controls.RowDefinition; $r0.Height = [System.Windows.GridLength]::new(44)
  $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $null = $g.RowDefinitions.Add($r0); $null = $g.RowDefinitions.Add($r1)

  # ===== 工具栏 =====
  $top = New-Object System.Windows.Controls.Border
  $top.Background = (New-WpfBrush '#FFFFFF'); $top.BorderBrush = (New-WpfBrush $script:Theme.CardLine); $top.BorderThickness = (New-WpfThickness 0 0 0 1)
  $tg = New-Object System.Windows.Controls.Grid
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $btnRPRefresh = New-Object System.Windows.Controls.Button
  $btnRPRefresh.Content = '刷新'; $btnRPRefresh.Margin = (New-WpfThickness 12 0 0 0)
  $btnRPRefresh.Background = (New-WpfBrush $script:Theme.Primary); $btnRPRefresh.Foreground = (New-WpfBrush '#FFFFFF')
  $btnRPRefresh.Padding = (New-WpfThickness 12 4 12 4)
  $null = $tg.Children.Add($btnRPRefresh)
  $script:BtnRPDelete = New-Object System.Windows.Controls.Button
  $script:BtnRPDelete.Content = '删除旧还原点(保留最近3个)'; $script:BtnRPDelete.Margin = (New-WpfThickness 10 0 0 0)
  $script:BtnRPDelete.Background = (New-WpfBrush $script:Theme.Red); $script:BtnRPDelete.Foreground = (New-WpfBrush '#FFFFFF')
  $script:BtnRPDelete.Padding = (New-WpfThickness 12 4 12 4)
  [System.Windows.Controls.Grid]::SetColumn($script:BtnRPDelete, 1); $null = $tg.Children.Add($script:BtnRPDelete)
  $script:LblRPStatus = New-Object System.Windows.Controls.TextBlock
  $script:LblRPStatus.Text = '检测中...'; $script:LblRPStatus.VerticalAlignment = 'Center'
  $script:LblRPStatus.Foreground = (New-WpfBrush $script:Theme.Text); $script:LblRPStatus.FontSize = 12
  $script:LblRPStatus.Margin = (New-WpfThickness 16 0 12 0); $script:LblRPStatus.TextTrimming = 'CharacterEllipsis'
  [System.Windows.Controls.Grid]::SetColumn($script:LblRPStatus, 2); $null = $tg.Children.Add($script:LblRPStatus)
  $top.Child = $tg
  [System.Windows.Controls.Grid]::SetRow($top, 0); $null = $g.Children.Add($top)

  # ===== 表头 + 列表 =====
  $mid = New-Object System.Windows.Controls.Grid
  $mh = New-Object System.Windows.Controls.RowDefinition; $mh.Height = [System.Windows.GridLength]::new(30)
  $ml = New-Object System.Windows.Controls.RowDefinition; $ml.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $null = $mid.RowDefinitions.Add($mh); $null = $mid.RowDefinitions.Add($ml)
  $hdr = New-Object System.Windows.Controls.Border
  $hdr.Background = (New-WpfBrush '#F8F9FA'); $hdr.BorderBrush = (New-WpfBrush '#F0F1F3'); $hdr.BorderThickness = (New-WpfThickness 0 0 0 1)
  $hg = New-Object System.Windows.Controls.Grid
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new(90)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(170)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))                       # 描述 *
  $hCols = @('序号', '创建时间', '描述')
  $hKeys = @(
    { param($r) [int]$r.SequenceNumber },
    { param($r) $r.CreationTime },
    { param($r) $r.Description }
  )
  $script:RPSort = @()
  for ($ci = 0; $ci -lt $hCols.Count; $ci++) {
    $ht = New-Object System.Windows.Controls.TextBlock
    $ht.Text = $hCols[$ci]; $ht.FontSize = 11; $ht.FontWeight = [System.Windows.FontWeights]::Bold
    $ht.Foreground = (New-WpfBrush $script:Theme.SubText); $ht.VerticalAlignment = 'Center'
    $ht.Margin = (New-WpfThickness 12 0 6 0)
    [System.Windows.Controls.Grid]::SetColumn($ht, $ci)
    $null = $hg.Children.Add($ht)
    Add-WpfSortHeader -Header $ht -VarName 'RPRows' -Key $hKeys[$ci] -Render { script:Render-RP }
    $script:RPSort += $ht
  }
  $hdr.Child = $hg
  [System.Windows.Controls.Grid]::SetRow($hdr, 0); $null = $mid.Children.Add($hdr)
  $scroll = New-Object System.Windows.Controls.ScrollViewer
  $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
  $scroll.Background = (New-WpfBrush '#FFFFFF')
  $script:RPList = New-Object System.Windows.Controls.StackPanel
  $scroll.Content = $script:RPList
  [System.Windows.Controls.Grid]::SetRow($scroll, 1); $null = $mid.Children.Add($scroll)
  [System.Windows.Controls.Grid]::SetRow($mid, 1); $null = $g.Children.Add($mid)

  # ===== 状态 =====
  $script:RPRows = @()

  # ===== 行助手 =====
  function script:New-RPRow {
    param($It)
    $row = New-Object System.Windows.Controls.Border
    $row.Tag = $It
    $row.Background = (New-WpfBrush '#FFFFFF')
    $row.BorderBrush = (New-WpfBrush '#F0F1F3'); $row.BorderThickness = (New-WpfThickness 0 0 0 1)
    $row.Padding = (New-WpfThickness 12 5 12 5)
    $ig = New-Object System.Windows.Controls.Grid
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new(90)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(170)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $tSeq = New-Object System.Windows.Controls.TextBlock
    $tSeq.Text = [string]$It.SequenceNumber; $tSeq.FontSize = 12; $tSeq.VerticalAlignment = 'Center'
    $tSeq.Foreground = (New-WpfBrush $script:Theme.Text)
    $null = $ig.Children.Add($tSeq)
    $tTime = New-Object System.Windows.Controls.TextBlock
    $tTime.Text = $(if ($It.CreationTime) { $It.CreationTime.ToString('yyyy-MM-dd HH:mm') } else { '-' })
    $tTime.FontSize = 12; $tTime.VerticalAlignment = 'Center'
    $tTime.Foreground = (New-WpfBrush $script:Theme.Text); [System.Windows.Controls.Grid]::SetColumn($tTime, 1); $null = $ig.Children.Add($tTime)
    $tDesc = New-Object System.Windows.Controls.TextBlock
    $tDesc.Text = $It.Description; $tDesc.FontSize = 12; $tDesc.VerticalAlignment = 'Center'
    $tDesc.Foreground = (New-WpfBrush $script:Theme.SubText); $tDesc.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetColumn($tDesc, 2); $null = $ig.Children.Add($tDesc)
    $row.Child = $ig
    return $row
  }

  function script:Render-RP {
    $script:RPList.Children.Clear()
    foreach ($r in $script:RPRows) { $null = $script:RPList.Children.Add((New-RPRow -It $r)) }
  }

  function script:Fill-RestoreList {
    $pts = @(Get-RestorePoints)
    $script:RPRows = @()
    if ($pts.Count -eq 0) {
      $script:LblRPStatus.Text = '系统还原不可用或无还原点（本机服务未启用）'
      $script:LblRPStatus.Foreground = (New-WpfBrush $script:Theme.Yellow)
      $script:BtnRPDelete.IsEnabled = $false
    } else {
      foreach ($rp in ($pts | Sort-Object CreationTime -Descending)) {
        # CreationTime 可能是 WMI 字符串日期（如 20260924...+480），须先转 DateTime
        try { $dt = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$rp.CreationTime) } catch {
          try { $dt = [datetime]$rp.CreationTime } catch { $dt = $null }
        }
        $script:RPRows += [pscustomobject]@{ SequenceNumber = [int]$rp.SequenceNumber; CreationTime = $dt; Description = [string]$rp.Description }
      }
      $script:LblRPStatus.Text = ('系统还原可用：共 {0} 个还原点' -f $pts.Count)
      $script:LblRPStatus.Foreground = (New-WpfBrush $script:Theme.Green)
      $script:BtnRPDelete.IsEnabled = $pts.Count -gt 3
    }
    Render-RP
  }

  $btnRPRefresh.Add_Click({ Fill-RestoreList })
  $script:BtnRPDelete.Add_Click({
    $r1 = [System.Windows.MessageBox]::Show('删除旧还原点后无法恢复被删除的系统快照！确定继续？', '危险操作', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($r1 -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $r2 = [System.Windows.MessageBox]::Show('再次确认：将删除除最近 3 个外的全部还原点？', '最终确认', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($r2 -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $del = Remove-OldRestorePoints
    Log-Line ('还原点清理: 删除 {0} 个' -f $del)
    Fill-RestoreList
    try { $null = [System.Windows.MessageBox]::Show(('已删除 {0} 个旧还原点。' -f $del), '完成', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
  })

  Fill-RestoreList
  return $g
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
  # 布局：工具栏 44（刷新 / 打开启动文件夹 / 备份reg / 计数）| 表头+列表
  $g = New-Object System.Windows.Controls.Grid
  $r0 = New-Object System.Windows.Controls.RowDefinition; $r0.Height = [System.Windows.GridLength]::new(44)
  $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $null = $g.RowDefinitions.Add($r0); $null = $g.RowDefinitions.Add($r1)

  # ===== 工具栏 =====
  $top = New-Object System.Windows.Controls.Border
  $top.Background = (New-WpfBrush '#FFFFFF'); $top.BorderBrush = (New-WpfBrush $script:Theme.CardLine); $top.BorderThickness = (New-WpfThickness 0 0 0 1)
  $tg = New-Object System.Windows.Controls.Grid
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $null = $tg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $btnStRefresh = New-Object System.Windows.Controls.Button
  $btnStRefresh.Content = '刷新'; $btnStRefresh.Margin = (New-WpfThickness 12 0 0 0)
  $btnStRefresh.Background = (New-WpfBrush $script:Theme.Primary); $btnStRefresh.Foreground = (New-WpfBrush '#FFFFFF')
  $btnStRefresh.Padding = (New-WpfThickness 12 4 12 4)
  $null = $tg.Children.Add($btnStRefresh)
  $btnStOpen = New-Object System.Windows.Controls.Button
  $btnStOpen.Content = '打开启动文件夹'; $btnStOpen.Margin = (New-WpfThickness 10 0 0 0)
  $btnStOpen.Padding = (New-WpfThickness 12 4 12 4)
  [System.Windows.Controls.Grid]::SetColumn($btnStOpen, 1); $null = $tg.Children.Add($btnStOpen)
  $btnStBackup = New-Object System.Windows.Controls.Button
  $btnStBackup.Content = '备份注册表项(.reg)'; $btnStBackup.Margin = (New-WpfThickness 10 0 0 0)
  $btnStBackup.Padding = (New-WpfThickness 12 4 12 4)
  [System.Windows.Controls.Grid]::SetColumn($btnStBackup, 2); $null = $tg.Children.Add($btnStBackup)
  $script:LblSt = New-Object System.Windows.Controls.TextBlock
  $script:LblSt.Text = '信息展示为主；修改请用系统"任务管理器>启动"或 msconfig。'
  $script:LblSt.VerticalAlignment = 'Center'; $script:LblSt.Margin = (New-WpfThickness 16 0 12 0)
  $script:LblSt.Foreground = (New-WpfBrush $script:Theme.Disabled); $script:LblSt.FontSize = 12
  $script:LblSt.TextTrimming = 'CharacterEllipsis'
  [System.Windows.Controls.Grid]::SetColumn($script:LblSt, 3); $null = $tg.Children.Add($script:LblSt)
  $top.Child = $tg
  [System.Windows.Controls.Grid]::SetRow($top, 0); $null = $g.Children.Add($top)

  # ===== 表头 + 列表 =====
  $mid = New-Object System.Windows.Controls.Grid
  $mh = New-Object System.Windows.Controls.RowDefinition; $mh.Height = [System.Windows.GridLength]::new(30)
  $ml = New-Object System.Windows.Controls.RowDefinition; $ml.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $null = $mid.RowDefinitions.Add($mh); $null = $mid.RowDefinitions.Add($ml)
  $hdr = New-Object System.Windows.Controls.Border
  $hdr.Background = (New-WpfBrush '#F8F9FA'); $hdr.BorderBrush = (New-WpfBrush '#F0F1F3'); $hdr.BorderThickness = (New-WpfThickness 0 0 0 1)
  $hg = New-Object System.Windows.Controls.Grid
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new(150)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(200)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $hg.ColumnDefinitions[2].Width = [System.Windows.GridLength]::new(60)
  $null = $hg.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))                       # 命令 *
  $hCols = @('来源', '名称', '状态', '命令')
  $hKeys = @(
    { param($r) $r.Source },
    { param($r) $r.Name },
    { param($r) $r.Status },
    { param($r) $r.Command }
  )
  $script:StSort = @()
  for ($ci = 0; $ci -lt $hCols.Count; $ci++) {
    $ht = New-Object System.Windows.Controls.TextBlock
    $ht.Text = $hCols[$ci]; $ht.FontSize = 11; $ht.FontWeight = [System.Windows.FontWeights]::Bold
    $ht.Foreground = (New-WpfBrush $script:Theme.SubText); $ht.VerticalAlignment = 'Center'
    $ht.Margin = (New-WpfThickness 12 0 6 0)
    [System.Windows.Controls.Grid]::SetColumn($ht, $ci)
    $null = $hg.Children.Add($ht)
    Add-WpfSortHeader -Header $ht -VarName 'StRows' -Key $hKeys[$ci] -Render { script:Render-St }
    $script:StSort += $ht
  }
  $hdr.Child = $hg
  [System.Windows.Controls.Grid]::SetRow($hdr, 0); $null = $mid.Children.Add($hdr)
  $scroll = New-Object System.Windows.Controls.ScrollViewer
  $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
  $scroll.Background = (New-WpfBrush '#FFFFFF')
  $script:StList = New-Object System.Windows.Controls.StackPanel
  $scroll.Content = $script:StList
  [System.Windows.Controls.Grid]::SetRow($scroll, 1); $null = $mid.Children.Add($scroll)
  [System.Windows.Controls.Grid]::SetRow($mid, 1); $null = $g.Children.Add($mid)

  # ===== 状态 =====
  $script:StRows = @()

  # ===== 行助手 =====
  function script:New-StRow {
    param($It)
    $row = New-Object System.Windows.Controls.Border
    $row.Tag = $It
    $row.Background = (New-WpfBrush '#FFFFFF')
    $row.BorderBrush = (New-WpfBrush '#F0F1F3'); $row.BorderThickness = (New-WpfThickness 0 0 0 1)
    $row.Padding = (New-WpfThickness 12 5 12 5)
    $ig = New-Object System.Windows.Controls.Grid
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new(150)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(200)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)); $ig.ColumnDefinitions[2].Width = [System.Windows.GridLength]::new(60)
    $null = $ig.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $tSrc = New-Object System.Windows.Controls.TextBlock
    $tSrc.Text = [string]$It.Source; $tSrc.FontSize = 12; $tSrc.VerticalAlignment = 'Center'
    $tSrc.Foreground = (New-WpfBrush $script:Theme.SubText); $tSrc.TextTrimming = 'CharacterEllipsis'
    $null = $ig.Children.Add($tSrc)
    $tName = New-Object System.Windows.Controls.TextBlock
    $tName.Text = [string]$It.Name; $tName.FontSize = 12; $tName.VerticalAlignment = 'Center'
    $tName.Foreground = (New-WpfBrush $script:Theme.Text); $tName.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetColumn($tName, 1); $null = $ig.Children.Add($tName)
    $tStatus = New-Object System.Windows.Controls.TextBlock
    $tStatus.Text = [string]$It.Status; $tStatus.FontSize = 12; $tStatus.VerticalAlignment = 'Center'
    $tStatus.Foreground = (New-WpfBrush $script:Theme.Green); [System.Windows.Controls.Grid]::SetColumn($tStatus, 2); $null = $ig.Children.Add($tStatus)
    $tCmd = New-Object System.Windows.Controls.TextBlock
    $tCmd.Text = [string]$It.Command; $tCmd.FontSize = 11; $tCmd.VerticalAlignment = 'Center'
    $tCmd.Foreground = (New-WpfBrush $script:Theme.Disabled); $tCmd.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetColumn($tCmd, 3); $null = $ig.Children.Add($tCmd)
    $row.Child = $ig
    # 右键：复制命令
    $menu = New-Object System.Windows.Controls.ContextMenu
    $miCopy = New-Object System.Windows.Controls.MenuItem; $miCopy.Header = '复制命令'; $miCopy.Tag = $It
    $miCopy.Add_Click({ $it = $_.Source.Tag; try { [System.Windows.Clipboard]::SetText([string]$it.Command) } catch { } })
    $null = $menu.Items.Add($miCopy)
    $row.ContextMenu = $menu
    return $row
  }

  function script:Render-St {
    $script:StList.Children.Clear()
    foreach ($r in $script:StRows) { $null = $script:StList.Children.Add((New-StRow -It $r)) }
    $script:LblSt.Text = ('共 {0} 个启动项' -f $script:StRows.Count)
  }

  function script:Fill-StartupList {
    $script:StRows = @(Get-StartupItems)
    Render-St
  }

  $btnStRefresh.Add_Click({ Fill-StartupList })
  $btnStOpen.Add_Click({
    try { Start-Process explorer.exe -ArgumentList ($env:APPDATA + '\Microsoft\Windows\Start Menu\Programs\Startup') } catch { }
  })
  $btnStBackup.Add_Click({
    $files = @(Backup-StartupReg)
    if ($files.Count -gt 0) {
      Log-Line ('启动项备份: ' + ($files -join '; '))
      try { $null = [System.Windows.MessageBox]::Show(('已备份到: ' + ($files -join "`r`n")), '备份完成', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
    } else {
      try { $null = [System.Windows.MessageBox]::Show('备份失败（注册表导出未生成文件）。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) } catch { }
    }
  })

  Fill-StartupList
  return $g
}
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

  # ---- 事件：主清理页逻辑在 New-CleanPage 内，操作条在此接线 ----
  $script:BtnScan.Add_Click({ Start-Scan })
  $btnClearCache.Add_Click({
    $script:SizeCache = @{}
    $p = Join-Path $script:DataDir 'size-cache.json'
    if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    Log-Line '已清空扫描缓存，下次扫描全量实测'
    Start-Scan
  })
  $script:BtnCancelScan.Add_Click({ if ($script:ScanWorker) { $script:ScanWorker.CancelAsync() } })

  $btnAll.Add_Click({
    $script:SuppressPrompt = $true
    try { foreach ($cb in $script:CleanCheckboxes) { $cb.IsChecked = $true } } finally { $script:SuppressPrompt = $false }
    Update-Total
  })
  $btnNone.Add_Click({
    $script:SuppressPrompt = $true
    try { foreach ($cb in $script:CleanCheckboxes) { $cb.IsChecked = $false } } finally { $script:SuppressPrompt = $false }
    Update-Total
  })
  $btnLow.Add_Click({
    $script:SuppressPrompt = $true
    try { foreach ($cb in $script:CleanCheckboxes) { $cb.IsChecked = ($cb.Tag -and $cb.Tag.Item.risk -eq 'green') } } finally { $script:SuppressPrompt = $false }
    Update-Total
  })
  $btnSafe.Add_Click({
    $script:SuppressPrompt = $true
    try { foreach ($cb in $script:CleanCheckboxes) { $cb.IsChecked = ($cb.Tag -and $cb.Tag.Item.risk -ne 'red') } } finally { $script:SuppressPrompt = $false }
    Update-Total
  })

  $script:RestoringMode = $false
  $script:RbPermanent.Add_Checked({
    $script:Settings.DeleteMode = 'Permanent'
    Save-Settings
    if ($script:RestoringMode) { return }
    try {
      $null = [System.Windows.MessageBox]::Show('你已切换到【永久删除】模式：清理后文件无法从回收站恢复，请谨慎操作！', '警告', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    } catch { }
  })
  $script:RbPermanent.Add_Unchecked({
    $script:Settings.DeleteMode = 'Recycle'
    Save-Settings
  })

  $script:BtnClean.Add_Click({
    $checked = @($script:CleanCheckboxes | Where-Object { $_.IsChecked -and $_.Tag } | ForEach-Object { $_.Tag.Item })
    if ($checked.Count -eq 0) {
      try { $null = [System.Windows.MessageBox]::Show('请先勾选要清理的项目。', '提示', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) } catch { }
      return
    }
    $mode = if ($script:RbPermanent.IsChecked) { 'Permanent' } else { 'Recycle' }
    if ($mode -eq 'Permanent') {
      $r = [System.Windows.MessageBox]::Show('你选择了【永久删除】！文件将无法从回收站恢复。确认继续？', '危险操作', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
      if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    $reds = @($checked | Where-Object { $_.risk -eq 'red' })
    if ($reds.Count -gt 0) {
      $names = ($reds | ForEach-Object { $_.name }) -join '、'
      $r = [System.Windows.MessageBox]::Show(('以下高风险项将被清理（可能影响个人数据）：' + $names + "`r`n`r`n确认继续？"), '高风险确认', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
      if ($r -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    $script:BtnClean.IsEnabled = $false
    $script:BtnCancelClean.IsEnabled = $true
    $script:CleanBar.Value = 0
    $script:CleanStatus.Text = '清理中...'
    $modeText = if ($mode -eq 'Permanent') { '永久删除' } else { '回收站' }
    Log-Line ('开始清理: ' + $checked.Count + ' 项, 模式=' + $modeText)
    $script:CleanWorker.RunWorkerAsync(@{ Items = $checked; Mode = $mode })
  })
  $script:BtnCancelClean.Add_Click({ if ($script:CleanWorker) { $script:CleanWorker.CancelAsync() } })

  # 恢复删除模式（RestoringMode 抑制启动时的永久删除弹窗）
  Load-Settings
  if ($script:Settings.DeleteMode -eq 'Permanent') {
    $script:RestoringMode = $true
    try { $script:RbPermanent.IsChecked = $true } finally { $script:RestoringMode = $false }
  }

  # 就绪后自动扫描：ContentRendered 时 dispatcher 已泵消息，worker 回调可封送到 UI 线程
  $win.Add_ContentRendered({
    Refresh-DiskInfo
    Log-Line '工具已就绪。勾选要清理的项目后点击「开始清理」；删除默认进回收站可恢复。'
    Start-Scan
  })

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
