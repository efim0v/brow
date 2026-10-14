[English](README.md) · [Русский](README.ru.md) · 简体中文

网站：[efimov.page/brow/zh-cn](https://efimov.page/brow/zh-cn/)

> 本文是[英文 README](README.md) 的译文。英文版可能比译文更新，两者不一致时以英文版为准。

# Brow：MacBook 刘海里的 Claude Code 用量限额

[![CI](https://github.com/efim0v/brow/actions/workflows/ci.yml/badge.svg)](https://github.com/efim0v/brow/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/efim0v/brow)](https://github.com/efim0v/brow/releases/latest)
[![License: GPL-3.0](https://img.shields.io/github/license/efim0v/brow)](LICENSE)
[![Platform: macOS 26+ · Apple silicon](https://img.shields.io/badge/platform-macOS%2026%2B%20%C2%B7%20Apple%20silicon-lightgrey)](#系统要求)

一款 macOS 应用，直接在 MacBook 刘海里显示**你所有 [Claude Code](https://claude.com/claude-code) 账号的用量和限额**：5 小时限额、每周限额，以及各自的重置时间。只需点一下，就能在专属于某个账号的浏览器配置文件中登录这个账号。

Brow 适合同时持有多个 Claude 订阅、在每个订阅上分别进行 AI 辅助工作的人。它让你一眼看出哪个账号快到限额、哪个还有余量、各自何时恢复。只有一个账号也能用：Brow 会自动找到 `~/.claude` 并显示该账号的限额。

**[下载 macOS 版 Brow](https://github.com/efim0v/brow/releases/latest/download/Brow.zip)** 或 `brew install --cask efim0v/tap/brow` · macOS 26 或更高版本，Apple 芯片 · [安装说明](#安装)

### 哪个账号还有余量

将指针悬停在刘海上，所有账号的 5 小时限额和每周限额就会从刘海中展开。复制某个账号的启动命令，Claude Code 就会以该账号的身份启动。

<p align="center"><picture>
  <source media="(prefers-reduced-motion: reduce)" srcset="docs/media/brow-hero-v1.png">
  <source type="image/webp" srcset="docs/media/brow-hero-v1.webp">
  <img src="docs/media/brow-hero-v1.png" width="840" alt="悬停在刘海上会展开所有账号的限额；复制还有余量的账号的启动命令后，Claude Code 以该账号的身份启动">
</picture></p>

### 每个限额何时重置

日历上标出了每个账号的每周重置日和订阅续费日。把指针移到某一天上，就能看到那天有哪些额度会恢复。

<p align="center"><picture>
  <source media="(prefers-reduced-motion: reduce)" srcset="docs/media/brow-calendar-v1.png">
  <source type="image/webp" srcset="docs/media/brow-calendar-v1.webp">
  <img src="docs/media/brow-calendar-v1.png" width="840" alt="重置日历：指向某一天，即可看到哪个账号的每周限额在这天重置，或哪个订阅在这天续费">
</picture></p>

### 一键重新登录

某个账号的登录过期后，点击它旁边的钥匙，就会为该账号运行 `claude auth login`，并打开属于它的浏览器配置文件，其中已经登录了这个账号。其他账号的登录状态不受影响。

<p align="center"><picture>
  <source media="(prefers-reduced-motion: reduce)" srcset="docs/media/brow-signin-v1.png">
  <source type="image/webp" srcset="docs/media/brow-signin-v1.webp">
  <img src="docs/media/brow-signin-v1.png" width="840" alt="登录过期：点一下钥匙，就会打开该账号专属且已登录的浏览器配置文件，Claude Code 随即重新登录">
</picture></p>

所有演示均使用虚构数据。

> **配套应用：[Grove](https://github.com/efim0v/grove)**。Grove 为多仓库项目中的每个功能单独创建供 Claude Code 使用的工作区，还能把会话从一个账号转移到另一个账号。Brow 告诉你哪个账号还有余量，Grove 把工作挪过去。两者都能单独运行，同时也是为配合使用而设计的。

## 功能

- **所有账号一目了然**：每个账号显示 5 小时限额、每周限额，以及特定模型的每周限额（如有），均以已用百分比表示，并附上距离各自重置还剩多久。
- **重置日历**：在月历上标出每周重置日和预计的订阅续费日，哪个账号什么时候恢复，一看便知。
- **复制启动命令**：一个按钮即可复制以该账号身份启动 Claude Code 的命令。
- **在账号自己的浏览器里重新登录**：每个账号都有独立的浏览器配置文件，Cookie、历史记录和已保存的登录信息互不相通，登录一个账号绝不会影响另一个。第二个按钮可以直接打开这个配置文件。
- **一键添加账号**：Brow 会创建账号文件夹，并打开 Anthropic 自己的登录流程。
- **令牌保持有效**：空闲账号的令牌会在后台刷新，所以数字不会过时。

独立的浏览器配置文件需要 Google Chrome、Chromium、Brave 或 Edge。如果都没有，链接会在默认浏览器中打开，不做隔离。关于请求节奏、刷新和布局选项的更多细节，见 [`docs/brow.md`](docs/brow.md)（英文）。

<p align="center">
  <img alt="Brow 设置：账号" src="docs/screenshots/brow-settings-accounts.png" width="420" />
</p>

收起时，Brow 在刘海两侧显示两个数字：你的所有账号总体上用掉了多少 5 小时限额和每周限额。指针悬停时，它会展开成上面演示中的面板。这两个读数也可以放到刘海下方的横条里：

<p align="center">
  <img alt="刘海下方的读数" src="docs/screenshots/brow-notch-collapsed-below.png" width="640" />
</p>

## Brow 会在你的 Mac 上做什么

运行之前，值得了解这些：

- **Brow 从 macOS 钥匙串读取 Claude Code 的登录令牌**，只用它调用 Anthropic 的用量（usage）和个人资料（profile）接口。这些接口并非有公开文档的 API，可能会发生变化。令牌不会写入磁盘，也不会记入日志，任何数据都不会发往别处。如果 macOS 不让 Brow 读取某个账号的令牌，该账号旁会显示一把钥匙；点击它，Brow 会向 macOS 申请访问权限。
- **备用令牌刷新默认开启**。如果常规刷新失效，Brow 会运行一个很小的 `claude -p` 请求，这会消耗少量限额，并开启该账号的 5 小时窗口。可在 Settings → Accounts 中关闭；它具体何时运行，见[常见问题](#brow-会消耗我的限额吗)。
- **每个账号的浏览器配置文件都是一个单独的目录**，位于 `~/Library/Application Support/Brow/browser-profiles/` 下。Brow 会设置配置文件的名称，并在其中允许第三方 Cookie，以便登录正常进行。
- **登录时会打开“终端”**，在其中运行 `claude auth login`；macOS 会询问一次是否允许 Brow 控制“终端”。

这是一个独立工具，与 Anthropic 没有关联，也未获 Anthropic 认可。

## 系统要求

- macOS 26 或更高版本；预编译版本仅支持 Apple 芯片。刘海布局为带刘海的 MacBook 设计；在其他显示器上，Brow 显示为一个胶囊。
- 构建需要带 Swift 6.2 的 Xcode。
- [Claude Code](https://claude.com/claude-code)。
- 独立的浏览器配置文件需要 Chrome、Chromium、Brave 或 Edge。

## 安装

```sh
brew install --cask efim0v/tap/brow
```

也可以从[最新版本](https://github.com/efim0v/brow/releases/latest)下载 **[Brow.zip](https://github.com/efim0v/brow/releases/latest/download/Brow.zip)**，解压后把 `Brow.app` 移到 `/Applications`。

该构建使用 ad hoc 签名，未经 Apple 公证，所以无论用哪种方式安装，macOS 都会拦下首次启动。打开**系统设置 → 隐私与安全性**，找到关于 Brow 的提示，点击**仍要打开**；也可以自己清除隔离属性：

```sh
xattr -dr com.apple.quarantine /Applications/Brow.app
```

如果 macOS 不让 Brow 读取某个账号的钥匙串项目，该账号会显示一把橙色钥匙，Settings → Accounts 中会把它的令牌标为 *Keychain access needed*：点击钥匙，或点击那里的 **Grant Keychain access**，然后选择**始终允许**。由于构建使用 ad hoc 签名，更新到新版本后，钥匙可能会再次出现。

发布附带的 `SHA256SUMS.txt` 可用来校验下载：把两个文件放在同一个文件夹里，运行 `shasum -a 256 -c SHA256SUMS.txt`。

Brow 没有程序坞图标：它待在刘海里，设置从面板上的 ⚙ 打开。在 Settings → General 中开启 **Launch at login**，即可在登录时自动启动 Brow。

## 常见问题

### Brow 会消耗我的限额吗？

只有备用令牌刷新会消耗，而且可以关闭。读取限额是向 Anthropic 的用量接口发请求，而不是调用模型；空闲账号的令牌通过 `claude doctor` 保持有效，它也不会调用模型。

备用刷新默认开启。当某个账号的令牌剩余有效期不超过 30 分钟，而 `claude doctor` 没能续期时，Brow 会在该账号中用 Haiku 运行一次单轮 `claude -p` 请求。这会消耗该账号极少的限额，并开启它的 5 小时窗口。如果 Anthropic 已拒绝该令牌，或者 `claude doctor` 超时或无法启动，Brow 不会发出这个请求。对每个账号，它最多每 30 分钟运行一次；连续三次尝试都没有效果后，Brow 就不再对该账号使用这个办法。在 Settings → Accounts → **Allow `claude -p` fallback** 中可以将其关闭。

### Brow 从哪里读取令牌？会有数据离开我的 Mac 吗？

从 Claude Code 为每个账号保存的钥匙串项目中读取：`~/.claude` 对应 `Claude Code-credentials`，其他账号文件夹对应 `Claude Code-credentials-<hash>`。Brow 用 macOS 的 `security` 工具读取，不行时回退到钥匙串 API；对于较旧版本的 Claude Code，则改为读取账号文件夹中的 `.credentials.json`。它只使用访问令牌，续期交给 Claude Code 自己处理。

Brow 自己的网络请求只发往两个 Anthropic 接口，不会发往别处：`api.anthropic.com/api/oauth/usage` 用于获取用量数字；`api.anthropic.com/api/oauth/profile` 每个账号大约每天请求一次，用于估算日历中的续费日期。Brow 没有任何统计分析，也不检查更新。它运行的 `claude` 命令会建立 Claude Code 平常就会建立的连接，各账号的浏览器配置文件会打开 claude.ai。

### Brow 支持哪些 Mac？显示在哪里？

macOS 26 或更高版本；预编译版本仅支持 Apple 芯片。Brow 位于主显示器顶部。如果主显示器有刘海，两个读数会显示在刘海两侧（默认），或者显示在刘海下方的横条里：Settings → General → **Ears**。在同一标签页中关闭 **Show readouts next to the notch** 后，指针移到刘海之前不会绘制任何内容。如果主显示器没有刘海（例如外接显示器），Brow 会改为在屏幕顶部中央显示一个胶囊。

## 卸载

1. 如果开启过 **Launch at login**，先在 Settings → General 中关闭它。然后在 Brow 的设置窗口位于最前面时按 ⌘Q 退出 Brow。
2. 删除应用：运行 `brew uninstall --cask efim0v/tap/brow`，或者把 `Brow.app` 从 `/Applications` 移到废纸篓。
3. 关闭 Brow 为各账号打开的浏览器窗口，然后删除 Brow 的文件：它的设置、缓存的读数、各账号的浏览器配置文件（包括其中的 Cookie 和已保存的密码）、它放在 Grove 文件夹里的请求节奏文件，以及 macOS 为它的网络请求保存的数据：

   ```sh
   rm -rf ~/Library/Application\ Support/Brow
   rm -f ~/Library/Application\ Support/Grove/oauth-usage-ledger.json
   rm -rf ~/Library/Caches/dev.artemefimov.brow ~/Library/HTTPStorages/dev.artemefimov.brow
   ```

4. 如果你把 Brow 的 `export BROWSER=…` 这一行加进了 `~/.zshrc`，请删除它。

如果你先删除了应用，而 Brow 仍然出现在“系统设置 → 通用 → 登录项与扩展”中，请在那里将它移除。`~/.claude-accounts` 下的账号文件夹属于 Claude Code，没有 Brow 也能照常使用。

## Brow 与 Grove 如何配合

Claude Code 把每个账号放在各自的目录中：默认账号是 `~/.claude`，其他账号是 `~/.claude-accounts/<name>`。两个应用都读取这些目录，彼此之间不直接通信。

- **账号**：Brow 在你登录时创建账号文件夹；Grove 会识别这些文件夹，并能以其中任意一个账号启动任意会话。
- **浏览器路由**：Brow 附带一个小脚本，负责在对应账号的浏览器配置文件中打开链接。安装了 Brow 时，Grove 会把这个脚本传给它启动的每个 Claude Code 会话，这样会话发起的登录就会进入正确的配置文件。
- **共享代码**：账号、凭据和用量相关的逻辑位于 Grove 的 `GroveCore` 库中，本包依赖这个库。

完整说明（包括会话如何在账号之间共享）见 [Grove 的 README](https://github.com/efim0v/grove#how-grove-and-brow-fit-together) 和 [`docs/grove-and-brow.md`](docs/grove-and-brow.md)（均为英文）。

<p align="center">
  <a href="https://github.com/efim0v/grove"><img alt="Grove：多仓库项目的工作区" src="https://raw.githubusercontent.com/efim0v/grove/main/docs/screenshots/grove-workspaces.png" width="420" /></a>
</p>

## 构建

```sh
git clone https://github.com/efim0v/brow.git
cd brow

swift test                 # fetches GroveCore from the Grove repository
Scripts/build-brow.sh      # -> dist/Brow.app
cp -R dist/Brow.app /Applications/
```

应用默认使用 ad hoc 签名，这样每次重新构建后，macOS 都会忘记钥匙串和自动化权限。如果想保留这些权限，请在构建前把 `GROVE_SIGN_IDENTITY` 设为你自己的 `Apple Development: Name (TEAMID)` 签名身份。

## 目录结构

| 路径 | 内容 |
|---|---|
| `Sources/BrowKit` | 应用本体：刘海面板及其几何计算、限额存储、视图、设置 |
| `Sources/BrowApp` | 程序入口 |
| `Resources/brow-browser.sh` | 按账号分流的浏览器路由脚本 |
| `Tests/BrowKitTests` | 约 150 个测试 |
| `docs` | [Brow 详解](docs/brow.md)、[Brow 与 Grove 如何配合](docs/grove-and-brow.md)（英文） |

唯一的依赖是 Grove 仓库中的 [`GroveCore`](https://github.com/efim0v/grove)。

## 开发

- 本 README 中的截图可用以下命令重新生成：
  `DEMO_SCREENSHOTS_DIR="$PWD/docs/screenshots" swift test --filter DemoScreenshotTests`。
- 刘海轮廓的调校常量位于 `Sources/BrowKit/Panel/NotchGeometry.swift`，需要对照实际的屏幕边框凭肉眼调整。

## 许可证

[GNU GPL v3](LICENSE)。0.2.0 及更早的版本以 MIT 许可证发布。
