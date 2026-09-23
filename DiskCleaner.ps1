# ============================================================
#  DiskCleanerPro - C 盘智能清理工具
#  PowerShell + WinForms（橙色主题，纯代码绘制，无图片资源）
#  启动：启动清理工具.bat（pwsh -STA 优先，PS5.1 兜底）
#  写入边界：所有运行时数据仅写入本目录 runtime\ 内
# ============================================================

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

#region 程序集加载（引擎与 UI 共用）
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic   # 回收站删除 API
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
  param([string]$Raw)
  $expanded = Expand-EnvPath $Raw
  if (-not $expanded) { return @() }
  if ($expanded -match '[\*\?]') {
    $parent = Split-Path $expanded -Parent
    $leaf   = Split-Path $expanded -Leaf
    if (-not (Test-Path -LiteralPath $parent)) { return @() }
    return @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like $leaf } | ForEach-Object { $_.FullName })
  }
  return @($expanded)
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
    if (-not (Test-Detect $it.detect)) { continue }   # 机器上不存在 → 隐藏
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

#region 主窗口（骨架：仅横幅 + 占位提示，后续填充各 Tab）
function New-MainWindow {
  $f = New-Object System.Windows.Forms.Form
  $f.Text = 'DiskCleanerPro - C 盘智能清理工具'
  $f.ClientSize = New-Object System.Drawing.Size(1180, 760)
  $f.MinimumSize = New-Object System.Drawing.Size(900, 600)
  $f.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Bg)
  $f.StartPosition = 'CenterScreen'

  # 顶部横幅
  $banner = New-Object System.Windows.Forms.Panel
  $banner.Dock = 'Top'
  $banner.Height = 96
  $banner.BackColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Banner)
  $title = New-Object System.Windows.Forms.Label
  $title.Text = 'DiskCleanerPro   C 盘智能清理工具'
  $title.Font = New-Object System.Drawing.Font('Microsoft YaHei', 20, [System.Drawing.FontStyle]::Bold)
  $title.ForeColor = [System.Drawing.Color]::White
  $title.Location = New-Object System.Drawing.Point(20, 12)
  $title.AutoSize = $true
  $banner.Controls.Add($title)
  $f.Controls.Add($banner)

  # 占位提示（骨架阶段）
  $hint = New-Object System.Windows.Forms.Label
  $hint.Text = '骨架已就绪：扫描引擎 / 清理项数据 / 完整界面将在后续提交中构建。'
  $hint.Font = New-Object System.Drawing.Font('Microsoft YaHei', 12)
  $hint.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($script:Theme.Text)
  $hint.AutoSize = $true
  $hint.Location = New-Object System.Drawing.Point(24, 130)
  $f.Controls.Add($hint)

  return $f
}
#endregion

#region 入口
$form = New-MainWindow
[System.Windows.Forms.Application]::Run($form)
#endregion
