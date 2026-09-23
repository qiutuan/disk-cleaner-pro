# 用户偏好与硬性约束（不可违反）

> 上下文丢失时必须恢复这些。用户不想重复交代。

## 硬性约束
1. **全程不允许任何图片**：不截图、不生图、不引用图片资源，UI 纯代码绘制
2. **程序/系统绝不崩溃**：任何删除操作独立 try/catch，失败自动跳过，全局异常兜底
3. **被占用文件自动跳过**（Windows 机制保证），物理上不可能破坏运行中程序
4. **手动触发**，不做任何定时任务/开机自启
5. **写入边界（最重要）**：所有执行只允许在 G:\work\myOuther\clear\ 内写/改，
   其余文件系统一律只读（包括 %LOCALAPPDATA%、Temp、memory 等）——运行时数据、日志、自测全在 clear 内

## 清理偏好（重要）
- **开发包缓存默认不删**：npm/yarn/pnpm/uv/pip/go-build/.m2/.gradle/.nuget/.cargo 等
  → 清理项里默认不勾选（删了要重新下载）
- **微信/QQ 数据默认不删**：聊天记录/缓存/备份等全部默认不勾
- Docker 镜像可清理（用户允许，不影响服务前提下）
- 用户上一轮已手动删除+迁移过一轮（Temp、JVM hprof、CrashDumps、go-build、
  系统更新缓存、Visio 安装包、Docker 无用镜像；迁移 Docker vhdx + 微信数据到 G:\Migrated）

## 协作方式
- 用户对清理软件不熟悉，其意见仅参考 → 需结合市面软件综合分析，主动给出推荐
- 先给方案讨论满意再执行（本项目已获批）
- 关键要点记录到 docs\ 下 md，简要记录

## 环境事实
- 系统：Windows 11 Pro for Workstations，C 盘 246GB，D 盘存在，G 盘 146GB 空闲
- 已装：Edge、Chrome、Firefox(?)、微信、QQ、uTools、JetBrains(PyCharm/IDEA)、VS Code、
  Docker Desktop、WSL、winget 等（具体以注册表扫描为准）
- 管理员权限已具备
- GitHub 账号：qiutuan
