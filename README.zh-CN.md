# AeroSpace Companion

一套适合日常使用的
[AeroSpace](https://github.com/nikitabobko/AeroSpace) 配置，附带类似 AltTab
的窗口切换器和紧凑的窗口控制台。

[English](README.md)

## 功能

- `Option + Tab`：按 AeroSpace workspace 分组浏览所有窗口。
- `Option + Shift + Tab`：反向浏览。
- AeroSpace 运行时以相同的窗口切换器接管 `Command + Tab`，不再显示 macOS
  App 切换器（首次使用需要授予辅助功能和输入监控权限）。
- 鼠标悬停只显示反馈，不改变键盘焦点；点击后切换窗口。
- 按住 `Command` 浏览时，使用 `Command + W` 关闭选中窗口，或用
  `Command + Q` 退出选中窗口所属的 App。
- `Command + Tab` 的前九项显示 `Command + 1-9` 键帽，可直接选中对应项，
  松开 `Command` 后照常切换。
- 显示正在运行但没有窗口的 App，并可重新打开。
- Workspace 标题显示用途、所在显示器、当前可见状态和窗口数量。
- 列表项标记当前、全屏、浮动和隐藏状态，并在右侧显示 Dock 未读数量、
  麦克风占用和音频播放状态；无法取得具体数量时仍显示红点。
- 局部半透明浮层，自动跟随 macOS 浅色或深色外观。
- `Option + Shift + M`：打开窗口控制台，可移动 workspace、切换布局与显示器、
  整理和缩放窗口。数字键移动当前窗口到 workspace 1-10，按住 `Shift` 则移动
  当前 App 的全部窗口。
- 自动将开发、浏览器、通讯、媒体和设计应用分配到对应 workspace。
- 可选竖屏承载沟通、AI 和 Aerial 氛围空屏；快速笔记和临时工具仍自动悬浮。
- 画中画和迷你播放器窗口悬浮在当前 workspace。
- 支持持久 workspace、多显示器分配、焦点循环、独立缩放与窗口整理模式，
  切换显示器时鼠标按需跟随。

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

窗口切换器与窗口控制台可在其他 Mac 上使用；仓库中的多屏配置是一个
个人预设，按 `built-in`、`dell`、`Portrait` 匹配显示器，并不会自动识别
其他机器的媒体屏、工作屏和竖屏。不同硬件需要修改配置里的
`workspace-to-monitor-force-assignment`、显示器快捷键，以及
`scripts/aerospace-show-ambient` 的返回显示器。默认终端 Ghostty 需要另行安装，
或使用下面的选项指定已有终端。

安装器不会安装 Aerial、修改 macOS 显示器排列或安装系统显示器名称覆盖。
Workspace 10 只是显示当前壁纸。多屏用户还需按
[AeroSpace 的排列要求](https://nikitabobko.github.io/AeroSpace/guide#proper-monitor-arrangement)
给隐藏窗口留出底角空间。未读数量和音频状态取决于系统及应用提供的信息。

也可以手动 clone：

```bash
git clone https://github.com/tovifun/aerospace-companion.git
cd aerospace-companion
./scripts/install.sh --with-config
```

`Option + Enter` 默认打开一个新的 Ghostty 窗口。可以在安装时改成其他终端：

```bash
AEROSPACE_TERMINAL_APP=Kitty ./scripts/install.sh --with-config
```

不传 `--with-config` 时，本地安装器只更新辅助工具，不替换配置。

### 可选社区集成

安装后的配置会在检测到 `borders` 命令时自动启动 JankyBorders：

```bash
brew install FelixKratz/formulae/borders
```

如需三指横扫切换 workspace，并自动跳过空 workspace、在首尾循环，可安装
[aerospace-swipe](https://github.com/acsandmann/aerospace-swipe)。它作为独立的
launch agent 运行，首次启动可能要求辅助功能权限：

```bash
curl -sSL https://raw.githubusercontent.com/acsandmann/aerospace-swipe/main/install.sh | bash
```

### 首次授权

安装完成后会自动打开权限引导。依次为 AeroSpace Window Switcher 开启：

1. **辅助功能**：允许替换系统的 `Command + Tab`。
2. **输入监控**：允许读取 `Command`、`Shift` 和 `Tab` 按键。

引导窗口会实时显示授权状态。如果输入监控列表中没有本应用，可以点击
“显示应用”，再使用系统设置列表下方的 `+` 添加；macOS 询问时请选择
“退出并重新打开”。这些权限只需授予一次，之后重启 AeroSpace 不会重复请求。

### Command 操作优先使用鼠标悬停项

默认情况下，`Command + W/Q` 操作蓝色的键盘选中项。若希望鼠标悬停在灰色
项目上时优先操作该项目，可运行：

```bash
defaults write io.github.tovifun.aerospace-companion.window-switcher \
  hoveredItemActionPriority -bool true
```

将值改为 `false` 即可恢复键盘选中项优先。修改后需重启窗口切换器。

## 更新

首次安装后，使用下面的命令更新到最新版并应用最新配置：

```bash
~/.local/bin/aerospace-companion-update
```

每次更新都会先备份当前配置。

## Workspace 自动分配

| Workspace | 分类 | 应用 |
| --- | --- | --- |
| `1` | 媒体和会议 | Music、网易云音乐、汽水音乐、Spotify、VLC、哔哩哔哩、抖音、TV、腾讯会议 |
| `2` | 浏览和资料 | Chrome、Safari、Edge、Dia、Vivaldi、ChatGPT Atlas、ego lite |
| `3` | 临时预览 | 不自动分配应用 |
| `4` | Codex 和编辑器 | Codex、Zed、Cursor、VS Code、Zcode、Xcode |
| `5` | 终端和 Agent | Ghostty、cmux、tty7、Otty、OpenCode |
| `6` | Git、数据库、API 和诊断 | Fork、DataGrip、Requestly、活动监视器、控制台 |
| `7` | 设计和内容 | Figma、Eagle、RightFont、OBS、Screen Studio、Audacity、Writer、Typora、Clearly、Lettera、备忘录、文本编辑 |
| `8` | 沟通和日常速览 | 飞书、微信、企业微信、Mail、Calendar、Reminders |
| `9` | AI、研究 | Claude、WorkBuddy AI、Grok Bot |
| `10` | 氛围空屏 | 不自动分配应用，专门留给 Aerial |

Workspace 1-3 固定到内置媒体副屏，4-7 固定到 DELL 主工作屏。8-10 优先
放在可选竖屏；竖屏断开时自动回退到 DELL，如果 DELL 也不存在才回退到
内置屏。回退后的 workspace 仍相互独立，不会混入当前 workspace 的窗口布局。
竖屏使用系统级名称 `Portrait`，同时保留空 EDID 名称作为兼容回退。

## 常用快捷键

| 快捷键 | 操作 |
| --- | --- |
| `Option + Tab` | 打开按 workspace 分组的窗口切换器 |
| `Option + Shift + Tab` | 反向切换 |
| `Option + Shift + M` | 打开窗口控制台 |
| `Command + W` | 切换器打开时关闭选中的窗口 |
| `Command + Q` | 切换器打开时退出选中窗口所属的 App |
| `Option + H/J/K/L` | 向左/下/上/右聚焦窗口，到 workspace 边缘后循环 |
| `Option + 反引号` | 在最近聚焦的两个窗口间切换 |
| `Option + Shift + H/J/K/L` | 移动当前窗口 |
| `Option + 1-9/0` | 切换到 workspace 1-10 |
| `Option + Shift + 1-9/0` | 移动当前窗口到 workspace 1-10 并跟随 |
| `Option + 左/右方向键` | 循环当前显示器上的非空 workspace |
| `Option + /` | 在 tiles 和 accordion 间切换 |
| `Option + Shift + /` | 修改 tile 方向 |
| `Option + Shift + Space` | 在 floating 和 tiling 间切换 |
| `Option + F` | 切换全屏 |
| `Option + R` | 进入窗口缩放模式 |
| `Option + B` | 返回上一个 workspace |
| `Option + S` | 进入窗口整理模式 |
| `Option + Control + H/J/K/L` | 聚焦其他显示器 |
| `Option + Control + Shift + H/J/K/L` | 将窗口移动到其他显示器 |
| `Option + Control + 1/2/3` | 直接聚焦内置屏／DELL／竖屏 |
| `Option + Control + Shift + 1/2/3` | 将窗口移到内置屏／DELL／竖屏 |
| `Option + Control + 0` | 让竖屏显示 Ambient 空 workspace，然后把焦点送回 DELL |

整理模式中，使用 `H/J/K/L` 交换窗口，`Shift + H/J/K/L` 创建窗口分组，
`R` 扁平化当前 workspace，`Esc` 退出。

缩放模式中，使用 `H/J/K/L` 以 50 点调整宽度或高度，
`Shift + H/J/K/L` 以 10 点微调，使用 `Enter` 或 `Esc` 退出。

窗口控制台中，使用 `1-9/0` 移动当前窗口，使用 `Shift + 1-9/0` 移动当前
App 的全部窗口；`F` 切换浮动/平铺，`M` 切换全屏，`T` 切换
tiles/accordion，`O` 切换布局方向，`B` 均分，`R` 重置，方向键跨显示器移动，
`A` 和 `Z` 分别进入带提示的排列与缩放模式。

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
