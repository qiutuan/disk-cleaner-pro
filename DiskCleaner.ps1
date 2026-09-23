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

#region 扫描引擎（高性能目录大小 + size-cache）
$script:SizeCache = @{}   # id -> bytes

function Measure-DirBytes {
  param([string]$Root)
  $total = 0L
  if (-not (Test-Path -LiteralPath $Root)) { return 0L }
  try {
    foreach ($f in [IO.Directory]::EnumerateFiles($Root)) {
      try { $total += ([IO.FileInfo]::new($f)).Length } catch { }
    }
    foreach ($d in [IO.Directory]::EnumerateDirectories($Root)) {
      try {
        $di = Get-Item -LiteralPath $d -Force
        if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }  # 跳过 Junction 防死循环
        $total += Measure-DirBytes $d
      } catch { }
    }
  } catch [System.UnauthorizedAccessException] { }
  catch { }
  return $total
}

function Save-SizeCache {
  try {
    $obj = [ordered]@{}
    foreach ($k in $script:SizeCache.Keys) { $obj[$k] = $script:SizeCache[$k] }
    $json = $obj | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $script:DataDir 'size-cache.json'), $json, [Text.UTF8Encoding]::new($false))
  } catch { }
}

function Load-SizeCache {
  $script:SizeCache = @{}
  try {
    $p = Join-Path $script:DataDir 'size-cache.json'
    if (Test-Path $p) {
      $o = Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json
      foreach ($prop in $o.PSObject.Properties) { $script:SizeCache[$prop.Name] = [long]$prop.Value }
    }
  } catch { }
}

