# DeepSeek Harness Desktop

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）打包成原生 macOS 应用：双击启动后自动拉起本地 `dsh web` 服务，并用原生窗口加载它的 Web UI。

![运行截图](docs/screenshot.png)

> ⚠️ **开发者预览**：`dsh` 本身处于 developer preview，接口可能发生破坏性变更。本项目只是它的桌面外壳。

## ✨ 特性

- **原生 macOS 应用**：Swift + AppKit + WKWebView，不是 Electron 壳。
- **一键启动**：双击图标 → 自动定位 Node → 拉起 `dsh web`（默认 `127.0.0.1:3080`）→ 窗口内加载。
- **优雅退出**：关闭窗口时自动向子进程发送 `SIGTERM`，让 dsh 干净收尾。
- **自定义图标**：鲸鱼剪影 + DeepSeek 蓝渐变，随源码一起生成。
- **内置运行时**：`@deepseek-ai/dsh` 及全部依赖被打进 `.app`，离线可用。

## 📋 环境要求

| 依赖 | 版本 | 说明 |
| --- | --- | --- |
| macOS | ≥ 12.0 | `LSMinimumSystemVersion` |
| Xcode Command Line Tools | 任意 | 提供 `swiftc` |
| Node.js | **≥ 20.12** | dsh 依赖 `util.parseEnv`，低版本会报 `SyntaxError` |

> 应用启动时会自动在 `/usr/local/bin`、`/opt/homebrew/bin` 等处探测可用的 Node，并校验版本 ≥ 20.12。

## 🚀 快速开始

### 方式一：直接构建并安装

```bash
git clone https://github.com/gchan2/deepseek-harness-desktop.git
cd deepseek-harness-desktop

# 构建 .app（首次会自动 npm install 拉取 dsh + 生成图标）
./build.sh --install
```

构建完成后应用会出现在「应用程序」（`/Applications/DeepSeekHarness.app`）。

### 方式二：只构建、不安装

```bash
./build.sh
# 产物：./DeepSeekHarness.app 和 ./dist/DeepSeekHarness.app
open ./DeepSeekHarness.app
```

## 🧱 工作原理

```
DeepSeekHarness.app
├─ 启动
├─ 探测 Node（≥ 20.12）
├─ spawn: node bin-wrapper.mjs web
│    └─ 动态 import @deepseek-ai/dsh/lib/bin.js（"web" profile）
├─ 轮询 127.0.0.1:3080 直到端口就绪
└─ WKWebView 加载 http://127.0.0.1:3080
```

退出时（关窗口 / ⌘Q）→ `SIGTERM` → dsh 触发自身 shutdown → 子进程结束。

## 🧩 目录结构

```
.
├── build.sh              # 一键构建脚本（自举：装依赖 → 编译 → 出图 → 打包 → 签名）
├── src/
│   ├── main.swift        # 原生壳：进程管理 + WKWebView + 菜单
│   └── makeicon.swift    # 用 CoreGraphics/NSBezierPath 绘制鲸鱼图标
├── dsh/
│   ├── package.json      # 声明 @deepseek-ai/dsh 依赖
│   └── bin-wrapper.mjs   # 信号安全启动器（见下方「技术细节」）
├── docs/screenshot.png   # README 截图
└── LICENSE
```

## 🔧 技术细节（踩坑记录）

1. **Node 版本门槛**：`@deepseek-ai/dsh-app-boot` 使用了 `import { parseEnv } from "node:util"`，这是 Node 20.12 才引入的 API。`main.swift` 里的 `findNode()` 会对候选 node 逐个执行 `-p process.versions.node` 并拒绝 `< 20.12` 的版本。

2. **`NODE_OPTIONS` 干扰**：GUI 父进程可能携带 `NODE_OPTIONS=--use-system-ca` 之类环境变量，这类 flag 在 Node 19+ 不允许通过 `NODE_OPTIONS` 注入，会导致子进程直接报错。启动器会显式 `removeValue(forKey: "NODE_OPTIONS")`（以及 `NODE_PATH`、`NODE_EXTRA_CA_CERTS`）。

3. **dsh 的 SIGINT 自杀行为**：`@deepseek-ai/dsh/lib/profile-boot-*.js` 注册了
   `process.on("SIGINT", () => interrupt(130))`——一旦子进程收到 SIGINT（终端/进程组残留信号），就会主动 `exit(130)`。`bin-wrapper.mjs` 通过 monkey-patch `process.on` / `process.addListener` 把 SIGINT / SIGHUP 的注册回调丢弃（只保留一个空监听器防止 Node 默认退出），但**保留 SIGTERM**，让 GUI 主动退出时 dsh 仍能干净清理。

## 📄 许可证

[MIT](LICENSE) © 2026 Gordon Chan (gchan2)

本项目打包并封装了 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（© DeepSeek AI，MIT 协议），其许可证与第三方声明以原仓库为准。
