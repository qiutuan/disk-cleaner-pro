# ============================================================
#  DiskCleanerPro - 引擎模块（Engine.psm1）
#  与 UI 解耦：主脚本 Import-Module 后调用 Initialize-Engine；
#  后台 worker runspace 也通过 Import-Module + Set-EngineSharedCache 复用同一套引擎。
#  写入边界：所有运行时数据仅写入 ToolRoot\runtime\ 内。
# ============================================================

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Continue'

#region 模块基础设置
$script:ToolRoot   = $PSScriptRoot
$script:DataDir    = Join-Path $script:ToolRoot 'runtime'
$script:LogDir     = Join-Path $script:DataDir 'logs'
$script:SizeCache  = @{}      # id -> @{ b=bytes; t=stamp }
$script:PathCache  = @{}      # id -> 展开后的路径数组（会话内缓存，避免重复 glob 展开）
$script:ConfigWarning = $null
#endregion

#region 程序集（兜底加载；类型按 AppDomain 全局可见，主会话已加载则此处跳过）
try { Add-Type -AssemblyName Microsoft.VisualBasic } catch { }   # 回收站删除 API
#endregion

#region 初始化
function Initialize-Engine {
  # 设置模块内部路径并加载磁盘缓存（worker runspace 仅 Import-Module，无需调用）
  Load-SizeCache
  return $script:ToolRoot
}

function Set-EngineSharedCache {
  # worker runspace 启动时绑定主会话共享 SizeCache（按引用共享，禁止重建对象）
  param([hashtable]$Cache)
  if ($Cache) { $script:SizeCache = $Cache }
}

function Get-EngineSharedCache {
  return $script:SizeCache
}

function Get-ConfigWarning {
  return $script:ConfigWarning
}

function Get-EngineRoot {
  return $script:ToolRoot
}
#endregion

#region 日志（缓冲批量写盘，避免扫描/清理期间逐行开合文件）
$script:LogBuffer = New-Object System.Collections.Generic.List[string]
$script:LogFlushThreshold = 20

function Write-CleanLog {
  param([string]$Message)
  try {
    if (-not (Test-Path -LiteralPath $script:LogDir)) {
      New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    }
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $script:LogBuffer.Add($line)
    if ($script:LogBuffer.Count -ge $script:LogFlushThreshold) {
      [IO.File]::AppendAllLines((Join-Path $script:LogDir 'cleanup.log'), $script:LogBuffer.ToArray(), [Text.UTF8Encoding]::new($false))
      $script:LogBuffer.Clear()
    }
  } catch { }
}

