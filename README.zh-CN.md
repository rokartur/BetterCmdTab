<div align="center">

<img width="128" height="128" alt="AppIcon-macOS-Dark-256x256@1x" src="https://github.com/user-attachments/assets/3e4bbb67-ef7d-4619-8068-1458d8460331" />

# BetterCmdTab

The Cmd+Tab macOS deserves.

<p>
  <a href="https://github.com/rokartur/BetterCmdTab/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/rokartur/BetterCmdTab?include_prereleases&style=for-the-badge&label=release&color=white"></a>
  <a href="https://github.com/rokartur/BetterCmdTab/releases/latest"><img alt="最新版本" src="https://img.shields.io/badge/Download_Latest_Release-F5F5F4?style=for-the-badge&logo=apple&logoColor=black"></a>
  <a href="https://github.com/rokartur/BetterCmdTab/releases"><img alt="下载量" src="https://img.shields.io/github/downloads/rokartur/BetterCmdTab/total?style=for-the-badge&color=white"></a>
</p>

<sub>
  <a href="#install">安装</a> ·
  <a href="#features">功能</a> ·
  <a href="#build-from-source">构建</a> ·
  <a href="#contributing">贡献</a>
</sub>

<p><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a></p>

</div>

<a id="features"></a>

## 功能

### 切换与导航

- **三种布局** — 经典列表、图标网格或实时窗口预览。
- **字母前缀跳转** — 输入名称即可跳转到对应项目。
- **搜索与启动** — 按 `/`（可重新绑定）进行模糊搜索，或启动任意已安装的 App。
- **窗口切换** — `` ⌘+ ` `` 可循环切换当前 App 的窗口。
- **轻点或按住** — 轻点即可立即切换，按住则打开切换器。
- **滚动切换** — 滚动鼠标滚轮即可在 App 之间移动。
- **多显示器** — 在你当前正在使用的显示器上打开。
- **保持打开** — 可选择在松开 ⌘ 后让切换器继续显示：按自己的节奏浏览，用 Return 或单击确认，用 Esc 关闭。
- **反向移动** — 按住 Shift 可继续在列表中反向移动（也可关闭轻点 Shift 反向功能）。
- **仅键盘操作** — 可关闭鼠标悬停选择和鼠标单击选择。

### 窗口与标签页管理

- **窗口标题** — 在网格和预览中，将每个窗口的标题显示在图标下方。
- **深入标签页** — 在窗口含有标签页的行上按 `\`（可重新绑定），即可选择特定标签页（Safari、Chrome、Arc、Brave、Edge、Vivaldi、Opera、Dia、Finder、Terminal、iTerm）。
- **将标签页显示为行** — 可将每个原生或浏览器标签页直接显示为独立行，而不只是藏在 `\` 预览中；还提供标签页最近使用顺序，并在 Safari/Chrome 需要自动化权限时给出明确提示。
- **快捷操作** — 可直接退出、关闭、最小化、最大化或隐藏。
- **悬停操作** — 悬停时显示快捷操作按钮：关闭、最小化、缩放、隐藏、退出、强制退出。
- **窗口管理** — 使用 `⌃⌘` 加方向键将窗口平铺到半屏或角落、最大化或居中；再次按平铺键可在 ½ → ⅔ → ⅓ 宽度之间循环。
- **移动窗口** — 将高亮窗口移到下一个显示器。

### 筛选与整理

- **排序方式** — 按最近使用（MRU）、字母顺序或启动顺序排列 App；也可按最近使用的窗口排序，将所有 App 的窗口按照你上次使用的时间混合排列。
- **限定范围的快捷键** — 可添加任意数量的全局快捷键，每个快捷键都能打开预先筛选的切换器（所有窗口、当前 Space、可见 Spaces、当前 App 的窗口或仅最小化窗口），并各自拥有独立于全局设置的布局、排序、筛选器和颜色。
- **窗口来源** — 所有 Spaces、仅当前 Space，或**可见 Spaces**；专为多显示器设计：列出所有显示器上当前可见的内容，并隐藏停放在后台桌面的窗口。
- **最小化与隐藏** — 包含最小化窗口、隐藏的 App 和无窗口 App；可将最小化窗口沉到列表末尾，也可让它们保持最近使用顺序。
- **置顶与筛选** — 将常用项目固定在顶部，隐藏其他项目。
- **按 App 设置规则** — 隐藏某个 App，或让它始终忽略 ⌘Tab，亦可仅在全屏时忽略。

### 效率与工作流

- **App 快捷键** — 为选定 App 分配全局快捷键，以聚焦或启动它（9 个位置）。
- **最近关闭** — 重新打开刚刚退出的 App。
- **未读角标** — 在切换器中显示 Dock 图标上的角标数字。
- **音频指示器** — 标记正在播放声音的 App。
- **即时切换 Spaces** — 无动画切换 Spaces。

### 可靠性与高级功能

- **强制退出** — 当正常退出卡住时，使用 `⌘+⌥+Q` 对高亮 App 执行 SIGKILL。
- **安全输入下仍可使用** — 即使密码输入框占用 Secure Event Input，⌘Tab 和窗口管理仍能正常工作。

### 外观与自定义

- **主题** — 可设置面板不透明度、圆角半径和背景材质；选择高亮会跟随 macOS 强调色。
- **预览标题** — 可选择窗口标题在预览中的对齐方式，以及是否以粗体显示选中名称。
- **状态图标** — 可隐藏每行末尾的隐藏 / 最小化 / 无窗口 / 全屏标记。
- **动效** — 可关闭切换器动画，改为直接切换；同时遵循系统的“减弱动态效果”。
- **可配置** — 自定义快捷键、尺寸、缩放比例、布局、网格列数（含自动缩小图块的单行网格）和显示延迟。

### 手势与反馈

- **触控板与触觉反馈** — 三指轻扫可打开切换器或切换 Spaces，并可选择启用触觉和点击反馈。

### 隐私与备份

- **从屏幕共享中隐藏** — 不在屏幕录制和共享屏幕中显示切换器。需要 macOS 14.6 或更高版本。
- **导出与导入** — 将完整设置备份并迁移为普通 JSON 文件（仍可导入旧版 `.cmdtab` 文件）。
- **配置文件** — 可选择将设置保存在 `~/.config/bettercmdtab/config.json` 中：编辑会实时生效，App 内所做的更改也会写回。旁边会生成一个 `schema.json`（并由该文件引用），让编辑器能够自动补全并检查编辑内容的类型。

<a id="install"></a>

## 安装

### 系统要求

- macOS 13.0（Ventura）或更高版本
- 辅助功能权限

### Homebrew

```bash
# 稳定版
brew install --cask bettercmdtab

