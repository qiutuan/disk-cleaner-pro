# 实施进度

> 每完成一步勾选并记录。提交号对应 Git 里程碑。

- [x] 方案讨论与获批（3 轮 AskUserQuestion + 计划文件）
- [x] 步骤0 Git 初始化（git init + 建仓 + token 存储 + README + 提交1 skeleton）
- [x] 步骤1 安装目录 + .bat 启动器 + ps1 骨架（UTF-8 BOM）
- [ ] 步骤2 categories.json 数据模型（真实路径）→ 提交2
- [ ] 步骤3 核心引擎（扫描 + 白名单 + 删除）→ 提交3/4
- [ ] 步骤4 WinForms 橙色主界面 → 提交5
- [ ] 步骤5 附加功能 Tab（大文件/软件占用/重复文件/还原点/启动项）→ 提交6
- [ ] 步骤6 自测 + README 完善 + v1.0.0 tag → 提交7
      ⚠️ 自测约束：不允许删除真实文件；真实文件只做扫描预览(DryRun)；
      删除逻辑验证仅在 clear\testdata\ 内自建数据上做

## Git 记录
- 提交1 `chore: project skeleton (launcher + scaffold)` → 已 push origin/main
- 仓库：https://github.com/qiutuan/disk-cleaner-pro （私有）

## 待办 / 风险
- Explore 后台代理扫描真实缓存目录的结果未收到（会补充 categories.json 路径）
- 还原点：本机 vssadmin 退出码 1 → 界面需"不可用"降级分支
