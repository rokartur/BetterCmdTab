<div align="center">

<img src=".github/og.png" alt="BetterCmdTab：macOS 应得的 ⌘+Tab" width="100%" />

<p>
  <a href="https://github.com/rokartur/BetterCmdTab/releases/latest"><img alt="下载" src="https://img.shields.io/badge/Download-F5F5F4?style=for-the-badge&logo=apple&logoColor=black"></a>
  <a href="https://github.com/rokartur/BetterCmdTab/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/rokartur/BetterCmdTab?include_prereleases&style=for-the-badge&label=release&color=white&labelColor=4B4960"></a>
  <a href="https://github.com/rokartur/BetterCmdTab/releases"><img alt="下载量" src="https://img.shields.io/github/downloads/rokartur/BetterCmdTab/total?style=for-the-badge&color=white&labelColor=4B4960"></a>
</p>

<a href="https://bettercmdtab.app">网站</a> · <a href="https://bettercmdtab.app/docs/">文档</a> · <a href="README.md">English</a>

</div>

原生的 macOS ⌘Tab 替代品。列表、网格或实时窗口预览，内置搜索、浏览器标签页和窗口平铺。免费、开源、无遥测。

## 安装

```bash
brew install --cask bettercmdtab        # 稳定版
brew install --cask bettercmdtab@beta   # 测试版
```

也可以从 [Releases](https://github.com/rokartur/BetterCmdTab/releases/latest) 下载签名版 `.dmg`。需要 macOS 13 或更高版本。

首次启动时，请在“系统设置 → 隐私与安全性 → 辅助功能”中授予权限。没有该权限，⌘Tab 不会有任何反应。

## 布局

| 列表 | 网格 | 预览 |
| :-: | :-: | :-: |
| <img src="web/public/screenshots/list.jpg" alt="列表布局" /> | <img src="web/public/screenshots/grid.jpg" alt="网格布局" /> | <img src="web/public/screenshots/preview.jpg" alt="窗口预览布局" /> |

## 功能

**切换**

- 轻点 ⌘Tab 立即切换，按住则打开切换器。按 Shift 反向移动。
- 输入字母即可跳转，或按 `/` 模糊搜索窗口并启动任意已安装的 App。
- `` ⌘` `` 循环切换当前 App 的窗口。滚轮可移动选择。
- 在你正在使用的显示器上打开。松开 ⌘ 后可保持打开。
- 三指轻扫可打开切换器或切换 Spaces，可选触觉反馈。

**窗口与标签页**

- 按 `\` 选择标签页：Safari、Chrome、Arc、Brave、Edge、Vivaldi、Opera、Dia、Finder、Terminal、iTerm。也可将每个标签页显示为独立行。
- 直接在切换器中关闭、最小化、缩放、隐藏、退出或强制退出（`⌘⌥Q`）。
- 使用 `⌃⌘` 加方向键平铺（再按一次在 ½ → ⅔ → ⅓ 间循环）、最大化、居中，或将窗口移到下一个显示器。

**筛选**

- 按最近使用的 App、最近使用的窗口、名称或启动顺序排序。
- 显示所有 Spaces、当前 Space，或仅显示各显示器上可见的内容。
- 置顶常用 App、隐藏 App，或让某个 App 跳过 ⌘Tab（始终或仅在全屏时）。
- 限定范围的快捷键会打开预先筛选的切换器，拥有独立的布局和规则。
- 九个 App 快捷键可直接聚焦或启动指定 App。

**其他**

- 在切换器中显示 Dock 未读角标和正在播放音频的指示。
- 重新打开刚退出的 App。无动画即时切换 Spaces。
- 即使密码输入框占用 Secure Event Input 也能正常工作。
- 不出现在屏幕共享和录屏中（macOS 14.6+）。
- 可调不透明度、圆角、材质、尺寸和网格列数。跟随强调色和“减弱动态效果”。
- 将设置导出为 JSON，或与 `~/.config/bettercmdtab/config.json` 实时同步（自动生成的 `schema.json` 为编辑器提供自动补全）。

所有选项详见[文档](https://bettercmdtab.app/docs/)。

## 隐私

无遥测、无分析、无崩溃报告、无需账户。唯一的网络请求发往 GitHub，且仅在检查更新时发生。

## 参与贡献

欢迎提交 Issue 和 Pull Request。构建和测试说明见 [CONTRIBUTING.md](CONTRIBUTING.md#building)。

## 许可证

[GPL v3](LICENSE)。由 [@rokartur](https://github.com/rokartur) 开发，灵感来自 [AltTab](https://alt-tab.app/)、[Witch](https://manytricks.com/witch/) 和 [Contexts](https://contexts.co/)。
