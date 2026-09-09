# DeepSeek Harness 启动器 (dsh-launcher)

Windows 桌面启动器，用于检测、启动、重启、升级和自动安装 [DeepSeek Harness](https://www.deepseek.com/harness/) (dsh)。纯 PowerShell + WinForms 实现，绿色免安装，无额外运行时依赖（除 Node.js）。

## 界面预览

![启动器界面](docs/screenshot.png)

## 功能特性

- **一键启动**：在独立窗口启动 dsh web 服务
- **一键重启**：先停止正在运行的 dsh，再重新启动（三层停止机制，保证端口释放、无残留进程）
- **一键升级**：显式版本 + `--prefer-online` + 安装后版本校验，避免 npm 缓存导致的"假升级"
- **自动安装**：未检测到 dsh 时自动提示，并通过 `npm install -g` 安装
- **环境自检**：启动时自动检测 Node.js / dsh / npm 最新版本；Node 版本不满足要求时给出明确提示
- **实时日志**：安装 / 升级 / 启动过程输出实时显示（已过滤 stderr 噪音）

## 环境要求

| 依赖 | 要求 | 说明 |
| --- | --- | --- |
| Windows | 10 / 11 | 需 PowerShell 5.1（系统自带） |
| Node.js | ≥ v22.19 | DeepSeek Harness 的硬性要求 |
| dsh | 最新版 | npm 全局包 `@deepseek-ai/dsh` |

## 安装与使用

1. 将 `DSHLauncher.ps1` 放到任意目录（例如 `D:\tools\dsh-launcher`）；
2. 创建桌面快捷方式，目标指向（注意脚本路径换成你的实际路径）：

   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "D:\tools\dsh-launcher\DSHLauncher.ps1"
   ```

3. 双击快捷方式即可打开启动器界面。

> 提示：脚本文件必须保持 **UTF-8 with BOM** 编码——Windows PowerShell 5.1 会按 ANSI 解析无 BOM 文件，导致中文乱码和语法错误。

## 按钮说明

| 按钮 | 功能 |
| --- | --- |
| 启动 DSH | 启动 dsh web；未安装时自动提示并安装 |
| 重启 DSH | 停止当前 dsh 后重新启动 |
| 升级 DSH | 升级到 npm 最新版本，完成后校验版本 |
| 退出 | 关闭启动器（不影响已启动的 dsh） |

## 工作原理

- **启动**：通过 `powershell -EncodedCommand` 在独立窗口运行 dsh web，窗口标题设为 `dsh web (DSH Launcher)`，并记录窗口进程 PID 到 `dsh.pid`（已 gitignore）；
- **停止（三层保障）**：
  1. 按唯一窗口标题发送窗口关闭消息（等同点击窗口 X，dsh 可优雅退出）；
  2. 若未退出，`taskkill /T /F` 结束进程树；
  3. 按命令行特征 `@deepseek-ai\dsh` 清扫残留 node 进程，确保端口 3080 释放；
- **升级**：读取 npm 最新版本 → 显式指定 `@deepseek-ai/dsh@<版本>` + `--prefer-online` 安装 → 重新探测环境并校验实际版本；若版本未变化，明确提示"npm 镜像缓存延迟"而非误报成功。

## 项目结构

```
dsh-launcher/
├── DSHLauncher.ps1   # 启动器主脚本（GUI）
├── .gitignore        # 忽略运行时状态文件
└── README.md         # 项目说明
```

## 常见问题

### 升级显示成功但版本没变？
npm 镜像（如 npmmirror）缓存可能导致 `@latest` 解析到旧版本。脚本已内置 `--prefer-online` + 显式版本 + 安装后校验，出现该情况会提示"镜像缓存延迟"，稍后重试即可。

### 启动时报 Node.js 版本过低？
DeepSeek Harness 要求 Node.js ≥ v22.19，请升级 Node.js 后重试。

### 脚本中文乱码？
脚本文件必须为 UTF-8 with BOM 编码，否则 Windows PowerShell 5.1 解析会出现乱码导致语法错误。

### 直接运行 .ps1 被阻止？
执行策略限制所致：使用快捷方式（已带 `-ExecutionPolicy Bypass`），或执行 `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`。

## 许可证

[MIT](LICENSE)
