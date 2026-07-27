# AeroSpace Companion

一套适合日常使用的
[AeroSpace](https://github.com/nikitabobko/AeroSpace) 配置，附带类似 AltTab
的窗口切换器，以及一键移动当前 App 全部窗口的工作流。

[English](README.md)

## 功能

- `Option + Tab`：按 AeroSpace workspace 分组浏览所有窗口。
- `Option + Shift + Tab`：反向浏览。
- 支持键盘、鼠标悬停和点击选择。
- 显示正在运行但没有窗口的 App，并可重新打开。
- 局部半透明浮层，自动跟随 macOS 浅色或深色外观。
- `Option + Shift + M`：将当前 App 的所有窗口移动到 workspace 1-9。
- 自动将开发、浏览器、通讯、媒体和设计应用分配到对应 workspace。
- 写作工具、系统工具以及飞书/微信附属窗口自动悬浮。
- 关闭当前悬浮窗口后，自动恢复此前聚焦的平铺窗口。
- 支持持久 workspace、多显示器分配和窗口整理模式。

## 环境要求

- macOS 13 或更高版本。
- Apple Command Line Tools：`xcode-select --install`。
- AeroSpace，官方推荐的 Homebrew 安装命令：

```bash
brew install --cask nikitabobko/tap/aerospace
```

## 安装

一条命令完成安装或更新：

```bash
curl -fsSL https://raw.githubusercontent.com/tovifun/aerospace-companion/main/scripts/install-online.sh | sh
```

安装器会备份当前 AeroSpace 配置、安装仓库配置、在本机编译原生工具并
重新加载 AeroSpace，同时支持 Apple Silicon 和 Intel Mac。

也可以手动 clone：

```bash
git clone https://github.com/tovifun/aerospace-companion.git
cd aerospace-companion
./scripts/install.sh --with-config
```

`Option + Enter` 默认打开 Ghostty。可以在安装时改成其他终端：

```bash
AEROSPACE_TERMINAL_APP=Kitty ./scripts/install.sh --with-config
```

不传 `--with-config` 时，本地安装器只更新辅助工具，不替换配置。

## 更新

首次安装后，使用下面的命令更新到最新版并应用最新配置：

```bash
~/.local/bin/aerospace-companion-update
```

每次更新都会先备份当前配置。

## Workspace 自动分配

| Workspace | 分类 | 应用 |
| --- | --- | --- |
| `1` | 开发 | Codex、Claude、Zed、Cursor、VS Code、Xcode、Ghostty、DataGrip、Fork、OpenCode |
| `2` | 浏览器 | Chrome、Safari、Edge、Dia、Vivaldi、ChatGPT Atlas |
| `3` | 通讯 | 飞书、微信、企业微信、腾讯会议、Mail |
| `4` | 媒体 | Music、网易云音乐、汽水音乐、VLC、哔哩哔哩、抖音、TV |
| `5` | 设计 | Figma、Eagle、RightFont、OBS、Screen Studio、Audacity |

Workspace 1-2 优先放在主显示器，3-9 优先放在内置显示器；没有内置屏幕时
自动回退到主显示器。写作和任务应用不绑定 workspace，默认悬浮在当前
workspace。

## 常用快捷键

| 快捷键 | 操作 |
| --- | --- |
| `Option + Tab` | 打开按 workspace 分组的窗口切换器 |
| `Option + Shift + Tab` | 反向切换 |
| `Option + Shift + M` | 移动当前 App 的全部窗口 |
| `Option + H/J/K/L` | 向左/下/上/右聚焦窗口 |
| `Option + Shift + H/J/K/L` | 移动当前窗口 |
| `Option + 1-9` | 切换 workspace |
| `Option + Shift + 1-9` | 移动当前窗口并跟随 |
| `Option + /` | 在 tiles 和 accordion 间切换 |
| `Option + Shift + /` | 修改 tile 方向 |
| `Option + Shift + Space` | 在 floating 和 tiling 间切换 |
| `Option + F` | 切换全屏 |
| `Option + B` | 返回上一个 workspace |
| `Option + S` | 进入窗口整理模式 |
| `Option + Control + H/J/K/L` | 聚焦其他显示器 |
| `Option + Control + Shift + H/J/K/L` | 将窗口移动到其他显示器 |

整理模式中，使用 `H/J/K/L` 交换窗口，`Shift + H/J/K/L` 创建窗口分组，
`R` 扁平化当前 workspace，`Esc` 退出。

## 卸载

卸载工具，并恢复安装时备份的配置：

```bash
aerospace-companion-uninstall --restore-config
```

不传 `--restore-config` 时保留当前 AeroSpace 配置。

## 开发

```bash
make build
make test
```

窗口切换器使用原生 AppKit 开发，不依赖第三方运行时或软件包。

## License

MIT
