# AeroSpace Companion

一套适合日常使用的
[AeroSpace](https://github.com/nikitabobko/AeroSpace) 配置，附带类似 AltTab
的窗口切换器和紧凑的窗口控制台。

[English](README.md)

## 功能

- `Option + Tab`：按 AeroSpace workspace 分组浏览所有窗口。
- Option-Tab 与 Command-Tab 使用相同列表及顺序；空工作区显示为紧凑的单行入口，
  选中后松开对应修饰键或鼠标点击即可进入，不启动 App。
- `Option + Shift + Tab`：反向浏览。
- `Option + P`：搜索所有工作区的窗口。可按应用名、窗口标题、工作区编号／标签、
  显示器名过滤，多个关键词用空格分隔；支持中文。上下键选择、回车切换、Esc 取消，
  松开 Option 后搜索框继续打开。也可从菜单栏选择「搜索窗口…」。
- AeroSpace 运行时以相同的窗口切换器接管 `Command + Tab`，不再显示 macOS
  App 切换器（首次使用需要授予辅助功能和输入监控权限）。
- 鼠标悬停只显示反馈，不改变键盘焦点；点击后切换窗口。
- 按住 `Command` 浏览时，使用 `Command + W` 关闭选中窗口，或用
  `Command + Q` 退出选中窗口所属的 App。
  操作期间显示进度，确认窗口消失或 App 退出后才移除；底部显示完成、不可用和等待提示。
  超过 12 秒仍未完成时保留原项目并提示检查 App 的确认对话框，也可选择等待中的项目前往查看。
  删除项目时保持面板位置和当前可见项目的位置，滚动到底部时也避免跳动。
  关闭最后一个窗口后，松开 Command 不会立即把它重新打开。
- `Command + Tab` 的前九项显示 `Command + 1-9` 键帽，可直接选中对应项，
  松开 `Command` 后照常切换。
- 显示正在运行但没有窗口的 App，并可重新打开。
  打开后会主动刷新窗口缓存；极快地再次打开列表时，短暂等待新快照，减少旧条目先出现再跳位。
  新窗口登记期间保留 App 的可操作入口，避免窗口过滤与 App 分类不同步导致项目消失。
- Workspace 显示当前／可见状态圆点与布局方向图标，右侧保留 D1/D2/D3。
  悬停图标可查看完整说明；用途标签可选。
- 列表项标记当前、全屏、浮动和隐藏状态，并在右侧显示 Dock 未读数量、
  麦克风占用和音频播放状态；无法取得具体数量时仍显示红点。
- 原生设置窗口可选择默认或紧凑布局，以及是否显示空工作区；偏好自动保存。
- 默认窗口行高 34pt、空工作区行高 32pt、App 图标 28pt；紧凑模式分别为 32pt、30pt、26pt。
  半透明浮层自动跟随 macOS 浅色或深色外观。
- `Option + Shift + M`：打开窗口控制台，可移动 workspace、切换布局与显示器、
  整理和缩放窗口。数字键移动当前窗口到 workspace 1-10，按住 `Shift` 则移动
  当前 App 的全部窗口。
- 默认使用中性的数字 workspace，开发者应用自动分配作为可选示例提供。
- 不依赖特定显示器；快速笔记和临时工具自动悬浮。
- 画中画和迷你播放器窗口悬浮在当前 workspace。
- 支持持久 workspace、多显示器分配、焦点循环、独立缩放与窗口整理模式，
  切换显示器时鼠标按需跟随。

## 设置

更新时会保留个人配置；已有用户需要在 `[mode.main.binding]` 中增加搜索快捷键：

```toml
alt-p = 'exec-and-forget ~/.local/bin/aerospace-window-switcher-trigger --search'
```

多屏按设备名称分配的示例见 [named-monitors.toml](config/examples/named-monitors.toml)。
请使用 `aerospace list-monitors` 确认名称，并替换已有分配表，避免重复定义。

点击菜单栏的 AeroSpace Companion 图标，选择「设置…」。也可以直接打开已安装的 App，
在切换器中按 `Command + ,`，或运行：

```sh
~/.local/bin/aerospace-window-switcher-trigger --settings
```

- **列表布局**：默认使用 34pt 窗口行、32pt 空工作区行；紧凑使用 32pt 和 30pt，正文 14pt，
  同时缩小 App 图标、分组标题与组间距。
- **显示空工作区**：开启时保留可直接进入的空工作区；关闭时只显示有窗口的工作区。
  「其他 APP」中的无窗口应用不受此开关影响。

默认使用「默认」布局并显示空工作区。设置自动保存，下次打开切换器时生效；
Option-Tab 和 Command-Tab 共用同一设置。关闭设置窗口后，切换器继续在后台运行。

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

首次安装会备份当前 AeroSpace 配置、安装仓库配置、在本机编译原生工具并
重新加载 AeroSpace。之后在线更新默认保留个人配置。支持 Apple Silicon 和 Intel Mac。

默认配置不绑定任何显示器，使用平铺布局和自动方向；新 workspace 的初始
方向由 AeroSpace 按屏幕宽高决定。`Option + Enter` 使用 macOS 自带 Terminal，
无需额外安装终端。默认不按应用自动搬动窗口，应用分配规则可按需启用。

安装器不会修改 macOS 显示器排列。多屏用户仍需按
[AeroSpace 的排列要求](https://nikitabobko.github.io/AeroSpace/guide#proper-monitor-arrangement)
给隐藏窗口留出底角空间。未读数量和音频状态取决于系统及应用提供的信息。

也可以手动 clone：

```bash
git clone https://github.com/tovifun/aerospace-companion.git
cd aerospace-companion
./scripts/install.sh --with-config
```

`Option + Enter` 默认打开一个新的 Terminal 窗口。可指定已安装的其他终端：

```bash
AEROSPACE_TERMINAL_APP=Ghostty ./scripts/install.sh --with-config
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
悬停操作会在按键时重新检测鼠标下的项目，关闭刷新后仍可连续操作。
即使关闭窗口后 AeroSpace 将焦点交给其他 App，切换器也会继续接收快捷键和滚动输入。

## 更新

首次安装后，使用下面的命令更新辅助工具，保留你的个人配置：

```bash
~/.local/bin/aerospace-companion-update
```

只有显式运行 `~/.local/bin/aerospace-companion-update --with-config`，
才会备份并替换为最新版通用配置。

## Workspace 与可选分配

Companion 支持可选的自动屏幕分配：三屏时工作区 1 在笔记本屏幕、2–8 在工作屏、
其余在扩展屏；两屏时 1 在第一屏、其余在第二屏；单屏全部归到当前屏幕。
它按设备名称识别屏幕角色，插拔稳定后调整，并覆盖新增工作区（包括 11、12 及以后）。
使用时删除个人配置中的 `workspace-to-monitor-force-assignment` 表，避免原生强制分配阻止移动。
按实际设备名称修改以下配置，写入后重启 Companion：

```sh
defaults write io.github.tovifun.aerospace-companion.window-switcher workspaceMonitorRoutingProfile -string \
  '{"primaryNames":["Built-in Retina Display"],"workNames":["DELL P2723QE","KOIOS K2721UD"],"extraNames":["Portrait"]}'
```

缺失的设备角色使用剩余屏幕兜底；未配置名称的第三屏也可作为扩展屏。
启用后，偏离规则或新增的工作区通常在 2 秒内归位；插拔需等待屏幕列表稳定。
该功能默认关闭，偏好随普通更新保留；删除 `workspaceMonitorRoutingProfile` 并重启可关闭。

默认保留数字工作区 1–10，不预设职业用途，不按 App 自动分配，也不强制绑定显示器。
使用 `Option + Control + Tab` 将当前 workspace 移到下一块显示器。
这是 AeroSpace 原生操作，但不保证每次拔插都精确恢复之前的位置。

喜欢开发者分类的人，可以把[可选规则示例](config/examples/developer-routing.toml)
中的条目复制到现有 `on-window-detected` 数组内，不要重复定义数组。
示例分配为：1 媒体、2 浏览、3 编辑器、4 终端、5 开发工具、6 沟通、
7 内容、8 AI；9 和 10 手动使用。示例不包含任何显示器绑定。

示例数组开头还有一条与 App 无关的守卫规则：

```toml
{ if = 'test %{window-layout} = floating', run = 'layout floating' },
```

由于 `on-window-detected` 命中第一条规则后即停止，这条规则会让 AeroSpace 已判定为
浮动（floating）的窗口——对话框、快捷搜索、面板、文件选择器等——停留在打开时所在
的工作区，而不会被拖到 App 对应的工作区。它必须放在所有有意移动浮动窗口的规则之后
（例如画中画规则），并在 App 路由规则之前。无需为每个 App 写例外。

界面用途标签独立设置，不影响窗口分配，例如：

```bash
defaults write io.github.tovifun.aerospace-companion.window-switcher \
  workspaceLabels -dict 1 媒体 2 浏览 3 开发 4 终端 6 沟通
```

修改后重启切换器。未设置标签的工作区仍显示中性名称。
运行 `defaults delete io.github.tovifun.aerospace-companion.window-switcher workspaceLabels`
可恢复默认标签。个人 App 规则和显示器分配留在本机 AeroSpace 配置中，普通更新不会覆盖。

另有[笔记本＋顺序屏幕分配示例](config/examples/laptop-ordered-monitors.toml)：
1 在笔记本，2–8 在第 2 块屏，9–10 优先第 3 块、缺屏回退第 2 块，
也就是竖屏第 3 块屏承载两个工作区。
它要求两处保持「笔记本、工作屏、可选第三屏」从左到右排列，不依赖 macOS 主显示器。
该示例默认不安装；改变排列或合盖会改变屏幕编号。启用强制分配后，不能再手动搬动整个工作区到另一屏。

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
| `Option + Control + Tab` | 将当前 workspace 移到下一块显示器 |

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
