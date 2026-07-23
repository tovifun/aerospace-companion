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
- 附带一套低间距、容易上手的完整 AeroSpace 配置。

## 环境要求

- macOS 13 或更高版本。
- Apple Command Line Tools：`xcode-select --install`。
- AeroSpace，官方推荐的 Homebrew 安装命令：

```bash
brew install --cask nikitabobko/tap/aerospace
```

## 安装

```bash
git clone https://github.com/tovifun/aerospace-companion.git
cd aerospace-companion
./scripts/install.sh --with-config
```

`--with-config` 会先备份已有 AeroSpace 配置，再安装仓库中的完整配置。
不传此参数时只安装辅助工具，不修改配置。

`Option + Enter` 默认打开 Ghostty。可以在安装时改成其他终端：

```bash
AEROSPACE_TERMINAL_APP=Kitty ./scripts/install.sh --with-config
```

安装器会在本机编译 Swift 工具并安装到 `~/.local`，同时支持 Apple
Silicon 和 Intel Mac。

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