# 测试版
brew install --cask bettercmdtab@beta
```

### 下载

从 [Releases 页面](https://github.com/rokartur/BetterCmdTab/releases)获取最新签名版 `.dmg`，打开后将 `BetterCmdTab.app` 拖入 `/Applications`，然后启动。

首次启动时，macOS 会请求**辅助功能**权限——全局 ⌘+Tab 事件拦截以及通过 Accessibility API 读取窗口列表都需要此权限。请前往`系统设置 → 隐私与安全性 → 辅助功能`授予权限。

<a id="build-from-source"></a>

### 从源码构建

如果你希望自行从源码构建，请参阅 [CONTRIBUTING.md 中的这一节](CONTRIBUTING.md#Building)获取说明。

## 隐私

BetterCmdTab 不收集、传输或存储任何数据。它不包含遥测、崩溃报告服务、分析 SDK，也不需要账户。它仅在你主动要求检查更新时向 `api.github.com` 和 `github.com` 发起网络请求。

<a id="contributing"></a>

## 参与贡献

欢迎提交 Issue 和 Pull Request。项目结构、构建/测试说明及 PR 指南请参阅 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

GPL v3。请参阅 [LICENSE](LICENSE)。

BetterCmdTab 采用 GNU General Public License v3.0 授权。你可以自由使用、研究、修改和再分发它，包括用于商业用途；但任何分发的衍生作品也必须以 GPL v3 发布并提供完整源代码。这确保本项目及其所有分支永远保持开放。

## 致谢

由 [@rokartur](https://github.com/rokartur) 开发。灵感来自 [AltTab](https://alt-tab.app/)、[Witch](https://manytricks.com/witch/) 和 [Contexts](https://contexts.co/)。