function Flush-CleanLog {
  try {
    if ($script:LogBuffer.Count -gt 0) {
      if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
      }
      [IO.File]::AppendAllLines((Join-Path $script:LogDir 'cleanup.log'), $script:LogBuffer.ToArray(), [Text.UTF8Encoding]::new($false))
      $script:LogBuffer.Clear()
    }
  } catch { }
}
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
  # 保留前导分隔符（Windows 绝对路径由盘符段处理；POSIX 绝对路径以 '/' 开头）
  $lead = ''
  if ($trimmed -match '^[\\/]') { $lead = [string]$trimmed[0] }
  $base = ''; $restIdx = $parts.Count
  for ($i = 0; $i -lt $parts.Count; $i++) {
    if ($parts[$i] -match '[\*\?]') { $restIdx = $i; break }
    if ($base -eq '') {
      if ($parts[$i] -match '^[A-Za-z]:$') { $base = $parts[$i] + '\' }
      elseif ($lead) { $base = $lead + $parts[$i] }
      else { $base = $parts[$i] }
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
  return , $result
}

function Get-ItemPaths {
  # 按 item.id 缓存展开路径（Get-ItemStamp 与 Get-ItemSize 共用，避免每次扫描展开两遍）
  param($Item)
  $key = [string]$Item.id
  if ($script:PathCache.ContainsKey($key)) { return $script:PathCache[$key] }
  $paths = New-Object System.Collections.Generic.List[string]
  foreach ($raw in @($Item.paths)) {
    foreach ($p in (Get-ExpandedPaths ([string]$raw))) { if ($p) { $paths.Add($p) } }
  }
  $arr = @($paths.ToArray())
  $script:PathCache[$key] = $arr
  return , $arr
}

function Clear-PathCache {
  $script:PathCache = @{}
}
#endregion

#region 白名单闸门（安全底线：受保护路径绝对不删）
$script:ProtectedRoots = @(
  'C:\', 'D:\', 'E:\', 'F:\', 'G:\', 'H:\', 'I:\', 'J:\', 'K:\', 'L:\',
  "$env:WINDIR", "$env:USERPROFILE",
  "$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:ProgramData"
)
$script:ForbiddenSubtrees = @(
  "$env:WINDIR\System32", "$env:WINDIR\WinSxS",
  "$env:WINDIR\assembly", "$env:WINDIR\SysWOW64",
  "$env:WINDIR\Boot", "$env:WINDIR\System32\config",
  "$env:SystemDrive\ProgramData\Microsoft\Windows\Start Menu",
  "$env:SystemDrive\ProgramData\Microsoft\Windows\Recovery",
  "$env:SystemDrive\System Volume Information",
  "$env:SystemDrive\Recovery",
  "$env:SystemDrive\bootmgr",
  "$env:SystemDrive\pagefile.sys",
  "$env:SystemDrive\hiberfil.sys",
  "$env:SystemDrive\swapfile.sys",
  "$env:SystemDrive\`$Recycle.Bin",
  "$env:ProgramFiles\WindowsApps",
  "$env:SystemDrive\ProgramData\Package Cache"
)
$script:DynamicWhitelist = @($script:ToolRoot)   # 工具自身目录，防"删到自己"

function Test-Whitelist {
  param([string]$FullPath)
  if (-not $FullPath) { return $false }
  try { $fp = [IO.Path]::GetFullPath($FullPath).TrimEnd('\') + '\' } catch { return $false }
  # UNC（网络共享）一律禁止：不在本机受控范围内
  if ($fp.StartsWith('\\')) { return $false }
  # 任意盘符的盘根一律禁止
  if ($fp -match '^[A-Za-z]:\\$') { return $false }
  # 显式放行工具自建的可丢弃测试数据（testdata，仅自测用、无真实数据）
  $testArea = Join-Path $script:ToolRoot 'testdata'
  try { $ta = [IO.Path]::GetFullPath($testArea).TrimEnd('\') + '\' } catch { $ta = '' }
  if ($ta -and $fp.StartsWith($ta, 'OrdinalIgnoreCase')) { return $true }
  # 规则1：目标是受保护根自身或其祖先（含工具目录祖先链）→ 禁止
  foreach ($w in ($script:ProtectedRoots + $script:DynamicWhitelist)) {
    try { $we = [IO.Path]::GetFullPath((Expand-EnvPath $w)).TrimEnd('\') + '\' } catch { continue }
    if ($we.StartsWith($fp, 'OrdinalIgnoreCase')) { return $false }
  }
  # 规则2：目标位于禁止子树内 → 一律禁止
  foreach ($w in $script:ForbiddenSubtrees) {
    try { $we = [IO.Path]::GetFullPath((Expand-EnvPath $w)).TrimEnd('\') + '\' } catch { continue }
    if ($fp.StartsWith($we, 'OrdinalIgnoreCase')) { return $false }
  }
  return $true
}
#endregion

#region 配置加载（内嵌兜底 + 外部 JSON 合并 + detect 筛选 + 用户自定义项合并）
$script:EmbeddedItemsJson = @'
[
  { "id":"sys_tmp_user","category":"system","name":"用户临时文件","desc":"临时文件，可安全删除","paths":["%LOCALAPPDATA%\\Temp"],"risk":"green","defaultChecked":true,"method":"delete-dir" },
  { "id":"sys_tmp_win","category":"system","name":"Windows 临时文件","desc":"系统临时文件","paths":["%WINDIR%\\Temp"],"risk":"green","defaultChecked":true,"method":"delete-dir" },
  { "id":"sys_crashdump","category":"system","name":"崩溃转储","desc":"应用崩溃转储","paths":["%LOCALAPPDATA%\\CrashDumps"],"risk":"green","defaultChecked":true,"method":"delete-dir" }
]
'@

# exec-process 可执行文件白名单（F1：配置被篡改也不能执行任意命令）
$script:ExecProcessWhitelist = @('dism.exe', 'docker.exe', 'taskkill.exe', 'reg.exe', 'cleanmgr.exe', 'sfc.exe', 'wevtutil.exe')
# 遗留 execCommand（PowerShell 表达式）首 token 白名单
$script:ExecCmdAllowlist = @('Clear-RecycleBin', 'Get-WinEvent', 'Remove-Item')

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
    'registry-exists' {
      foreach ($v in $Detect.value) {
        if (Test-Path -LiteralPath $v) { return $true }
      }
      return $false
    }
  }
  return $true
}

function Merge-UserItems {
  # 读取 runtime\user-items.json 并追加到内置/外部清单（id 不冲突），供用户自定义清理项
  param([object[]]$Base)
  $userPath = Join-Path $script:DataDir 'user-items.json'
  if (-not (Test-Path -LiteralPath $userPath)) { return $Base }
  try {
    $userItems = Get-Content -Raw -Encoding UTF8 $userPath | ConvertFrom-Json
    $ids = @{}
    foreach ($it in $Base) { if ($it.id) { $ids[[string]$it.id] = $true } }
    foreach ($it in $userItems) {
      if (-not $it.id -or $ids.ContainsKey([string]$it.id)) { continue }
      $ids[[string]$it.id] = $true
      $Base += $it
    }
  } catch {
    Write-CleanLog "用户自定义项解析失败: $($_.Exception.Message)"
  }
  return $Base
}

function Load-CleanupItems {
  $configPath = Join-Path $script:ToolRoot 'config\cleanup-items.json'
  $script:ConfigWarning = $null
  $items = $null
  if (Test-Path $configPath) {
    try {
      $items = Get-Content -Raw -Encoding UTF8 $configPath | ConvertFrom-Json
    } catch {
      $script:ConfigWarning = '配置文件解析失败，已回退内置兜底清单；损坏文件已备份，请检查 config\cleanup-items.json'
      Write-CleanLog "配置文件解析失败，回退内嵌默认: $($_.Exception.Message)"
      try {
        $bakDir = Join-Path $script:DataDir 'backups'
        if (-not (Test-Path -LiteralPath $bakDir)) { New-Item -ItemType Directory -Force -Path $bakDir | Out-Null }
        $bak = Join-Path $bakDir ('cleanup-items.bad-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
        Copy-Item -LiteralPath $configPath -Destination $bak -Force -ErrorAction SilentlyContinue
      } catch { }
    }
  }
  if (-not $items) {
    try { $items = $script:EmbeddedItemsJson | ConvertFrom-Json } catch { return @() }
  }
  $valid = New-Object System.Collections.Generic.List[object]
  $skipped = 0
  foreach ($it in $items) {
    if (-not $it.id) { $skipped++; continue }
    if (-not $it.category) { $it.category = 'app' }
    if (-not $it.name)  { $it.name = $it.id }
    if (-not $it.desc)  { $it.desc = '' }
    if ($null -eq $it.risk) { $it.risk = 'yellow' }
    if ($it.risk -notin 'green', 'yellow', 'red') { $it.risk = 'yellow' }
    if ($null -eq $it.defaultChecked) { $it.defaultChecked = ($it.risk -eq 'green') }
    if (-not $it.method) { $it.method = 'delete-dir' }
    if ($it.method -notin 'delete-dir', 'delete-file', 'exec', 'exec-process') {
      Write-CleanLog "配置项 [$($it.id)] 方法不受支持已跳过: $($it.method)"
      $skipped++; continue
    }
    if (-not $it.paths) { $it.paths = @() }
    # exec-process：进程必须在白名单内，否则拒绝加载（安全底线）
    if ($it.method -eq 'exec-process') {
      $procName = [IO.Path]::GetFileName([string]$it.process).ToLower()
      if (-not $it.process -or $procName -notin $script:ExecProcessWhitelist) {
        Write-CleanLog "配置项 [$($it.id)] 命令不在白名单已跳过: $($it.process)"
        $skipped++; continue
      }
    }
    # detect 为可选字段，用 PSObject.Properties 访问避免 StrictMode 抛异常
    $detProp = $it.PSObject.Properties['detect']
    $detect = if ($detProp) { $detProp.Value } else { $null }
    if (-not (Test-Detect $detect)) { continue }
    $valid.Add($it)
  }
  if ($skipped -gt 0) {
    $script:ConfigWarning = "配置中有 $skipped 项无效已跳过，详见日志"
  }
  return @(Merge-UserItems $valid.ToArray())
}
#endregion

#region 扫描引擎（高性能目录大小 + size-cache）
function Measure-DirBytes {
  # 迭代（栈）遍历：消除深递归函数调用开销；跳过重解析点（Junction）防死循环
  param([string]$Root)
  $total = 0L
  if (-not (Test-Path -LiteralPath $Root)) { return 0L }
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
    } catch { }
  }
  return $total
}

function Save-SizeCache {
  try {
    $obj = [ordered]@{}
    foreach ($k in $script:SizeCache.Keys) {
      $v = $script:SizeCache[$k]
      if ($v -is [hashtable]) { $obj[$k] = @{ b = [long]$v.b; t = [long]$v.t } }
      else { $obj[$k] = @{ b = [long]$v; t = -1L } }
    }
    $json = $obj | ConvertTo-Json -Depth 4
    if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null }
    [IO.File]::WriteAllText((Join-Path $script:DataDir 'size-cache.json'), $json, [Text.UTF8Encoding]::new($false))
  } catch { }
}

function Load-SizeCache {
  # 原地清空后重填（.Clear()），绝不重建对象——worker runspace 持有共享缓存引用
  $script:SizeCache.Clear()
  try {
    $p = Join-Path $script:DataDir 'size-cache.json'
    if (Test-Path $p) {
      $o = Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json
      foreach ($prop in $o.PSObject.Properties) {
        $v = $prop.Value
        if ($v -is [pscustomobject]) {
          $b = 0L; $t = -1L
          $bp = $v.PSObject.Properties['b']; if ($bp) { $b = [long]$bp.Value }
          $tp = $v.PSObject.Properties['t']; if ($tp) { $t = [long]$tp.Value }
          $script:SizeCache[$prop.Name] = @{ b = $b; t = $t }
        } else {
          $script:SizeCache[$prop.Name] = @{ b = [long]$v; t = -1L }
        }
      }
    }
  } catch {
    # 缓存文件损坏兜底（S8）：备份损坏文件后忽略，下次启动全量重测
    Write-CleanLog ('尺寸缓存损坏，已忽略并备份: ' + $_.Exception.Message)
    try {
      $p = Join-Path $script:DataDir 'size-cache.json'
      if (Test-Path $p) {
        $bk = Join-Path $script:DataDir 'backups'
        if (-not (Test-Path -LiteralPath $bk)) { New-Item -ItemType Directory -Force -Path $bk | Out-Null }
        Copy-Item -LiteralPath $p -Destination (Join-Path $bk ('size-cache.bad-{0}.json' -f (Get-Date -Format 'yyyyMMddHHmmss'))) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
      }
    } catch { }
  }
}

function Clear-SizeCache {
  # 原地清空（.Clear()），绝不重建对象——worker runspace 持有旧引用，重建会孤儿化共享缓存
  $script:SizeCache.Clear()
  $p = Join-Path $script:DataDir 'size-cache.json'
  if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}

function Get-ItemStamp {
  # 清理项所有展开根路径的时间戳指纹（根目录时间 + 路径数量），任一变化 → 缓存失效重测
  # 用 .NET 静态读取取代 Get-Item cmdlet（无解释器逐路径开销）；不存在路径不计入
  param($Item)
  $stamp = 0L
  $paths = @(Get-ItemPaths $Item)
  foreach ($p in $paths) {
    try {
      $t = 0L
      if ([IO.File]::Exists($p)) { $t = [IO.File]::GetLastWriteTimeUtc($p).Ticks }
      elseif ([IO.Directory]::Exists($p)) { $t = [IO.DirectoryInfo]::new($p).LastWriteTimeUtc.Ticks }
      if ($t -gt $stamp) { $stamp = $t }
    } catch { }
  }
  return ($stamp + $paths.Count)   # 路径集合变化也计入指纹
}

function Test-AgeEligible {
  # minAgeDays 过滤：仅删除早于 N 天的文件（delete-file 项用）
  param([string]$Path, $MinAgeDays)
  if (-not $MinAgeDays -or [long]$MinAgeDays -le 0) { return $true }
  try {
    $lt = [IO.File]::GetLastWriteTimeUtc($Path)
    return (([DateTime]::UtcNow) - $lt).TotalDays -ge [double]$MinAgeDays
  } catch { return $true }
}

function Get-ItemSize {
  param($Item, [switch]$Force)
  if ($Item.method -eq 'exec' -or $Item.method -eq 'exec-process') { return 0L }
  $stamp = Get-ItemStamp $Item
  if (-not $Force -and $script:SizeCache.ContainsKey($Item.id)) {
    $ent = $script:SizeCache[$Item.id]
    if ($ent -is [hashtable] -and $ent.t -eq $stamp) { return [long]$ent.b }
  }
  $total = 0L
  foreach ($p in (Get-ItemPaths $Item)) {
    try {
      if ($Item.method -eq 'delete-file') {
        if ([IO.File]::Exists($p)) {
          if (Test-AgeEligible -Path $p -MinAgeDays $Item.minAgeDays) { $total += ([IO.FileInfo]::new($p)).Length }
        }
      } else {
        if ([IO.Directory]::Exists($p)) { $total += Measure-DirBytes $p }
      }
    } catch { }
  }
  $script:SizeCache[$Item.id] = @{ b = $total; t = $stamp }
  return $total
}
#endregion

#region 删除引擎（安全优先：默认回收站，占用自动跳过，保留根目录）
function Add-FailureNote {
  param([System.Collections.Generic.List[string]]$Log, [string]$Text)
  if ($Log) {
    try {
      if ($Log.Count -lt 200) { $Log.Add($Text) }
    } catch { }
  }
}

function Remove-DirContents {
  # 统一迭代实现（无深递归，防栈溢出）：
  #  - Recycle：保留根目录；子目录整棵进回收站（先测量用于报告），失败则逐项降级
  #  - Permanent：逐个删除文件并累计实际释放字节（无需预测量，P1）；目录后序删除
  # 重解析点只删链接本身，绝不枚举进链接目标
  param([string]$Dir, [string]$Mode, [System.Collections.Generic.List[string]]$FailureLog = $null)
  try {
    if ([IO.DirectoryInfo]::new($Dir).Attributes -band [IO.FileAttributes]::ReparsePoint) {
      try {
        if ($Mode -eq 'Recycle') {
          [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Dir, 'OnlyErrorDialogs', 'SendToRecycleBin', 'ThrowException')
        } else {
          [IO.Directory]::Delete($Dir, $false)
        }
      } catch { Add-FailureNote $FailureLog ("重解析点删除失败: $Dir") }
      return 0L
    }
  } catch { }
  $released = 0L
  $stack = New-Object System.Collections.Generic.Stack[string]
  $deleteStack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($Dir)
  while ($stack.Count -gt 0) {
    $d = $stack.Pop()
    # 直接文件
    try {
      foreach ($f in [IO.Directory]::EnumerateFiles($d)) {
        try {
          $sz = ([IO.FileInfo]::new($f)).Length
          if ($Mode -eq 'Recycle') {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f, 'OnlyErrorDialogs', 'SendToRecycleBin')
          } else {
            [IO.File]::Delete($f)
          }
          $released += $sz
        } catch { Add-FailureNote $FailureLog ("文件删除失败: $f") }
      }
    } catch { Add-FailureNote $FailureLog ("目录枚举失败: $d") }
    # 子目录
    try {
      foreach ($cd in [IO.Directory]::EnumerateDirectories($d)) {
        $isReparse = $false
        try { $isReparse = ([IO.DirectoryInfo]::new($cd).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } catch { }
        if ($isReparse) {
          # 重解析点子目录：只删链接本身
          try {
            if ($Mode -eq 'Recycle') {
              [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($cd, 'OnlyErrorDialogs', 'SendToRecycleBin', 'ThrowException')
            } else {
              [IO.Directory]::Delete($cd, $false)
            }
          } catch { Add-FailureNote $FailureLog ("链接删除失败: $cd") }
          continue
        }
        if ($Mode -eq 'Recycle') {
          try {
            $sz = Measure-DirBytes $cd
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($cd, 'OnlyErrorDialogs', 'SendToRecycleBin', 'ThrowException')
            $released += $sz
          } catch {
            $stack.Push($cd)   # 整体回收失败（占用等）→ 逐项降级（保留该目录根）
          }
        } else {
          $stack.Push($cd)
        }
      }
    } catch { Add-FailureNote $FailureLog ("子目录枚举失败: $d") }
    if ($Mode -eq 'Permanent' -and $d -ne $Dir) { $deleteStack.Push($d) }
  }
  if ($Mode -eq 'Permanent') {
    while ($deleteStack.Count -gt 0) {
      $d = $deleteStack.Pop()
      try { [IO.Directory]::Delete($d, $false) } catch { Add-FailureNote $FailureLog ("目录删除失败: $d") }
    }
    try { [IO.Directory]::Delete($Dir, $false) } catch { Add-FailureNote $FailureLog ("根目录删除失败: $Dir") }
  }
  return $released
}

function Remove-PatternFile {
  param([string]$Path, [string]$Mode, $MinAgeDays = $null, [System.Collections.Generic.List[string]]$FailureLog = $null)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0L }
  if (-not (Test-AgeEligible -Path $Path -MinAgeDays $MinAgeDays)) { return 0L }
  try {
    $sz = ([IO.FileInfo]::new($Path)).Length
    if ($Mode -eq 'Recycle') {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    } else {
      [IO.File]::Delete($Path)
    }
    return $sz
  } catch {
    Add-FailureNote $FailureLog ("文件删除失败: $Path")
    return 0L
  }
}

function Invoke-PsExpressionTimed {
  # 在独立 runspace 中执行遗留 PowerShell 表达式并限时中止（替代 Start-Job 起进程）
  param([string]$Expression, [int]$TimeoutSec = 120)
  $rs = [runspacefactory]::CreateRunspace()
  $rs.Open()
  $ps = [powershell]::Create(); $ps.Runspace = $rs
  $res = ''
  try {
    $null = $ps.AddScript($Expression)
    $handle = $ps.BeginInvoke()
    if (-not $handle.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSec))) {
      try { $ps.Stop() } catch { }
      $res = 'TIMEOUT(已中止)'
    } else {
      try { $res = ($ps.EndInvoke($handle) | Out-String) } catch { $res = "ERR: $($_.Exception.Message)" }
    }
  } catch {
    $res = "ERR: $($_.Exception.Message)"
  } finally {
    $ps.Dispose(); $rs.Dispose()
  }
  return $res
}

function Invoke-ExecItem {
  param($Item)
  if ($Item.method -eq 'exec-process') {
    # 结构化进程执行：白名单校验 + 参数数组（无 shell 解释）+ 超时终止进程树
    $procName = [IO.Path]::GetFileName([string]$Item.process).ToLower()
    if ($procName -notin $script:ExecProcessWhitelist) {
      Write-CleanLog "拒绝执行未授权命令: $($Item.process)"
      return 0L
    }
    $src = (Get-Command $Item.process -ErrorAction SilentlyContinue).Source
    if (-not $src) { $src = [string]$Item.process }
    $timeout = if ($Item.timeoutSec) { [int]$Item.timeoutSec } else { 300 }
    Write-CleanLog "执行进程项: $($Item.name) ($src)"
    try {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $src
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $argParts = @()
      foreach ($a in @($Item.args)) {
        $s = [string]$a
        $argParts += ('"' + ($s -replace '"', '\"') + '"')
      }
      $psi.Arguments = $argParts -join ' '
      $p = [System.Diagnostics.Process]::new()
      $p.StartInfo = $psi
      if (-not $p.Start()) {
        Write-CleanLog "进程启动失败: $($Item.process)"
        return 0L
      }
      if (-not $p.WaitForExit($timeout * 1000)) {
        try { $null = & taskkill.exe /PID $p.Id /T /F 2>$null } catch { }
        Write-CleanLog "命令超时已终止: $($Item.process)"
        return 0L
      }
      $out = try { $p.StandardOutput.ReadToEnd() } catch { '' }
      $err = try { $p.StandardError.ReadToEnd() } catch { '' }
      Write-CleanLog "进程结果($($Item.process)): exit=$($p.ExitCode) $out $err"
      return 0L
    } catch {
      Write-CleanLog "进程执行失败: $($Item.name) :: $($_.Exception.Message)"
      return 0L
    }
  }
  # 遗留 execCommand（PowerShell 表达式）：首 token 白名单 + 独立 runspace 限时执行
  $cmd = [string]$Item.execCommand
  $first = (($cmd -split '\s+') | Where-Object { $_ } | Select-Object -First 1)
  $first = ($first -replace '^&', '' -replace '^"', '' -replace '"$', '')
  if ($first -notin $script:ExecCmdAllowlist) {
    Write-CleanLog "拒绝执行未授权表达式: $first"
    return 0L
  }
  $timeout = if ($Item.execTimeoutSec) { [int]$Item.execTimeoutSec } else { 120 }
  Write-CleanLog "执行命令项: $($Item.name)"
  $res = Invoke-PsExpressionTimed -Expression $cmd -TimeoutSec $timeout
  Write-CleanLog "命令项结果: $res"
  return 0L
}

function Invoke-SafeDelete {
  # 统一删除入口：白名单闸门 + 回收站/永久模式 + 逐项日志 + 失败明细
  param($Item, [string]$Mode)
  $released = 0L
  $skipped = 0
  $failed = 0
  $failures = New-Object System.Collections.Generic.List[string]
  if ($Item.method -eq 'exec' -or $Item.method -eq 'exec-process') {
    $released = Invoke-ExecItem $Item
    return [pscustomobject]@{ Name = $Item.name; Released = $released; Skipped = 0; Failed = 0; FailureText = '' }
  }
  foreach ($p in (Get-ItemPaths $Item)) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $full = [IO.Path]::GetFullPath($p)
    if (-not (Test-Whitelist $full)) {
      Write-CleanLog "跳过(受保护路径): $full"
      $skipped++
      continue
    }
    try {
      if ($Item.method -eq 'delete-file') {
        $released += Remove-PatternFile -Path $full -Mode $Mode -MinAgeDays $Item.minAgeDays -FailureLog $failures
      } else {
        $released += Remove-DirContents -Dir $full -Mode $Mode -FailureLog $failures
      }
      Write-CleanLog "已清理: $($Item.name) :: $full"
    } catch {
      $failed++
      $failures.Add("清理失败: $($Item.name) :: $full :: $($_.Exception.Message)")
      Write-CleanLog "清理失败: $($Item.name) :: $full :: $($_.Exception.Message)"
    }
  }
  $failed += $failures.Count
  return [pscustomobject]@{
    Name        = $Item.name
    Released    = $released
    Skipped     = $skipped
    Failed      = $failed
    FailureText = ($failures -join ' | ')
  }
}

function Csv-Quote {
  param($Value)
  return '"' + ([string]$Value -replace '"', '""') + '"'
}

function Export-CleanReport {
  # 清理完成后自动导出 CSV 报告（UTF-8 BOM 便于 Excel 打开）；所有字段统一转义
  param(
    [object[]]$Details,
    [long]$Planned = 0,
    [long]$Released = 0,
    [int]$Skipped = 0,
    [int]$Failed = 0,
    [string]$Mode = 'Recycle',
    [string]$Note = ''
  )
  try {
    $dir = Join-Path $script:DataDir 'reports'
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $file = Join-Path $dir ('clean-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('时间,模式,项目,分类,风险,计划大小(字节),实际释放(字节),跳过数,失败数')
    foreach ($d in $Details) {
      $lines.Add(('{0},{1},{2},{3},{4},{5},{6},{7},{8}' -f $ts, (Csv-Quote $Mode), (Csv-Quote $d.Name), (Csv-Quote $d.Category), (Csv-Quote $d.Risk), [long]$d.Size, [long]$d.Released, [int]$d.Skipped, [int]$d.Failed))
    }
    $lines.Add(('{0},{1},{2},,,{3},{4},{5},{6}' -f $ts, (Csv-Quote $Mode), (Csv-Quote '合计'), $Planned, $Released, $Skipped, $Failed))
    if ($Note) { $lines.Add(('{0},{1},{2},,,0,0,0,0' -f $ts, (Csv-Quote $Mode), (Csv-Quote ('备注: ' + $Note)))) }
    [IO.File]::WriteAllLines($file, $lines, (New-Object System.Text.UTF8Encoding $true))
    return $file
  } catch {
    Write-CleanLog ('清理报告导出失败: ' + $_.Exception.Message)
    return $null
  }
}
#endregion

#region 附加功能引擎（空间 / 大文件 / 空文件夹 / 内存 / 软件 / 重复 / 还原点 / 启动项）
function Get-FixedDrives {
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
  # 首 64KB 部分哈希：重复检测预筛用
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

# ---------- 空间分析 ----------
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
  param([System.Collections.Generic.Dictionary[string,long]]$Own)
  $total = New-Object 'System.Collections.Generic.Dictionary[string,long]'
  $keys = [string[]]$Own.Keys
  $cmp = [System.Comparison[string]] { param($a, $b) $b.Length.CompareTo($a.Length) }
  [System.Array]::Sort($keys, $cmp)
  foreach ($k in $keys) { $total[$k] = $Own[$k] }
  foreach ($k in $keys) {
    $pi = $k.LastIndexOfAny([char[]]@('\', '/'))
    if ($pi -gt 0) {
      $parent = $k.Substring(0, $pi)
      if ($total.ContainsKey($parent)) { $total[$parent] += $total[$k] }
    }
  }
  return $total
}

function Build-ChildrenIndex {
  # 构建一次 parent -> [direct children]，下钻从 O(全盘目录数) 降到 O(子项数)
  param([System.Collections.Generic.Dictionary[string,long]]$Total)
  $idx = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]'
  foreach ($k in @($Total.Keys)) {
    $pi = $k.LastIndexOfAny([char[]]@('\', '/'))
    if ($pi -le 0) { continue }
    $parent = $k.Substring(0, $pi)
    if (-not $Total.ContainsKey($parent)) { continue }
    if (-not $idx.ContainsKey($parent)) { $idx[$parent] = New-Object 'System.Collections.Generic.List[string]' }
    $idx[$parent].Add($k)
  }
  return $idx
}

# ---------- 大文件 ----------
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
            $result.Add([pscustomobject]@{
              Name = $fi.Name; Size = $fi.Length; Modified = $fi.LastWriteTime
              Path = $fi.FullName
              SizeText = (Format-EngineBytes $fi.Length)
              ModifiedText = $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            })
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

# ---------- 空文件夹 ----------
function Get-EmptyDirs {
  # 找出可安全删除的空目录（级联判定）；只输出"空子树顶端"
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
      if ($di.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
      foreach ($f in [IO.Directory]::EnumerateFiles($dir)) { $fc++ }
      foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) {
        try {
          if (([IO.DirectoryInfo]::new($d)).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $kids.Add($d)
            continue
          }
          $kids.Add($d)
          $stack.Push($d)
        } catch { $kids.Add($d) }
      }
    } catch { continue }
    $files[$dir] = $fc
    $children[$dir] = $kids
    $dirs++
    if (($dirs % 500) -eq 0 -and $W) { $W.ReportProgress(0, ("已扫描 {0} 个目录..." -f $dirs)) }
  }
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
  $result = New-Object System.Collections.Generic.List[object]
  foreach ($k in $keys) {
    if (-not $empty.Contains($k)) { continue }
    $pi = $k.LastIndexOfAny([char[]]@('\', '/'))
    if ($pi -gt 0) {
      $parent = $k.Substring(0, $pi)
      if ($empty.Contains($parent)) { continue }
    }
    $result.Add([pscustomobject]@{ Path = $k; Name = [IO.Path]::GetFileName($k) })
  }
  return $result
}

# ---------- 系统加速（内存） ----------
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
    [DllImport("ntdll.dll")]
    public static extern int RtlAdjustPrivilege(int privilege, bool enable, bool currentThread, out bool enabled);
  }
}
"@ -ErrorAction SilentlyContinue
}

function Get-MemoryInfoText {
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
  param([int]$Command)
  $enabled = $false
  $null = [DiskCleanerPro.NativeMem]::RtlAdjustPrivilege(13, $true, $false, [ref]$enabled)
  $i = $Command
  $st = [DiskCleanerPro.NativeMem]::NtSetSystemInformation(80, [ref]$i, 4)
  if ($st -ne 0) {
    $null = [DiskCleanerPro.NativeMem]::RtlAdjustPrivilege(5, $true, $false, [ref]$enabled)
    $i = $Command
    $st = [DiskCleanerPro.NativeMem]::NtSetSystemInformation(80, [ref]$i, 4)
  }
  return $st
}

function Test-IsAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

# ---------- 软件占用 ----------
function Get-InstalledSoftware {
  $rows = New-Object System.Collections.Generic.List[object]
  $keys = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  $seen = @{}
  foreach ($k in $keys) {
    if (-not (Test-Path $k)) { continue }
    foreach ($sub in (Get-Item $k)) {
      try {
        $name = $sub.GetValue('DisplayName')
        if (-not $name) { continue }
        $loc = $sub.GetValue('InstallLocation')
        $est = $sub.GetValue('EstimatedSize')
        $ver = [string]$sub.GetValue('DisplayVersion')
        # 去重：同名同版本只保留第一个（含安装位置的优先）
        $dedupeKey = ([string]$name).Trim().ToLower() + '|' + $ver.Trim().ToLower()
        if ($seen.ContainsKey($dedupeKey)) { continue }
        $seen[$dedupeKey] = $true
        $rows.Add([pscustomobject]@{
          Name      = [string]$name
          Publisher = [string]$sub.GetValue('Publisher')
          Version   = $ver
          Location  = [string]$loc
          RegKB     = if ($est) { [long]$est } else { 0L }
          RealBytes = 0L
          SizeText  = ''
          RealText  = ''
        })
      } catch { }
    }
  }
  return $rows
}

# ---------- 重复文件 ----------
function Get-DupeGroups {
  # 大小分桶(跳过<1MB) → 首 64KB 预筛 → SHA-256 全量（并行）→ 同哈希=重复组
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
          if ($fi.Length -lt 1048576) { continue }
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
  # 阶段1：首 64KB 头部哈希预筛
  $fullJobs = New-Object System.Collections.Generic.List[object]
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
  # 阶段2：仅对头部相同的组做全量 SHA-256（并行）
  $byHash = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Collections.Generic.List[string]]]::new()
  $hashTotal = 0
  foreach ($job in $fullJobs) {
    $hashTotal += $job.Paths.Count
  }
  $hashDone = 0
  $lock = New-Object object
  try {
    $actions = New-Object System.Collections.Generic.List[System.Action[string]]
    foreach ($job in $fullJobs) {
      foreach ($f in $job.Paths) {
        $path = [string]$f
        $actions.Add([System.Action[string]]{
          param($fp)
          if ($W -and $W.CancellationPending) { return }
          $h = Get-FileHashSha256 $fp
          if (-not $h) { return }
          $list = $byHash.GetOrAdd($h, { New-Object System.Collections.Generic.List[string] })
          [System.Threading.Monitor]::Enter($lock)
          try { $list.Add($fp) } finally { [System.Threading.Monitor]::Exit($lock) }
          [System.Threading.Monitor]::Enter($lock)
          try { $hashDone++ } finally { [System.Threading.Monitor]::Exit($lock) }
          if (($hashDone % 50) -eq 0 -and $W) { $W.ReportProgress(0, ("全量哈希 {0}/{1}..." -f $hashDone, $hashTotal)) }
        })
      }
    }
    [System.Threading.Tasks.Parallel]::ForEach($actions, [System.Threading.Tasks.ParallelOptions]::new(), [System.Action[System.Action[string]]]{
      param($a) $a.Invoke()
    })
  } catch {
    # 并行失败 → 串行兜底
    foreach ($job in $fullJobs) {
      foreach ($f in $job.Paths) {
        if ($W -and $W.CancellationPending) { return $null }
        $h = Get-FileHashSha256 $f
        if (-not $h) { continue }
        $list = $byHash.GetOrAdd($h, { New-Object System.Collections.Generic.List[string] })
        $null = $list.Add($f)
      }
    }
  }
  $result = New-Object System.Collections.Generic.List[object]
  $g = 0
  foreach ($h in @($byHash.Keys)) {
    $list = $byHash[$h]
    if ($list.Count -lt 2) { continue }
    $g++
    $size = 0L
    try { $size = ([IO.FileInfo]::new($list[0])).Length } catch { }
    $keep = ($list | Sort-Object @{ Expression = { $_.Length } }, @{ Expression = { $_ } })[0]
    foreach ($f in $list) {
      $result.Add([pscustomobject]@{
        Group = $g; Size = $size; Path = $f; Keep = ($f -eq $keep)
        IsMarked = (-not ($f -eq $keep))
        SizeText = (Format-EngineBytes $size)
      })
    }
  }
  return $result
}

# ---------- 还原点 ----------
function Get-RestorePoints {
  $p = @()
  try { $p = @(Get-ComputerRestorePoint -ErrorAction Stop) } catch { $p = @() }
  return , $p
}

function Remove-OldRestorePoints {
  $pts = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)
  if ($pts.Count -le 3) { return 0 }
  $toDelete = $pts | Sort-Object CreationTime | Select-Object -First ($pts.Count - 3)
  $del = 0
  foreach ($rp in $toDelete) {
    try { Remove-ComputerRestorePoint -RestorePoint $rp.SequenceNumber -ErrorAction Stop; $del++ } catch { }
  }
  return $del
}

# ---------- 启动项 ----------
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
        try {
          $status = Get-StartupApprovedStatus -ValueName $n -Source $k.Src
          $rows.Add([pscustomobject]@{
            Source = $k.Src; Name = $n; Command = [string]$key.GetValue($n); Status = $status
            StatusText = $(if ($status -eq 'Disabled') { '已禁用' } elseif ($status -eq 'Enabled') { '启用' } else { '未知' })
          })
        } catch { }
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
            $rows.Add([pscustomobject]@{
              Source = $fd.Src; Name = [IO.Path]::GetFileName($f); Command = $f; Status = 'Unknown'; StatusText = '未知'
            })
          }
        }
      } catch { }
    }
  } catch { }
  return $rows
}