function Get-ItemSize {
  param($Item, [switch]$Force)
  if ($Item.method -eq 'exec') { return 0L }
  if (-not $Force -and $script:SizeCache.ContainsKey($Item.id)) { return $script:SizeCache[$Item.id] }
  $total = 0L
  foreach ($raw in $Item.paths) {
    foreach ($p in (Get-ExpandedPaths $raw)) {
      if (-not (Test-Path -LiteralPath $p)) { continue }
      try {
        if ($Item.method -eq 'delete-file') {
          if (Test-Path -LiteralPath $p -PathType Leaf) { $total += ([IO.FileInfo]::new($p)).Length }
        } else {
          $item = Get-Item -LiteralPath $p -Force
          if ($item -and ($item.Attributes -band [IO.FileAttributes]::Directory)) { $total += Measure-DirBytes $p }
        }
      } catch { }
    }
  }
  $script:SizeCache[$Item.id] = $total
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

function New-PlaceholderPage {
  # 附加功能 Tab 占位页（提交6 填充）
  param([string]$Text, [string]$Msg)
  $p = New-Object System.Windows.Forms.TabPage
  $p.Text = $Text
  $p.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Bg)
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $Msg
  $l.Font = New-Object System.Drawing.Font('Microsoft YaHei', 12)
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
      $di = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
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

  $top = New-Object System.Windows.Forms.Panel
  $top.Dock = 'Top'; $top.Height = 44; $top.BackColor = [System.Drawing.Color]::White

  $lblDrv = New-Object System.Windows.Forms.Label
  $lblDrv.Text = '磁盘:'; $lblDrv.Location = New-Object System.Drawing.Point(12, 13); $lblDrv.AutoSize = $true
  $top.Controls.Add($lblDrv)
  $cmbDrive = New-Object System.Windows.Forms.ComboBox
  $cmbDrive.Location = New-Object System.Drawing.Point(52, 10); $cmbDrive.Width = 66
  foreach ($d in (Get-FixedDrives)) { $null = $cmbDrive.Items.Add($d) }
  if ($cmbDrive.Items.Count -gt 0) { $cmbDrive.SelectedIndex = 0 }
  $top.Controls.Add($cmbDrive)

  $lblTh = New-Object System.Windows.Forms.Label
  $lblTh.Text = '最小大小:'; $lblTh.Location = New-Object System.Drawing.Point(130, 13); $lblTh.AutoSize = $true
  $top.Controls.Add($lblTh)
  $cmbTh = New-Object System.Windows.Forms.ComboBox
  $cmbTh.Location = New-Object System.Drawing.Point(196, 10); $cmbTh.Width = 90
  $null = $cmbTh.Items.Add('100 MB'); $null = $cmbTh.Items.Add('300 MB'); $null = $cmbTh.Items.Add('500 MB'); $null = $cmbTh.Items.Add('1 GB')
  $cmbTh.SelectedIndex = 0
  $top.Controls.Add($cmbTh)

  $btnScanL = New-Object System.Windows.Forms.Button
  $btnScanL.Text = '开始扫描'
  $btnScanL.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $btnScanL.ForeColor = [System.Drawing.Color]::White; $btnScanL.FlatStyle = 'Flat'
  $btnScanL.Location = New-Object System.Drawing.Point(300, 8); $btnScanL.Size = New-Object System.Drawing.Size(90, 28)
  $top.Controls.Add($btnScanL)
  $btnStopL = New-Object System.Windows.Forms.Button
  $btnStopL.Text = '停止'
  $btnStopL.Location = New-Object System.Drawing.Point(396, 8); $btnStopL.Size = New-Object System.Drawing.Size(60, 28); $btnStopL.Enabled = $false
  $top.Controls.Add($btnStopL)
  $progL = New-Object System.Windows.Forms.ProgressBar
  $progL.Location = New-Object System.Drawing.Point(466, 13); $progL.Size = New-Object System.Drawing.Size(220, 16)
  $top.Controls.Add($progL)
  $lblL = New-Object System.Windows.Forms.Label
  $lblL.Text = '就绪'; $lblL.Location = New-Object System.Drawing.Point(694, 14); $lblL.AutoSize = $true
  $top.Controls.Add($lblL)

  $lvLarge = New-Object System.Windows.Forms.ListView
  $lvLarge.Dock = 'Fill'
  $lvLarge.View = 'Details'; $lvLarge.FullRowSelect = $true; $lvLarge.GridLines = $true; $lvLarge.HideSelection = $false
  $lvLarge.UseCompatibleStateImageBehavior = $false
  $null = $lvLarge.Columns.Add('名称', 220)
  $null = $lvLarge.Columns.Add('大小', 90)
  $null = $lvLarge.Columns.Add('修改时间', 130)
  $null = $lvLarge.Columns.Add('路径', 560)

  $foot = New-Object System.Windows.Forms.Panel
  $foot.Dock = 'Bottom'; $foot.Height = 48; $foot.BackColor = [System.Drawing.Color]::White
  $lblLTotal = New-Object System.Windows.Forms.Label
  $lblLTotal.Text = '共 0 个文件'
  $lblLTotal.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)
  $lblLTotal.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $lblLTotal.Location = New-Object System.Drawing.Point(12, 14); $lblLTotal.AutoSize = $true
  $foot.Controls.Add($lblLTotal)
  $btnDelL = New-Object System.Windows.Forms.Button
  $btnDelL.Text = '删除选中(回收站)'
  $btnDelL.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Red)
  $btnDelL.ForeColor = [System.Drawing.Color]::White; $btnDelL.FlatStyle = 'Flat'
  $btnDelL.Location = New-Object System.Drawing.Point(900, 9); $btnDelL.Size = New-Object System.Drawing.Size(140, 30)
  $foot.Controls.Add($btnDelL)

  $p.Controls.Add($foot)
  $p.Controls.Add($top)
  $p.Controls.Add($lvLarge)

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $miOpen = New-Object System.Windows.Forms.ToolStripMenuItem('打开所在文件夹')
  $miCopy = New-Object System.Windows.Forms.ToolStripMenuItem('复制路径')
  $miDelL = New-Object System.Windows.Forms.ToolStripMenuItem('删除到回收站')
  $null = $menu.Items.Add($miOpen); $null = $menu.Items.Add($miCopy); $null = $menu.Items.Add($miDelL)
  $lvLarge.ContextMenuStrip = $menu

  $lfWorker = New-Object System.ComponentModel.BackgroundWorker
  $lfWorker.WorkerSupportsCancellation = $true
  $lfWorker.add_DoWork({
    param($s, $e)
    $a = $e.Argument
    $list = Get-LargeFiles -Root $a.Root -Threshold $a.Threshold -W $s
    if ($s.CancellationPending) { $e.Cancel = $true; return }
    $e.Result = $list
  })
  $lfWorker.add_ProgressChanged({
    param($s, $e)
    $lblL.Text = [string]$e.UserState
  })
  $lfWorker.add_RunWorkerCompleted({
    param($s, $e)
    $btnScanL.Enabled = $true; $btnStopL.Enabled = $false
    $progL.Style = 'Continuous'; $progL.Value = 0
    if ($e.Cancelled) { $lblL.Text = '已取消'; return }
    $rows = @($e.Result)
    $lvLarge.BeginUpdate(); $lvLarge.Items.Clear()
    $totalBytes = 0L
    foreach ($r in $rows) {
      $totalBytes += [long]$r.Size
      $li = [System.Windows.Forms.ListViewItem]::new([string[]]@($r.Name, (Format-Bytes $r.Size), $r.Modified.ToString('yyyy-MM-dd HH:mm'), $r.Path))
      $li.Tag = $r
      $null = $lvLarge.Items.Add($li)
    }
    $lvLarge.EndUpdate()
    $lblLTotal.Text = ('共 {0} 个文件 / {1}' -f $rows.Count, (Format-Bytes $totalBytes))
    $lblL.Text = '完成'
    Log-Line ('大文件扫描完成: {0} 个' -f $rows.Count)
  })

  $btnScanL.add_Click({
    $drive = [string]$cmbDrive.SelectedItem
    if (-not $drive) {
      try { [System.Windows.Forms.MessageBox]::Show('请先选择磁盘。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $mb = switch ([string]$cmbTh.SelectedItem) { '300 MB' { 300 } '500 MB' { 500 } '1 GB' { 1024 } default { 100 } }
    $btnScanL.Enabled = $false; $btnStopL.Enabled = $true
    $progL.Style = 'Marquee'; $progL.MarqueeAnimationSpeed = 30
    $lblL.Text = '扫描中...'
    $lvLarge.Items.Clear(); $lblLTotal.Text = '共 0 个文件'
    Log-Line ('大文件扫描开始: {0} >= {1}' -f $drive, $cmbTh.SelectedItem)
    $lfWorker.RunWorkerAsync(@{ Root = ($drive + '\'); Threshold = ([long]$mb * 1024 * 1024) })
  })
  $btnStopL.add_Click({ $lfWorker.CancelAsync() })
  $miOpen.add_Click({
    if ($lvLarge.SelectedItems.Count -gt 0) { Open-InExplorer -Path $lvLarge.SelectedItems[0].Tag.Path -Select }
  })
  $miCopy.add_Click({
    if ($lvLarge.SelectedItems.Count -gt 0) { try { [System.Windows.Forms.Clipboard]::SetText([string]$lvLarge.SelectedItems[0].Tag.Path) } catch { } }
  })
  $btnDelL.add_Click({
    $sel = @($lvLarge.SelectedItems | ForEach-Object { $_.Tag })
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
    foreach ($li in @($lvLarge.SelectedItems)) { $lvLarge.Items.Remove($li) }
    $totalBytes = 0L
    foreach ($li2 in $lvLarge.Items) { if ($li2.Tag) { $totalBytes += [long]$li2.Tag.Size } }
    $lblLTotal.Text = ('共 {0} 个文件 / {1}' -f $lvLarge.Items.Count, (Format-Bytes $totalBytes))
    try {
      [System.Windows.Forms.MessageBox]::Show(('已删除 {0} 个大文件，释放 {1}；被占用/受保护的文件自动跳过。' -f $ok, (Format-Bytes $rel)), '完成', 'OK', 'Information')
    } catch { }
  })
  $miDelL.add_Click({ $btnDelL.PerformClick() })

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

  $btnSoftRefresh = New-Object System.Windows.Forms.Button
  $btnSoftRefresh.Text = '刷新列表'
  $btnSoftRefresh.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $btnSoftRefresh.ForeColor = [System.Drawing.Color]::White; $btnSoftRefresh.FlatStyle = 'Flat'
  $btnSoftRefresh.Location = New-Object System.Drawing.Point(12, 8); $btnSoftRefresh.Size = New-Object System.Drawing.Size(90, 28)
  $top.Controls.Add($btnSoftRefresh)
  $btnSoftReal = New-Object System.Windows.Forms.Button
  $btnSoftReal.Text = '计算实际占用'
  $btnSoftReal.Location = New-Object System.Drawing.Point(108, 8); $btnSoftReal.Size = New-Object System.Drawing.Size(120, 28)
  $top.Controls.Add($btnSoftReal)
  $lblSoft = New-Object System.Windows.Forms.Label
  $lblSoft.Text = '信息展示为主，不提供卸载。'
  $lblSoft.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Disabled)
  $lblSoft.Location = New-Object System.Drawing.Point(240, 14); $lblSoft.AutoSize = $true
  $top.Controls.Add($lblSoft)

  $lvSoft = New-Object System.Windows.Forms.ListView
  $lvSoft.Dock = 'Fill'
  $lvSoft.View = 'Details'; $lvSoft.FullRowSelect = $true; $lvSoft.GridLines = $true; $lvSoft.HideSelection = $false
  $lvSoft.UseCompatibleStateImageBehavior = $false
  $null = $lvSoft.Columns.Add('名称', 200)
  $null = $lvSoft.Columns.Add('发布者', 150)
  $null = $lvSoft.Columns.Add('版本', 110)
  $null = $lvSoft.Columns.Add('安装位置', 320)
  $null = $lvSoft.Columns.Add('注册大小', 80)
  $null = $lvSoft.Columns.Add('实际占用', 90)

  $menuS = New-Object System.Windows.Forms.ContextMenuStrip
  $miSoftOpen = New-Object System.Windows.Forms.ToolStripMenuItem('打开安装目录')
  $miSoftCopy = New-Object System.Windows.Forms.ToolStripMenuItem('复制安装路径')
  $null = $menuS.Items.Add($miSoftOpen); $null = $menuS.Items.Add($miSoftCopy)
  $lvSoft.ContextMenuStrip = $menuS

  $p.Controls.Add($top)
  $p.Controls.Add($lvSoft)

  function Fill-SoftwareList {
    $lvSoft.BeginUpdate(); $lvSoft.Items.Clear()
    foreach ($s in (Get-InstalledSoftware)) {
      $realTxt = if ($s.RealBytes -gt 0) { Format-Bytes $s.RealBytes } else { '' }
      $regTxt = if ($s.RegKB -gt 0) { Format-Bytes ($s.RegKB * 1024) } else { '' }
      $li = [System.Windows.Forms.ListViewItem]::new([string[]]@($s.Name, $s.Publisher, $s.Version, $s.Location, $regTxt, $realTxt))
      $li.Tag = $s
      $null = $lvSoft.Items.Add($li)
    }
    $lvSoft.EndUpdate()
    $lblSoft.Text = ('共 {0} 个已安装软件' -f $lvSoft.Items.Count)
  }

  $softWorker = New-Object System.ComponentModel.BackgroundWorker
  $softWorker.add_DoWork({
    param($s, $e)
    $row = $e.Argument
    $bytes = 0L
    if ($row.Location -and (Test-Path -LiteralPath $row.Location)) {
      try { $bytes = Measure-DirBytes $row.Location } catch { $bytes = 0L }
    }
    $e.Result = @{ Row = $row; Bytes = $bytes }
  })
  $softWorker.add_RunWorkerCompleted({
    param($s, $e)
    $btnSoftReal.Enabled = $true
    $r = $e.Result
    $r.Row.RealBytes = $r.Bytes
    foreach ($li in $lvSoft.Items) {
      if ($li.Tag -eq $r.Row) {
        $li.SubItems[5].Text = if ($r.Bytes -gt 0) { Format-Bytes $r.Bytes } else { '（不可测/无位置）' }
        break
      }
    }
    Log-Line ('实际占用: {0} = {1}' -f $r.Row.Name, (Format-Bytes $r.Bytes))
  })

  $btnSoftRefresh.add_Click({ Fill-SoftwareList; Log-Line ('软件列表已刷新: {0} 项' -f $lvSoft.Items.Count) })
  $btnSoftReal.add_Click({
    if ($lvSoft.SelectedItems.Count -eq 0) {
      try { [System.Windows.Forms.MessageBox]::Show('请先选择要计算占用的一项软件。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $row = $lvSoft.SelectedItems[0].Tag
    if (-not $row.Location -or -not (Test-Path -LiteralPath $row.Location)) {
      try { [System.Windows.Forms.MessageBox]::Show('该项未记录安装位置，无法计算实际占用。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $btnSoftReal.Enabled = $false
    $softWorker.RunWorkerAsync($row)
  })
  $miSoftOpen.add_Click({
    if ($lvSoft.SelectedItems.Count -gt 0 -and $lvSoft.SelectedItems[0].Tag.Location) {
      Open-InExplorer -Path $lvSoft.SelectedItems[0].Tag.Location
    }
  })
  $miSoftCopy.add_Click({
    if ($lvSoft.SelectedItems.Count -gt 0) { try { [System.Windows.Forms.Clipboard]::SetText([string]$lvSoft.SelectedItems[0].Tag.Location) } catch { } }
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
      $di = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
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
  # 仅保留"同大小出现>=2"的候选
  $candidates = New-Object System.Collections.Generic.List[string]
  foreach ($k in @($bySize.Keys)) { if ($bySize[$k].Count -ge 2) { $candidates.AddRange($bySize[$k]) } }
  $bySize = $null
  # 哈希
  $hashMap = @{}
  $i = 0
  foreach ($f in $candidates) {
    if ($W -and $W.CancellationPending) { return $null }
    $h = Get-FileHashSha256 $f
    if ($h) { $hashMap[$f] = $h }
    $i++
    if (($i % 50) -eq 0 -and $W -and $candidates.Count -gt 0) {
      $W.ReportProgress([int](100.0 * $i / $candidates.Count), ("哈希 {0}/{1}" -f $i, $candidates.Count))
    }
  }
  $byHash = @{}
  foreach ($f in $hashMap.Keys) {
    $h = $hashMap[$f]
    if (-not $byHash.ContainsKey($h)) { $byHash[$h] = New-Object System.Collections.Generic.List[string] }
    $byHash[$h].Add($f)
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

  $top = New-Object System.Windows.Forms.Panel
  $top.Dock = 'Top'; $top.Height = 44; $top.BackColor = [System.Drawing.Color]::White

  $lblDupDir = New-Object System.Windows.Forms.Label
  $lblDupDir.Text = '目录:'; $lblDupDir.Location = New-Object System.Drawing.Point(12, 14); $lblDupDir.AutoSize = $true
  $top.Controls.Add($lblDupDir)
  $txtDupDir = New-Object System.Windows.Forms.TextBox
  $txtDupDir.Text = $env:USERPROFILE
  $txtDupDir.Location = New-Object System.Drawing.Point(50, 11); $txtDupDir.Width = 330
  $top.Controls.Add($txtDupDir)
  $btnDupBrowse = New-Object System.Windows.Forms.Button
  $btnDupBrowse.Text = '浏览'
  $btnDupBrowse.Location = New-Object System.Drawing.Point(386, 9); $btnDupBrowse.Size = New-Object System.Drawing.Size(60, 26)
  $top.Controls.Add($btnDupBrowse)
  $btnDupScan = New-Object System.Windows.Forms.Button
  $btnDupScan.Text = '开始检测'
  $btnDupScan.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $btnDupScan.ForeColor = [System.Drawing.Color]::White; $btnDupScan.FlatStyle = 'Flat'
  $btnDupScan.Location = New-Object System.Drawing.Point(452, 8); $btnDupScan.Size = New-Object System.Drawing.Size(90, 28)
  $top.Controls.Add($btnDupScan)
  $btnDupStop = New-Object System.Windows.Forms.Button
  $btnDupStop.Text = '停止'
  $btnDupStop.Location = New-Object System.Drawing.Point(548, 8); $btnDupStop.Size = New-Object System.Drawing.Size(60, 28); $btnDupStop.Enabled = $false
  $top.Controls.Add($btnDupStop)
  $progD = New-Object System.Windows.Forms.ProgressBar
  $progD.Location = New-Object System.Drawing.Point(618, 13); $progD.Size = New-Object System.Drawing.Size(200, 16)
  $top.Controls.Add($progD)
  $lblD = New-Object System.Windows.Forms.Label
  $lblD.Text = '就绪'; $lblD.Location = New-Object System.Drawing.Point(826, 14); $lblD.AutoSize = $true
  $top.Controls.Add($lblD)

  $lvDup = New-Object System.Windows.Forms.ListView
  $lvDup.Dock = 'Fill'
  $lvDup.View = 'Details'; $lvDup.FullRowSelect = $true; $lvDup.GridLines = $true; $lvDup.HideSelection = $false
  $lvDup.CheckBoxes = $true
  $lvDup.UseCompatibleStateImageBehavior = $false
  $null = $lvDup.Columns.Add('组', 50)
  $null = $lvDup.Columns.Add('大小', 90)
  $null = $lvDup.Columns.Add('状态', 70)
  $null = $lvDup.Columns.Add('路径', 660)

  $foot = New-Object System.Windows.Forms.Panel
  $foot.Dock = 'Bottom'; $foot.Height = 48; $foot.BackColor = [System.Drawing.Color]::White
  $lblDupInfo = New-Object System.Windows.Forms.Label
  $lblDupInfo.Text = '默认每组保留 1 个副本，其余已勾选待删除。'
  $lblDupInfo.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $lblDupInfo.Location = New-Object System.Drawing.Point(12, 15); $lblDupInfo.AutoSize = $true
  $foot.Controls.Add($lblDupInfo)
  $btnDupDel = New-Object System.Windows.Forms.Button
  $btnDupDel.Text = '删除勾选(回收站)'
  $btnDupDel.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Red)
  $btnDupDel.ForeColor = [System.Drawing.Color]::White; $btnDupDel.FlatStyle = 'Flat'
  $btnDupDel.Location = New-Object System.Drawing.Point(900, 9); $btnDupDel.Size = New-Object System.Drawing.Size(140, 30)
  $foot.Controls.Add($btnDupDel)

  $p.Controls.Add($foot)
  $p.Controls.Add($top)
  $p.Controls.Add($lvDup)

  $dupWorker = New-Object System.ComponentModel.BackgroundWorker
  $dupWorker.WorkerSupportsCancellation = $true
  $dupWorker.add_DoWork({
    param($s, $e)
    $groups = Get-DupeGroups -Root ([string]$e.Argument) -W $s
    if ($s.CancellationPending) { $e.Cancel = $true; return }
    $e.Result = $groups
  })
  $dupWorker.add_ProgressChanged({
    param($s, $e)
    $progD.Value = [Math]::Min(100, $e.ProgressPercentage)
    $lblD.Text = [string]$e.UserState
  })
  $dupWorker.add_RunWorkerCompleted({
    param($s, $e)
    $btnDupScan.Enabled = $true; $btnDupStop.Enabled = $false
    $progD.Style = 'Continuous'; $progD.Value = 0
    if ($e.Cancelled) { $lblD.Text = '已取消'; return }
    $rows = @($e.Result)
    $lvDup.BeginUpdate(); $lvDup.Items.Clear()
    foreach ($r in $rows) {
      $keepTxt = if ($r.Keep) { '保留' } else { '待删' }
      $li = [System.Windows.Forms.ListViewItem]::new([string[]]@([string]$r.Group, (Format-Bytes $r.Size), $keepTxt, $r.Path))
      $li.Tag = $r
      $li.Checked = -not $r.Keep
      $li.ForeColor = if ($r.Keep) { [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Green) } else { [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text) }
      $null = $lvDup.Items.Add($li)
    }
    $lvDup.EndUpdate()
    $grp = @($rows | ForEach-Object { $_.Group } | Sort-Object -Unique).Count
    $lblDupInfo.Text = ('发现 {0} 组重复文件，共 {1} 个副本（每组保留 1 个）' -f $grp, $rows.Count)
    $lblD.Text = '完成'
    Log-Line ('重复文件检测完成: {0} 组 / {1} 文件' -f $grp, $rows.Count)
  })

  $btnDupBrowse.add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = '选择要检测重复文件的目录'
    $d.SelectedPath = $txtDupDir.Text
    if ($d.ShowDialog() -eq 'OK') { $txtDupDir.Text = $d.SelectedPath }
  })
  $btnDupScan.add_Click({
    $root = $txtDupDir.Text.Trim()
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
      try { [System.Windows.Forms.MessageBox]::Show('请输入存在的目录。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $btnDupScan.Enabled = $false; $btnDupStop.Enabled = $true
    $progD.Style = 'Marquee'; $progD.MarqueeAnimationSpeed = 30
    $lblD.Text = '检测中...'
    $lvDup.Items.Clear()
    Log-Line ('重复文件检测开始: ' + $root)
    $dupWorker.RunWorkerAsync($root)
  })
  $btnDupStop.add_Click({ $dupWorker.CancelAsync() })
  $btnDupDel.add_Click({
    $sel = @($lvDup.CheckedItems | ForEach-Object { $_.Tag })
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
    foreach ($li in @($lvDup.CheckedItems)) { $lvDup.Items.Remove($li) }
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

  $banner = New-Object System.Windows.Forms.Panel
  $banner.Dock = 'Top'; $banner.Height = 40; $banner.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Yellow)
  $lblRPStatus = New-Object System.Windows.Forms.Label
  $lblRPStatus.Text = '检测中...'
  $lblRPStatus.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)
  $lblRPStatus.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $lblRPStatus.Location = New-Object System.Drawing.Point(12, 10); $lblRPStatus.AutoSize = $true
  $banner.Controls.Add($lblRPStatus)

  $top = New-Object System.Windows.Forms.Panel
  $top.Dock = 'Top'; $top.Height = 44; $top.BackColor = [System.Drawing.Color]::White
  $btnRPRefresh = New-Object System.Windows.Forms.Button
  $btnRPRefresh.Text = '刷新'
  $btnRPRefresh.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $btnRPRefresh.ForeColor = [System.Drawing.Color]::White; $btnRPRefresh.FlatStyle = 'Flat'
  $btnRPRefresh.Location = New-Object System.Drawing.Point(12, 8); $btnRPRefresh.Size = New-Object System.Drawing.Size(70, 28)
  $top.Controls.Add($btnRPRefresh)
  $btnRPDelete = New-Object System.Windows.Forms.Button
  $btnRPDelete.Text = '删除旧还原点(保留最近3个)'
  $btnRPDelete.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Red)
  $btnRPDelete.ForeColor = [System.Drawing.Color]::White; $btnRPDelete.FlatStyle = 'Flat'
  $btnRPDelete.Location = New-Object System.Drawing.Point(88, 8); $btnRPDelete.Size = New-Object System.Drawing.Size(190, 28)
  $top.Controls.Add($btnRPDelete)

  $lvRP = New-Object System.Windows.Forms.ListView
  $lvRP.Dock = 'Fill'
  $lvRP.View = 'Details'; $lvRP.FullRowSelect = $true; $lvRP.GridLines = $true; $lvRP.HideSelection = $false
  $lvRP.UseCompatibleStateImageBehavior = $false
  $null = $lvRP.Columns.Add('序号', 70)
  $null = $lvRP.Columns.Add('创建时间', 150)
  $null = $lvRP.Columns.Add('描述', 400)

  $p.Controls.Add($top)
  $p.Controls.Add($banner)
  $p.Controls.Add($lvRP)

  function Fill-RestoreList {
    $lvRP.BeginUpdate(); $lvRP.Items.Clear()
    $pts = Get-RestorePoints
    if ($pts.Count -eq 0) {
      $lblRPStatus.Text = '系统还原不可用或无还原点（本机服务未启用）'
      $banner.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Yellow)
      $btnRPDelete.Enabled = $false
    } else {
      foreach ($rp in ($pts | Sort-Object CreationTime -Descending)) {
        $li = [System.Windows.Forms.ListViewItem]::new([string[]]@([string]$rp.SequenceNumber, $rp.CreationTime.ToString('yyyy-MM-dd HH:mm'), [string]$rp.Description))
        $li.Tag = $rp
        $null = $lvRP.Items.Add($li)
      }
      $lblRPStatus.Text = ('系统还原可用：共 {0} 个还原点' -f $pts.Count)
      $banner.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Green)
      $btnRPDelete.Enabled = $pts.Count -gt 3
    }
    $lvRP.EndUpdate()
  }

  $btnRPRefresh.add_Click({ Fill-RestoreList })
  $btnRPDelete.add_Click({
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

  $btnStRefresh = New-Object System.Windows.Forms.Button
  $btnStRefresh.Text = '刷新'
  $btnStRefresh.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $btnStRefresh.ForeColor = [System.Drawing.Color]::White; $btnStRefresh.FlatStyle = 'Flat'
  $btnStRefresh.Location = New-Object System.Drawing.Point(12, 8); $btnStRefresh.Size = New-Object System.Drawing.Size(70, 28)
  $top.Controls.Add($btnStRefresh)
  $btnStOpen = New-Object System.Windows.Forms.Button
  $btnStOpen.Text = '打开启动文件夹'
  $btnStOpen.Location = New-Object System.Drawing.Point(88, 8); $btnStOpen.Size = New-Object System.Drawing.Size(120, 28)
  $top.Controls.Add($btnStOpen)
  $btnStBackup = New-Object System.Windows.Forms.Button
  $btnStBackup.Text = '备份注册表项(.reg)'
  $btnStBackup.Location = New-Object System.Drawing.Point(214, 8); $btnStBackup.Size = New-Object System.Drawing.Size(140, 28)
  $top.Controls.Add($btnStBackup)
  $lblSt = New-Object System.Windows.Forms.Label
  $lblSt.Text = '信息展示为主；修改请用系统"任务管理器>启动"或 msconfig。'
  $lblSt.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Disabled)
  $lblSt.Location = New-Object System.Drawing.Point(364, 14); $lblSt.AutoSize = $true
  $top.Controls.Add($lblSt)

  $lvStart = New-Object System.Windows.Forms.ListView
  $lvStart.Dock = 'Fill'
  $lvStart.View = 'Details'; $lvStart.FullRowSelect = $true; $lvStart.GridLines = $true; $lvStart.HideSelection = $false
  $lvStart.UseCompatibleStateImageBehavior = $false
  $null = $lvStart.Columns.Add('来源', 130)
  $null = $lvStart.Columns.Add('名称', 200)
  $null = $lvStart.Columns.Add('状态', 60)
  $null = $lvStart.Columns.Add('命令', 560)

  $menuSt = New-Object System.Windows.Forms.ContextMenuStrip
  $miStCopy = New-Object System.Windows.Forms.ToolStripMenuItem('复制命令')
  $null = $menuSt.Items.Add($miStCopy)
  $lvStart.ContextMenuStrip = $menuSt

  $p.Controls.Add($top)
  $p.Controls.Add($lvStart)

  function Fill-StartupList {
    $lvStart.BeginUpdate(); $lvStart.Items.Clear()
    foreach ($s in (Get-StartupItems)) {
      $li = [System.Windows.Forms.ListViewItem]::new([string[]]@($s.Source, $s.Name, $s.Status, $s.Command))
      $li.Tag = $s
      $null = $lvStart.Items.Add($li)
    }
    $lvStart.EndUpdate()
    $lblSt.Text = ('共 {0} 个启动项' -f $lvStart.Items.Count)
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
    if ($lvStart.SelectedItems.Count -gt 0) { try { [System.Windows.Forms.Clipboard]::SetText([string]$lvStart.SelectedItems[0].Tag.Command) } catch { } }
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
  $f.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9)
  $f.Icon = $null   # 纯代码绘制，无图片资源

  # ============ 顶部横幅 ============
  $banner = New-Object System.Windows.Forms.Panel
  $banner.Dock = 'Top'
  $banner.Height = 100
  $banner.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Banner)

  $title = New-Object System.Windows.Forms.Label
  $title.Text = 'DiskCleanerPro  C 盘智能清理工具'
  $title.Font = New-Object System.Drawing.Font('Microsoft YaHei', 20, [System.Drawing.FontStyle]::Bold)
  $title.ForeColor = [System.Drawing.Color]::White
  $title.Location = New-Object System.Drawing.Point(20, 10)
  $title.AutoSize = $true
  $banner.Controls.Add($title)

  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $adminBadge = New-Object System.Windows.Forms.Label
  $adminBadge.Text = if ($isAdmin) { '管理员模式: 已启用' } else { '普通模式（建议以管理员运行）' }
  $adminBadge.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9, [System.Drawing.FontStyle]::Bold)
  $adminBadge.ForeColor = [System.Drawing.Color]::White
  $adminBadge.Location = New-Object System.Drawing.Point(20, 54)
  $adminBadge.AutoSize = $true
  $banner.Controls.Add($adminBadge)

  $diskInfo = New-Object System.Windows.Forms.Label
  $diskInfo.Text = '磁盘信息加载中...'
  $diskInfo.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9)
  $diskInfo.ForeColor = [System.Drawing.Color]::White
  $diskInfo.Location = New-Object System.Drawing.Point(400, 12)
  $diskInfo.AutoSize = $true
  $banner.Controls.Add($diskInfo)

  $diskBar = New-Object System.Windows.Forms.ProgressBar
  $diskBar.Location = New-Object System.Drawing.Point(400, 44)
  $diskBar.Size = New-Object System.Drawing.Size(320, 18)
  $diskBar.Style = 'Continuous'
  $banner.Controls.Add($diskBar)

  $btnScan = New-Object System.Windows.Forms.Button
  $btnScan.Text = '立即重新扫描'
  $btnScan.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Secondary)
  $btnScan.ForeColor = [System.Drawing.Color]::White
  $btnScan.FlatStyle = 'Flat'
  $btnScan.Location = New-Object System.Drawing.Point(760, 12)
  $btnScan.Size = New-Object System.Drawing.Size(110, 30)
  $banner.Controls.Add($btnScan)

  $btnClearCache = New-Object System.Windows.Forms.Button
  $btnClearCache.Text = '清空扫描缓存'
  $btnClearCache.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Secondary)
  $btnClearCache.ForeColor = [System.Drawing.Color]::White
  $btnClearCache.FlatStyle = 'Flat'
  $btnClearCache.Location = New-Object System.Drawing.Point(878, 12)
  $btnClearCache.Size = New-Object System.Drawing.Size(110, 30)
  $banner.Controls.Add($btnClearCache)

  $btnCancelScan = New-Object System.Windows.Forms.Button
  $btnCancelScan.Text = '取消扫描'
  $btnCancelScan.BackColor = [System.Drawing.Color]::Gray
  $btnCancelScan.ForeColor = [System.Drawing.Color]::White
  $btnCancelScan.FlatStyle = 'Flat'
  $btnCancelScan.Location = New-Object System.Drawing.Point(996, 12)
  $btnCancelScan.Size = New-Object System.Drawing.Size(90, 30)
  $btnCancelScan.Enabled = $false
  $banner.Controls.Add($btnCancelScan)

  # ============ 底部日志 ============
  $logBox = New-Object System.Windows.Forms.RichTextBox
  $logBox.Dock = 'Bottom'
  $logBox.Height = 150
  $logBox.ReadOnly = $true
  $logBox.BackColor = [System.Drawing.Color]::White
  $logBox.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
  $logBox.BorderStyle = 'FixedSingle'

  function Log-Line {
    param([string]$Msg)
    try {
      $logBox.AppendText((Get-Date -Format 'HH:mm:ss') + '  ' + $Msg + "`r`n")
      $logBox.SelectionStart = $logBox.TextLength
      $logBox.ScrollToCaret()
    } catch { }
    Write-CleanLog $Msg
  }

  # ============ 主 TabControl ============
  $tabs = New-Object System.Windows.Forms.TabControl
  $tabs.Dock = 'Fill'

  # ===== Tab1 缓存清理 =====
  $tabClean = New-Object System.Windows.Forms.TabPage
  $tabClean.Text = '缓存清理'
  $tabClean.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Bg)

  # 底部操作条（先加入 Dock，占位）
  $actionBar = New-Object System.Windows.Forms.Panel
  $actionBar.Dock = 'Bottom'
  $actionBar.Height = 96
  $actionBar.BackColor = [System.Drawing.Color]::White

  $totalLabel = New-Object System.Windows.Forms.Label
  $totalLabel.Text = '合计可释放: 0 B'
  $totalLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 13, [System.Drawing.FontStyle]::Bold)
  $totalLabel.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $totalLabel.Location = New-Object System.Drawing.Point(14, 12)
  $totalLabel.AutoSize = $true
  $actionBar.Controls.Add($totalLabel)

  $btnAll = New-Object System.Windows.Forms.Button
  $btnAll.Text = '全选'
  $btnAll.Location = New-Object System.Drawing.Point(12, 52)
  $btnAll.Size = New-Object System.Drawing.Size(72, 30)
  $actionBar.Controls.Add($btnAll)

  $btnNone = New-Object System.Windows.Forms.Button
  $btnNone.Text = '全不选'
  $btnNone.Location = New-Object System.Drawing.Point(90, 52)
  $btnNone.Size = New-Object System.Drawing.Size(72, 30)
  $actionBar.Controls.Add($btnNone)

  $btnLow = New-Object System.Windows.Forms.Button
  $btnLow.Text = '仅低风险'
  $btnLow.Location = New-Object System.Drawing.Point(168, 52)
  $btnLow.Size = New-Object System.Drawing.Size(88, 30)
  $actionBar.Controls.Add($btnLow)

  $btnSafe = New-Object System.Windows.Forms.Button
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
  $rbRecycle.Location = New-Object System.Drawing.Point(410, 14)
  $rbRecycle.AutoSize = $true
  $actionBar.Controls.Add($rbRecycle)

  $rbPermanent = New-Object System.Windows.Forms.RadioButton
  $rbPermanent.Text = '永久删除 (不可恢复)'
  $rbPermanent.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Red)
  $rbPermanent.Location = New-Object System.Drawing.Point(410, 42)
  $rbPermanent.AutoSize = $true
  $actionBar.Controls.Add($rbPermanent)

  $btnClean = New-Object System.Windows.Forms.Button
  $btnClean.Text = '开 始 清 理'
  $btnClean.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $btnClean.ForeColor = [System.Drawing.Color]::White
  $btnClean.Font = New-Object System.Drawing.Font('Microsoft YaHei', 12, [System.Drawing.FontStyle]::Bold)
  $btnClean.FlatStyle = 'Flat'
  $btnClean.Location = New-Object System.Drawing.Point(620, 16)
  $btnClean.Size = New-Object System.Drawing.Size(140, 56)
  $actionBar.Controls.Add($btnClean)

  $btnCancelClean = New-Object System.Windows.Forms.Button
  $btnCancelClean.Text = '取消'
  $btnCancelClean.Location = New-Object System.Drawing.Point(768, 16)
  $btnCancelClean.Size = New-Object System.Drawing.Size(70, 56)
  $btnCancelClean.Enabled = $false
  $actionBar.Controls.Add($btnCancelClean)

  $cleanBar = New-Object System.Windows.Forms.ProgressBar
  $cleanBar.Location = New-Object System.Drawing.Point(860, 22)
  $cleanBar.Size = New-Object System.Drawing.Size(300, 16)
  $actionBar.Controls.Add($cleanBar)

  $cleanStatus = New-Object System.Windows.Forms.Label
  $cleanStatus.Text = '就绪'
  $cleanStatus.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $cleanStatus.Location = New-Object System.Drawing.Point(860, 46)
  $cleanStatus.AutoSize = $true
  $actionBar.Controls.Add($cleanStatus)

  # 右侧详情面板
  $detailPanel = New-Object System.Windows.Forms.Panel
  $detailPanel.Dock = 'Right'
  $detailPanel.Width = 260
  $detailPanel.BackColor = [System.Drawing.Color]::White

  $detailTitle = New-Object System.Windows.Forms.Label
  $detailTitle.Text = '项目说明'
  $detailTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11, [System.Drawing.FontStyle]::Bold)
  $detailTitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Primary)
  $detailTitle.Location = New-Object System.Drawing.Point(12, 10)
  $detailTitle.AutoSize = $true
  $detailPanel.Controls.Add($detailTitle)

  $detailName = New-Object System.Windows.Forms.Label
  $detailName.Text = '（选择左侧清理项）'
  $detailName.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)
  $detailName.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $detailName.Location = New-Object System.Drawing.Point(12, 40)
  $detailName.MaximumSize = New-Object System.Drawing.Size(236, 0)
  $detailName.AutoSize = $true
  $detailPanel.Controls.Add($detailName)

  $detailRisk = New-Object System.Windows.Forms.Label
  $detailRisk.Text = ''
  $detailRisk.Font = New-Object System.Drawing.Font('Microsoft YaHei', 10, [System.Drawing.FontStyle]::Bold)
  $detailRisk.Location = New-Object System.Drawing.Point(12, 68)
  $detailRisk.AutoSize = $true
  $detailPanel.Controls.Add($detailRisk)

  $detailDesc = New-Object System.Windows.Forms.Label
  $detailDesc.Text = ''
  $detailDesc.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $detailDesc.Location = New-Object System.Drawing.Point(12, 96)
  $detailDesc.MaximumSize = New-Object System.Drawing.Size(236, 0)
  $detailDesc.AutoSize = $true
  $detailPanel.Controls.Add($detailDesc)

  $detailPath = New-Object System.Windows.Forms.Label
  $detailPath.Text = ''
  $detailPath.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Disabled)
  $detailPath.Font = New-Object System.Drawing.Font('Consolas', 8)
  $detailPath.Location = New-Object System.Drawing.Point(12, 190)
  $detailPath.MaximumSize = New-Object System.Drawing.Size(236, 0)
  $detailPath.AutoSize = $true
  $detailPanel.Controls.Add($detailPath)

  # 清理项列表（最后加入 Dock，占满剩余空间）
  $listView = New-Object System.Windows.Forms.ListView
  $listView.Dock = 'Fill'
  $listView.View = 'Details'
  $listView.CheckBoxes = $true
  $listView.FullRowSelect = $true
  $listView.GridLines = $true
  $listView.HideSelection = $false
  $listView.UseCompatibleStateImageBehavior = $false
  $null = $listView.Columns.Add('名称', 300)
  $null = $listView.Columns.Add('大小', 100)
  $null = $listView.Columns.Add('风险', 80)
  $null = $listView.Columns.Add('说明', 480)

  $tabClean.Controls.Add($actionBar)
  $tabClean.Controls.Add($detailPanel)
  $tabClean.Controls.Add($listView)
  $tabs.Controls.Add($tabClean)

  # ===== Tab2-6 附加功能页 =====
  $tabs.Controls.Add((New-LargeFilesPage))
  $tabs.Controls.Add((New-SoftwarePage))
  $tabs.Controls.Add((New-DupeFilesPage))
  $tabs.Controls.Add((New-RestorePage))
  $tabs.Controls.Add((New-StartupPage))

  $f.Controls.Add($banner)
  $f.Controls.Add($logBox)
  $f.Controls.Add($tabs)

  # ============ 逻辑函数 ============
  $suppressPrompt = $false

  function Refresh-DiskInfo {
    try {
      $d = Get-PSDrive -Name 'C'
      $used = [long]$d.Used; $free = [long]$d.Free; $total = $used + $free
      $pct = if ($total -gt 0) { [int](100 * $used / $total) } else { 0 }
      $diskInfo.Text = ('C盘: 已用 {0} / 可用 {1}   占用 {2}%' -f (Format-Bytes $used), (Format-Bytes $free), $pct)
      $diskBar.Maximum = 100
      $diskBar.Value = [Math]::Min(100, $pct)
    } catch { }
  }

  function Update-Total {
    $total = 0L
    foreach ($li in $listView.Items) {
      if ($li.Checked -and $li.Tag) { $total += [long]$li.Tag.Size }
    }
    $totalLabel.Text = '合计可释放: ' + (Format-Bytes $total)
  }

  # ===== 扫描 worker =====
  $scanWorker = New-Object System.ComponentModel.BackgroundWorker
  $scanWorker.WorkerReportsProgress = $true
  $scanWorker.add_DoWork({
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
  })
  $scanWorker.add_ProgressChanged({
    param($s, $e)
    $diskBar.Value = [Math]::Min(100, $e.ProgressPercentage)
    $diskInfo.Text = ('扫描中... ' + [string]$e.UserState + '  (' + $e.ProgressPercentage + '%)')
  })
  $scanWorker.add_RunWorkerCompleted({
    param($s, $e)
    $btnScan.Enabled = $true
    $btnCancelScan.Enabled = $false
    if ($e.Cancelled) {
      Log-Line '扫描已取消'
      $diskInfo.Text = '扫描已取消'
      return
    }
    $listView.BeginUpdate()
    $listView.Items.Clear()
    $listView.Groups.Clear()
    $groups = @{}
    foreach ($row in $e.Result.Rows) {
      $it = $row.Item; $size = [long]$row.Size
      $li = [System.Windows.Forms.ListViewItem]::new([string[]]@($it.name, (Format-Bytes $size), (Get-RiskText $it.risk), $it.desc))
      $li.Tag = [pscustomobject]@{ Item = $it; Size = $size }
      $li.ForeColor = [System.Drawing.ColorTranslator]::FromHtml((Get-RiskColor $it.risk))
      $catKey = switch ($it.category) {
        'system'  { '系统' }
        'browser' { '浏览器' }
        'dev'     { '开发工具' }
        default   { '常用软件' }
      }
      if (-not $groups.ContainsKey($catKey)) {
        $g = New-Object System.Windows.Forms.ListViewGroup($catKey)
        $listView.Groups.Add($g)
        $groups[$catKey] = $g
      }
      $li.Group = $groups[$catKey]
      $li.Checked = [bool]$it.defaultChecked
      $null = $listView.Items.Add($li)
    }
    $listView.EndUpdate()
    Save-SizeCache
    Update-Total
    Refresh-DiskInfo
    Log-Line ('扫描完成: 共 ' + $listView.Items.Count + ' 项清理目标')
  })

  function Start-Scan {
    $btnScan.Enabled = $false
    $btnCancelScan.Enabled = $true
    $listView.Items.Clear()
    $listView.Groups.Clear()
    Update-Total
    Log-Line '开始扫描清理项大小（未缓存项首次较慢）...'
    $scanWorker.RunWorkerAsync()
  }

  # ===== 清理 worker =====
  $cleanWorker = New-Object System.ComponentModel.BackgroundWorker
  $cleanWorker.WorkerSupportsCancellation = $true
  $cleanWorker.add_DoWork({
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
  })
  $cleanWorker.add_ProgressChanged({
    param($s, $e)
    $cleanBar.Value = [Math]::Min(100, $e.ProgressPercentage)
    $cleanStatus.Text = '清理中... ' + [string]$e.UserState
    Log-Line ('清理: ' + [string]$e.UserState)
  })
  $cleanWorker.add_RunWorkerCompleted({
    param($s, $e)
    $cleanBar.Value = 0
    $btnClean.Enabled = $true
    $btnCancelClean.Enabled = $false
    if ($e.Cancelled) {
      $cleanStatus.Text = '已取消'
      Log-Line '清理已取消（已完成部分保留）'
    } else {
      $res = $e.Result
      $cleanStatus.Text = '清理完成'
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
  $listView.add_ItemCheck({
    param($s, $e)
    if ($suppressPrompt) { return }
    if ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked) {
      $li = $listView.Items[$e.Index]
      if ($li.Tag -and $li.Tag.Item.risk -eq 'red') {
        $r = [System.Windows.Forms.MessageBox]::Show(('「' + $li.Text + '」风险较高，可能涉及个人数据。确定勾选清理吗？'), '风险确认', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.NewValue = [System.Windows.Forms.CheckState]::Unchecked }
      }
    }
  })
  $listView.add_ItemChecked({ param($s, $e) Update-Total })
  $listView.add_SelectedIndexChanged({
    if ($listView.SelectedItems.Count -gt 0) {
      $li = $listView.SelectedItems[0]
      if ($li.Tag) {
        $it = $li.Tag.Item
        $detailName.Text = $it.name
        $detailRisk.Text = '风险: ' + (Get-RiskText $it.risk)
        $detailRisk.ForeColor = [System.Drawing.ColorTranslator]::FromHtml((Get-RiskColor $it.risk))
        $detailDesc.Text = $it.desc
        $detailPath.Text = ($it.paths -join "`r`n")
      }
    }
  })

  $btnScan.add_Click({ Start-Scan })
  $btnClearCache.add_Click({
    $script:SizeCache = @{}
    $p = Join-Path $script:DataDir 'size-cache.json'
    if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    Log-Line '已清空扫描缓存，下次扫描全量实测'
    Start-Scan
  })
  $btnCancelScan.add_Click({ $scanWorker.CancelAsync() })

  $btnAll.add_Click({
    $suppressPrompt = $true
    try { foreach ($li in $listView.Items) { $li.Checked = $true } } finally { $suppressPrompt = $false }
  })
  $btnNone.add_Click({
    $suppressPrompt = $true
    try { foreach ($li in $listView.Items) { $li.Checked = $false } } finally { $suppressPrompt = $false }
  })
  $btnLow.add_Click({
    $suppressPrompt = $true
    try { foreach ($li in $listView.Items) { $li.Checked = ($li.Tag -and $li.Tag.Item.risk -eq 'green') } } finally { $suppressPrompt = $false }
  })
  $btnSafe.add_Click({
    # 一键清理安全项 = 绿 + 黄（排除红）
    $suppressPrompt = $true
    try { foreach ($li in $listView.Items) { $li.Checked = ($li.Tag -and $li.Tag.Item.risk -ne 'red') } } finally { $suppressPrompt = $false }
  })

  $rbPermanent.add_CheckedChanged({
    if ($rbPermanent.Checked) {
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

  $btnClean.add_Click({
    $checked = @($listView.Items | Where-Object { $_.Checked -and $_.Tag } | ForEach-Object { $_.Tag.Item })
    if ($checked.Count -eq 0) {
      try { [System.Windows.Forms.MessageBox]::Show('请先勾选要清理的项目。', '提示', 'OK', 'Information') } catch { }
      return
    }
    $mode = if ($rbPermanent.Checked) { 'Permanent' } else { 'Recycle' }
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
    $btnClean.Enabled = $false
    $btnCancelClean.Enabled = $true
    $cleanBar.Value = 0
    $cleanStatus.Text = '清理中...'
    $modeText = if ($mode -eq 'Permanent') { '永久删除' } else { '回收站' }
    Log-Line ('开始清理: ' + $checked.Count + ' 项, 模式=' + $modeText)
    $cleanWorker.RunWorkerAsync(@{ Items = $checked; Mode = $mode })
  })
  $btnCancelClean.add_Click({ $cleanWorker.CancelAsync() })

  # 恢复上次删除模式
  Load-Settings
  if ($script:Settings.DeleteMode -eq 'Permanent') { $rbPermanent.Checked = $true }

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
