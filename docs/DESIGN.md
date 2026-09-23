# DiskCleanerPro 项目设计要点

> 用途：项目设计文档。上下文丢失时据此恢复。简要记录，勿扩充。

## 目标
C 盘智能清理工具：通用、智能、安全、橙色系 WinForms 界面，可勾选清理内容，
覆盖常用软件 + 开发工具缓存，内置多重安全保护。替代反复手动清理。

## 技术栈（已实测验证）
- PowerShell 7.6.6（优先）+ Windows PowerShell 5.1（兜底），均可用 WinForms
- UI = System.Windows.Forms（纯代码绘制，无图片资源）
- 删除回收站 = Microsoft.VisualBasic.FileIO.FileSystem::DeleteDirectory/DeleteFile + SendToRecycleBin
- 永久删除 = [IO.Directory]::Delete($p,$true)
- 启动 = .bat 双击（纯 ASCII 内容，中文全在 ps1），`pwsh -STA -ExecutionPolicy Bypass -File DiskCleaner.ps1`
- ps1 保存为 UTF-8 带 BOM（PS5.1/7 中文都正确）
- 管理员权限已具备（当前会话已是管理员）

## 关键决策（用户拍板）
| 决策 | 结论 |
|---|---|
| 界面 | WinForms 原生窗口，橙色系主题 |
| 删除模式 | 默认移到回收站（可恢复），可切永久删除 |
| 安装位置 | G:\work\myOuther\clear |
| 高风险项 | 全部显示，但默认不勾选，用户自由勾 |
| 一键清理 | 有"一键清理安全项"按钮（自动勾选绿+黄） |
| 附加功能 | 大文件分析 / 软件占用 / 重复文件 / 还原点 / 启动项 |
| 自动清理 | 手动触发，不做定时任务 |
| 运行时文件 | G:\work\myOuther\clear\runtime\（settings.json / size-cache.json / logs\）——全部写入仅限 clear 目录内 |

## 文件结构
```
G:\work\myOuther\clear\
├── 启动清理工具.bat       # 双击启动（ASCII）
├── DiskCleaner.ps1        # 主程序：内嵌默认清理项 + 扫描/删除引擎 + UI
├── config\cleanup-items.json   # 可选用户扩展项（存在则与内嵌合并覆盖）
├── runtime\               # 运行时数据（gitignore）：settings.json / size-cache.json / logs\
├── docs\                  # 本文档 + 偏好 + 进度
├── testdata\              # 自测临时数据（gitignore，用完删）
├── README.md / LICENSE / .gitignore
```

## 写入边界（用户硬性约束，不可违反）
**所有写入/修改只允许在 G:\work\myOuther\clear\ 内**；其余文件系统只读。
→ 运行时数据（settings/size-cache/日志/自测数据）一律放 clear 内，绝不写 %LOCALAPPDATA% 等。

## 数据模型（categories.json）
字段：id / category(system|browser|dev|app) / name / desc / paths[](支持%VAR%+通配符) /
exclude[] / risk / defaultChecked / method(delete-dir|delete-file|exec) / pattern /
execCommand / execTimeoutSec / admin / detect(path-exists|registry-key|command-exists)

风险等级：
- green 绝对安全 → defaultChecked=true，无确认
- yellow 谨慎（删后重下载）→ 默认不勾，勾选提示
- red 需确认 → 默认不勾，勾选弹确认

## 安全机制（底线，不可删减）
1. 白名单闸门 Test-Whitelist：静态（盘根/WINDIR/System32/WinSxS/UserProfile/ProgramFiles/
   ProgramData/$Recycle.Bin/pagefile/hiberfil…）+ 动态（工具自身目录/进程路径），双向祖先检查，
   命中 → 记日志跳过，绝不执行删除
2. 默认回收站；目录整体回收失败(占用) → Recycle-DirGracefully 逐文件回收，占用自动跳过
3. 全局异常兜底：UnhandledException + ThreadException → 记日志 + 友好提示，不闪退
4. 扫描跳过 ReparsePoint（防 Junction 死循环）；逐目录 try/catch 降级

## 扫描引擎
- RunspacePool 后台（worker=ProcessorCount），结果入 ConcurrentDictionary
- UI 用 Timer(500ms) 轮询增量刷新；可取消，保留已得结果
- Measure-DirBytes：EnumerateFiles 只读元数据，逐目录 try/catch，跳过 ReparsePoint
- size-cache.json 缓存（LastWriteTime 未变直接读缓存）；"立即重新扫描"强制全量

## 界面布局
顶部横幅(C盘进度+重新扫描) | 左侧 Tab 导航(缓存清理/大文件/软件占用/重复文件/还原点/启动项)
| 中间勾选 ListView(按 category 分组,风险着色) | 右侧说明区 | 底部操作条(合计+全选/全不选/
一键清理安全项+删除模式+开始清理) | 日志面板
色板：背景#FFF3E0 横幅#E65100 主按钮#F57C00 次级#FB8C00 绿#43A047 黄#F9A825 红#E53935 文字#3E2723

## 参考项目（已调研）
orzcls/win-disk-cleaner（模块化路径+DryRun）、riffpointer/DiskyCleaner（数据驱动目标列表+
Get-FolderSize+CheckedListBox+回收站/永久模式，技术主参考）、CCleaner/Wise（风险分级）、
BleachBit（多规则+预览）、WizTree/dupeGuru（大文件/重复文件）

## Git 约定
- 仓库：qiutuan/disk-cleaner-pro，私有，MIT License，README 中文
- token：GitHub PAT 存 Windows 凭据管理器（git credential approve），绝不落盘/不提交/不写 .git/config
- 提交：英文 message + 原子提交，7 个里程碑 + v1.0.0 tag，每节点 push
  1 chore: skeleton  2 feat: categories  3 feat: scan  4 feat: delete
  5 feat: UI  6 feat: panels  7 docs: README + v1.0.0 tag