function Get-StartupApprovedStatus {
  # 读取 StartupApproved 二进制标记：首字节 02=启用 / 03=已禁用 / 无记录=未知
  param([string]$ValueName, [string]$Source)
  try {
    $paths = @(
      'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
      'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
      'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
    )
    foreach ($p in $paths) {
      if (-not (Test-Path $p)) { continue }
      $key = Get-Item $p
      $val = $key.GetValue($ValueName, $null)
      if ($null -ne $val -and $val -is [byte[]] -and $val.Length -ge 1) {
        return $(if ($val[0] -eq 2) { 'Enabled' } elseif ($val[0] -eq 3) { 'Disabled' } else { 'Unknown' })
      }
    }
  } catch { }
  return 'Unknown'
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
#endregion

#region 引擎侧字节格式化
function Format-EngineBytes {
  # 引擎侧字节格式化（大文件/重复文件行数据预格式化用，UI 主脚本另有 Format-Bytes）
  param([long]$Bytes)
  if ($Bytes -le 0) { return '0 B' }
  $units = 'B', 'KB', 'MB', 'GB', 'TB'
  $i = 0; $v = [double]$Bytes
  while ($v -ge 1024 -and $i -lt 4) { $v /= 1024; $i++ }
  return ('{0:N1} {1}' -f $v, $units[$i])
}
#endregion

#region 导出
Export-ModuleMember -Function @(
  'Initialize-Engine', 'Set-EngineSharedCache', 'Get-ConfigWarning', 'Get-EngineRoot',
  'Write-CleanLog', 'Flush-CleanLog',
  'Expand-EnvPath', 'Get-ExpandedPaths', 'Get-ItemPaths', 'Clear-PathCache',
  'Test-Whitelist', 'Test-Detect', 'Load-CleanupItems',
  'Measure-DirBytes', 'Save-SizeCache', 'Load-SizeCache', 'Clear-SizeCache',
  'Get-ItemStamp', 'Get-ItemSize', 'Test-AgeEligible',
  'Remove-DirContents', 'Remove-PatternFile', 'Invoke-ExecItem', 'Invoke-SafeDelete',
  'Export-CleanReport', 'Csv-Quote',
  'Get-EngineSharedCache',
  'Get-FixedDrives', 'Open-InExplorer', 'Remove-UserPathToRecycle',
  'Get-FileHashSha256', 'Get-FileHashSha256Partial',
  'Get-DirSizes', 'Get-MergedDirTotals', 'Build-ChildrenIndex',
  'Get-LargeFiles', 'Get-EmptyDirs',
  'Get-MemoryInfoText', 'Invoke-MemoryPurge', 'Test-IsAdmin',
  'Get-InstalledSoftware', 'Get-DupeGroups',
  'Get-RestorePoints', 'Remove-OldRestorePoints',
  'Get-StartupItems', 'Get-StartupApprovedStatus', 'Backup-StartupReg',
  'Format-EngineBytes'
)

function Format-EngineBytes {
  # 引擎侧字节格式化（大文件/重复文件行数据预格式化用，UI 主脚本另有 Format-Bytes）
  param([long]$Bytes)
  if ($Bytes -le 0) { return '0 B' }
  $units = 'B', 'KB', 'MB', 'GB', 'TB'
  $i = 0; $v = [double]$Bytes
  while ($v -ge 1024 -and $i -lt 4) { $v /= 1024; $i++ }
  return ('{0:N1} {1}' -f $v, $units[$i])
}
#endregion
