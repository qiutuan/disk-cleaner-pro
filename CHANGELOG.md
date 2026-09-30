# Changelog

本项目按"每笔提交一个主题"维护变更记录。日期为本地提交时间（+08:00）。

## v1.4.0（2026-09-24 ~ 2026-09-30）

> 发布于 2026-09-30。发行包：`disk-cleaner-pro-v1.4.0.zip`（git archive 构建，15 个文件）。
> Windows 专属功能（WPF 窗口/回收站/内存/还原点/启动项）需在 Windows 11 真机回归，
> 本版本在 Linux 上以 Parser 校验 + 35 项引擎单元测试验证。

性能与架构重构 + 稳定性/可用性打磨。引擎从单文件拆为可测试模块，worker 机制重写。

### 架构
- 引擎模块化：扫描/删除/白名单/配置/缓存/附加功能引擎全部移入 `Engine.psm1`（48 个导出函数），UI 壳 `DiskCleaner.ps1` 保留纯界面与页面逻辑
- WorkerBridge 重写：runspace 懒创建 + `Import-Module`，替代旧的"整文件源码注入"（每 worker 初始化从千行级解析降为一次模块解析）
- 新增 `Tests/Engine.Tests.ps1` 引擎单元测试（35 项，可在 Linux pwsh 下运行）；GitHub Actions 在 push/PR 时自动跑解析检查与单元测试

### 性能
- 指纹/大小读取改用 .NET 静态 API，路径展开单次缓存（`Get-ItemStamp`/`Get-ItemSize`）
- 永久删除模式跳过删除前的全量预测量（计划值=实际释放值）
- 日志改为内存缓冲批量写盘，窗口关闭/worker 结束/自测退出时落盘；日志框 500 行上限
- 空间分析页下钻使用"父目录→直接子级"索引（O(全盘目录数) → O(子项数)），删除后自动重建
- 大文件 / 空文件夹 / 重复文件页结果超过 3000 行时截断并提示，防止超大列表拖垮渲染

### 稳定性与安全
- 共享缓存修复：`Load-SizeCache`/`Clear-SizeCache` 原地 `.Clear()`，根治 worker runspace 持有旧引用导致的孤儿化
- 删除白名单加固：新增 `ForbiddenSubtrees`（Windows\Boot、System32\config、WindowsApps、Package Cache 等）；exec 命令首 token 与 exec-process 进程名白名单（dism/docker/taskkill/reg/cleanmgr/sfc/wevtutil）
- 配置/尺寸缓存损坏时自动备份到 `runtime\backups` 并回退默认，不再导致启动失败
- 扫描/清理/空间 worker 增加引擎级异常兜底，未捕获异常以 `Result.Error` 带回日志
- 目录聚合与路径展开兼容 `/` 与 `\`；StrictMode 下 ConcurrentDictionary 枚举修复

### Bug 修复
- 重复文件页"浏览"按钮在 Windows PowerShell 5.1 下不可用（`OpenFolderDialog` 仅 PS7）→ 改用 Win32 `SHBrowseForFolder` 选择器
- `ConfigWarning` 初值由空串改为 `$null`；配置加载警告经 worker 结果带回并在日志面板展示

### 用户体验
- 清理页新增实时搜索过滤（按名称/分类）
- 清理页行 ToolTip 显示完整展开路径；空间页行 ToolTip 显示完整目录路径
- 清理页勾选状态持久化到 `runtime\settings.json`（下次启动恢复；已清理项自动移除）
- 单实例互斥：重复启动提示并退出；窗口关闭时回收全部 worker runspace 与后台线程
- 永久删除要求输入「确认删除」二次确认（输入框不可用时回退确认框）
- 清理页快捷键：F5 重新扫描、Ctrl+Enter 开始清理
- 大文件/空文件夹页友好空态提示；公共按钮文案集中到 UI 资源字典（便于统一调整与未来多语言）

### 已知限制（未实施）
- 深色主题（U7）：9 个页面为纯代码构造且大量硬编码浅色，需在 Windows 实机上逐步替换为主题引用，本轮未做
- XAML 定义的按钮文案未接入资源字典（后续阶段可做）
- Windows 专属功能（WPF 窗口、回收站、内存释放、还原点、启动项注册表）无法在 Linux CI 实跑，需 Windows 真机回归
