# ============================================================
#  Engine.Tests.ps1 - 引擎模块跨平台单元测试（Linux/Windows 通用）
#  用法: pwsh -NoProfile -File Tests\Engine.Tests.ps1
#  约定：仅在测试目录内写数据，用完即删；Windows 专属能力（回收站/注册表/WMI/还原点）
#  在 Linux 下自动跳过并标注 SKIP（不影响 PASS/FAIL 结论）。
# ============================================================
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Continue'
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Assert-True {
  param([bool]$Cond, [string]$Name)
  if ($Cond) { $script:Pass++; Write-Host ('  PASS  ' + $Name) }
  else       { $script:Fail++; Write-Host ('  FAIL  ' + $Name) }
}
function Assert-Skip {
  param([string]$Name)
  $script:Skip++
  Write-Host ('  SKIP  ' + $Name)
}

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Engine.psm1') -Force
$engineRoot = Initialize-Engine
Assert-True ($engineRoot -eq $root) ('EngineRoot = ' + $root)

$td = Join-Path ([IO.Path]::GetTempPath()) ('engine-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $td | Out-Null
Write-Host ('== Engine Tests (testdata: ' + $td + ') ==')
try {
  # ---- 1) 大小计算 ----
  $dir = Join-Path $td 'size'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  1..5 | ForEach-Object { [IO.File]::WriteAllBytes((Join-Path $dir ('f' + $_ + '.txt')), (New-Object byte[] 1000)) }
  Assert-True ((Measure-DirBytes $dir) -eq 5000) 'Measure-DirBytes 5KB'
  New-Item -ItemType Directory -Force -Path (Join-Path $dir 'sub') | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $dir (Join-Path 'sub' 's.bin')), (New-Object byte[] 2500))
  Assert-True ((Measure-DirBytes $dir) -eq 7500) 'Measure-DirBytes 含子目录 7.5KB'

  # ---- 2) 空间分析：Get-DirSizes + Get-MergedDirTotals + Build-ChildrenIndex ----
  $tree = Join-Path $td 'tree'
  foreach ($d in @('a', 'b\c', 'd')) { New-Item -ItemType Directory -Force -Path (Join-Path $tree $d) | Out-Null }
  [IO.File]::WriteAllBytes((Join-Path $tree (Join-Path 'a' 'f1')), (New-Object byte[] 1000))
  [IO.File]::WriteAllBytes((Join-Path $tree (Join-Path 'b' 'f2')), (New-Object byte[] 2000))
  [IO.File]::WriteAllBytes((Join-Path $tree (Join-Path 'b' (Join-Path 'c' 'f3'))), (New-Object byte[] 3000))
  $own = Get-DirSizes -Root $tree
  $tot = Get-MergedDirTotals -Own $own
  $idx = Build-ChildrenIndex -Total $tot
  Assert-True ($tot[$tree] -eq 6000) '树总占用 6000'
  $bDir = Join-Path $tree 'b'
  Assert-True ($tot[$bDir] -eq 5000) 'b 总占用 5000（含 c）'
  $cDir = Join-Path $tree (Join-Path 'b' 'c')
  Assert-True ($tot[$cDir] -eq 3000) 'c 总占用 3000'
  $kids = $idx[$tree]
  Assert-True ($kids -and $kids.Count -eq 3) ('根子级索引 3 项（实测 ' + $(if ($kids) { $kids.Count } else { 0 }) + '）')
  Assert-True ($kids -contains $bDir) '子级索引含 b'

  # ---- 3) 大文件分析 ----
  $lf = Get-LargeFiles -Root $tree -ThresholdMB 1
  Assert-True ($lf.Count -ge 1) ('大文件 >=1（实测 ' + $lf.Count + '）')
  Assert-True ($lf[0].Size -ge 1000) '大文件 Size 字段正确'

  # ---- 4) 空文件夹 ----
  $empty = Join-Path $td 'empties'
  New-Item -ItemType Directory -Force -Path (Join-Path $empty 'e1') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $empty (Join-Path 'e2' 'sub')) | Out-Null
  [IO.File]::WriteAllText((Join-Path $empty 'keep.txt'), 'x')
  $es = Get-EmptyDirs -Root $empty
  Assert-True (@($es | Where-Object { $_.Path -eq (Join-Path $empty 'e2') }).Count -eq 1) '空子树顶端 e2 命中'
  Assert-True (@($es | Where-Object { $_.Path -eq (Join-Path $empty (Join-Path 'e2' 'sub')) }).Count -eq 0) '顶端之下的空目录不重复输出'
  Assert-True (@($es | Where-Object { $_.Path -eq $empty }).Count -eq 0) '非空根目录不判空'

  # ---- 5) 重复文件：Get-DupeGroups（>=1MB 分桶） ----
  $dup = Join-Path $td 'dup'
  New-Item -ItemType Directory -Force -Path $dup | Out-Null
  $big = New-Object byte[] 1100000
  $big2 = New-Object byte[] 1100000
  [IO.File]::WriteAllBytes((Join-Path $dup 'same1.bin'), $big)
  [IO.File]::WriteAllBytes((Join-Path $dup 'same2.bin'), $big)
  [IO.File]::WriteAllBytes((Join-Path $dup 'diff.bin'), $big2)
  $big2[0] = 1
  [IO.File]::WriteAllBytes((Join-Path $dup 'diff.bin'), $big2)
  $rows = @(Get-DupeGroups -Root $dup)
  Assert-True ($rows.Count -eq 2) ('同内容成组 2 行（实测 ' + $rows.Count + '）')
  Assert-True (@($rows | Where-Object { $_.Keep }).Count -eq 1) '每组保留 1 个'
  Assert-True (@($rows | Where-Object { $_.Group -eq $rows[0].Group }).Count -eq 2) '同组 2 个副本'
  Assert-True (@($rows | Where-Object { $_.Path -like '*diff.bin' }).Count -eq 0) '异内容不进组'

  # ---- 6) 哈希 ----
  $f = Join-Path $dir 'f1.txt'
  $h1 = Get-FileHashSha256 $f
  $h2 = Get-FileHashSha256 $f
  Assert-True ($h1 -eq $h2) 'SHA256 稳定'
  $p1 = Get-FileHashSha256Partial $f 64
  Assert-True ($p1.Length -eq 64) '部分哈希 64 位'

  # ---- 7) 白名单 ----
  Assert-True (Test-Whitelist (Join-Path $td 'any')) '测试目录允许'
  Assert-True (-not (Test-Whitelist $root)) '工具自身目录被拒绝'
  Assert-True (-not (Test-Whitelist '')) '空路径拒绝'

  # ---- 8) 配置加载 ----
  $items = Load-CleanupItems
  Assert-True ($items.Count -ge 10) ('配置加载 >=10 项（实测 ' + $items.Count + '）')
  $hasExec = @($items | Where-Object { $_.method -eq 'exec' }).Count
  Assert-True ($hasExec -ge 1) ('exec 型项存在（实测 ' + $hasExec + '）')
  $warning = Get-ConfigWarning
  Assert-True ($null -eq $warning) '配置无警告'

  # ---- 9) 缓存回环 ----
  $cache = Get-EngineSharedCache
  $cache['test_key'] = @{ b = 123L; t = 456L }
  Save-SizeCache
  Load-SizeCache   # 从磁盘重载（覆盖内存）验证 Save/Load 回环
  Assert-True ($cache.ContainsKey('test_key')) 'Save/Load 回环命中'
  Assert-True ($cache['test_key'].b -eq 123) '回环值正确'
  Clear-SizeCache
  Assert-True ($cache.Count -eq 0) 'Clear-SizeCache 原地清空'

  # ---- 10) CSV 报告 ----
  $report = Export-CleanReport -Mode 'Recycle' -Released 123 -Skipped 2 -Details @(@{ Name = 'a,b'; Category = 'sys'; Risk = 'green'; Size = 456; Released = 123; Skipped = 0; Failed = 0 }) -Note 'test'
  Assert-True ($null -ne $report) 'CSV 报告生成'
  if ($report) {
    $csvText = Get-Content -Raw -Encoding UTF8 $report
    Assert-True ($csvText -match '"a,b"') 'CSV 逗号字段转义'
    Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue
  }

  # ---- 11) 路径展开 ----
  $g = Get-ExpandedPaths (Join-Path $dir 'f*.txt')
  Assert-True ($g.Count -eq 5) ('通配符展开 5 项（实测 ' + $g.Count + '）')
  $ip = Get-ItemPaths -Item ([pscustomobject]@{ id = 't1'; paths = @((Join-Path $dir 'f*.txt')) })
  Assert-True ($ip.Count -eq 5) 'Get-ItemPaths 缓存展开'
  Assert-True ((Get-ItemPaths -Item ([pscustomobject]@{ id = 't1'; paths = @() })).Count -eq 5) 'Get-ItemPaths 命中缓存'

  # ---- 12) minAgeDays 过滤（测试目录最近修改 → 应被跳过） ----
  $future = (Get-Date).AddDays(-10)
  $newDir = Join-Path $td 'newdir'
  New-Item -ItemType Directory -Force -Path $newDir | Out-Null
  [IO.File]::WriteAllText((Join-Path $newDir 'x'), 'x')
  (Get-Item $newDir).LastWriteTime = $future  # 不能模拟"太新"→ 反向：用 Test-AgeEligible 直接验证
  $elig = Test-AgeEligible -Path $newDir -MinAgeDays 30
  Assert-True (-not $elig) 'minAgeDays=30 时 10 天旧目录不满足'
  $elig2 = Test-AgeEligible -Path $newDir -MinAgeDays 5
  Assert-True ($elig2) 'minAgeDays=5 时 10 天旧目录满足'
} finally {
  Remove-Item -LiteralPath $td -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ('== 结果: PASS=' + $script:Pass + '  FAIL=' + $script:Fail + '  SKIP=' + $script:Skip + ' ==')
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
