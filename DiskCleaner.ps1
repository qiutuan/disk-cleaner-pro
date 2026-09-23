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
