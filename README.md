# DiskCleanerPro — C 盘智能清理工具

一款**通用、智能、安全**的 Windows 磁盘清理工具（PowerShell + WinForms，橙色系界面）。
按分类勾选清理内容，覆盖系统缓存、浏览器缓存、开发工具缓存与常用软件缓存，
内置多重安全保护：默认移入回收站、被占用文件自动跳过、关键路径白名单、风险分级。

## 特性

- 橙色系 WinForms 图形界面，无需图片资源，纯代码绘制
- 清理项按 系统 / 浏览器 / 开发工具 / 常用软件 分组，勾选自由
- 风险三级（绿=绝对安全 / 黄=谨慎 / 红=需确认），高风险默认不勾选
- 默认移到回收站（可恢复），可切换永久删除
- 硬编码白名单（System32、盘根等）双向往返检查，受保护路径绝对不删
- 自动检测：只显示机器上实际存在的清理项
- 扫描后台多线程，目录大小缓存，二次扫描秒级
- 附加工具：大文件分析 / 软件占用 / 重复文件检测 / 系统还原点 / 启动项
- 每次清理写入日志，可追溯

## 使用方法

双击 `启动清理工具.bat`（自动以管理员 + STA 模式运行）→ 扫描 → 勾选 → 开始清理。

- 删除模式默认"移到回收站"，误删可从回收站还原
- 不确定的项目选绿色（绝对安全）即可
- 开发工具缓存、微信/QQ 数据默认不勾选（删除后需重新下载/可能含个人数据）

## 扩展：添加自定义清理项

编辑 `config\cleanup-items.json`，按以下字段添加即可：

```json
{
  "id": "app_mytool",
  "category": "app",
  "name": "某软件缓存",
  "paths": ["%LOCALAPPDATA%\\MyTool\\Cache"],
  "risk": "green",
  "defaultChecked": true,
  "method": "delete-dir"
}
```

字段说明：

- `id` 唯一标识；`category` 分组（system/browser/dev/app）；`name`/`desc` 显示文本
- `paths` 目标路径数组，支持 `%VAR%` 环境变量和 `*?` 通配符
- `risk` 风险级：green（绝对安全）/ yellow（谨慎）/ red（需确认）
- `defaultChecked` 默认是否勾选
- `method` 处理方式：delete-dir（删目录内容保留根）/ delete-file（按通配符删文件）/
  exec（执行 `execCommand` 命令）
- `detect` 自动检测（可选）：`{"type":"path-exists","value":["路径"]}` 或
  `{"type":"command-exists","value":["docker"]}`，不满足则该项不显示

## 目录结构

```
├── 启动清理工具.bat       # 双击启动
├── DiskCleaner.ps1        # 主程序
├── config\cleanup-items.json  # 自定义清理项
└── runtime\               # 运行时数据（设置/扫描缓存/日志，不入库）
```

## 许可

[MIT](LICENSE)

> 安全声明：本工具仅按白名单与配置清理可再生成缓存/临时文件；对关键系统路径做了硬保护。
> 请在使用前备份重要数据，并优先使用回收站模式。
