# Meerkat

[English](README.md) | 简体中文

一只蹲在你 Mac 桌面上的小狐獴，专门替你盯着 Claude Code。

Claude Code 跑长任务的时候，不用再一遍遍切回去看：跑完了、要你点确认了，它会站起来叫你。你可以放心走开。

```
   ╭──────────────────────────────────────────╮
   │   /\_/\    MEERKAT                       │
   │  ( o.o )   1 needs you · 1 working       │
   │   > ^ <                                  │
   ├──────────────────────────────────────────┤
   │ PLAN USAGE                      just now │
   │ Session  ▓▓░░░░░░░░░   16%      12:10 AM │
   │ Week     ▓▓▓▓▓▓▓▓▓░░   81%   Mon 9:00 AM │
   │ Fable    ▓▓▓▓▓▓▓▓▓▓▓  100%   Mon 9:00 AM │
   ├──────────────────────────────────────────┤
   │ ● api-server            needs you · 2m   │
   │   needs permission                       │
   ├──────────────────────────────────────────┤
   │ ● meerkat                    3/5 · 14m   │
   │   Wire up the progress bar               │
   │   ▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░                   │
   ├──────────────────────────────────────────┤
   │ ✓ docs                       done · 6m   │
   │   Update the README                      │
   ╰──────────────────────────────────────────╯
```

狐獴是画出来的，不是 emoji：有任务在跑时它站直了四处张望；有会话等你确认时，它头上冒个"!"，"叮"一声；任务做完时，它举手蹦一下，再响一声；出错了它会耷拉下来；什么都没有时它打盹。不想听声音，右键 → Mute sounds。

## 它能显示什么

**每个会话：** 状态（在跑、等你、做完、出错）、在这个状态多久了、正在做或刚做完的那条指令；Claude 在用任务清单时，还有一条真实的进度条（比如 3/5）。

**套餐额度：和 claude.ai 上一样的几条。** 当前 5 小时额度、本周所有模型合计的额度，以及每个有单独周额度的模型，各显示用了百分之多少、什么时候重置。和 claude.ai 的「设置 → 用量」页是同一个数据来源。

额度数据来自 `api.anthropic.com/api/oauth/usage`，也就是 Claude Code 自己的 `/usage` 用的接口。这需要用到你的 Claude Code 登录凭据，这是 Meerkat 唯一碰到凭据的地方，而且碰得很克制：

- 和 Claude Code 一样，用 `/usr/bin/security` 从登录钥匙串里的 `Claude Code-credentials` 读取，所以 macOS 不会弹窗问你。钥匙串锁着时直接跳过，不会弹出解锁框。
- 每次请求现读现用，不记日志、不写文件。`~/.meerkat/usage-api.json` 里只有数字和每次检查的结果。
- 从不刷新凭据（刷新会让 Claude Code 掉登录）；凭据过期就等 Claude Code 自己续上。
- 每 3 分钟查一次；会话做完一轮、电脑唤醒时也会查。
- 右键 → **Turn off plan usage** 可以立刻关掉，之后不再读钥匙串、不再发请求。

终端、VS Code 插件、桌面版里的 Claude Code 都能用。

## 安装

需要 macOS 13 或更高版本、较新版本的 Claude Code（在 2.1.296 上测试过，太老的版本可能收不到全部事件），以及 Xcode 命令行工具（提供 `swiftc` 和 `python3`，不用装完整的 Xcode）：

```bash
xcode-select --install
```

然后：

```bash
git clone https://github.com/tinytoots/meerkat
cd meerkat
./install.sh                    # 把 hook 接进 Claude Code
./build.sh                      # 编译出 Meerkat.app
open build/Meerkat.app          # 启动
```

`install.sh` 会让 hook 使用你 PATH 里第一个 `python3`。如果那是 pyenv、conda 或 Homebrew 装的 Python，哪天删了 hook 就会失效。建议改用系统自带的那个：

```bash
PATH="/usr/bin:$PATH" ./install.sh
```

装好后，**新开一个 Claude Code 会话**（已经开着的会话不会读到新的 hook，在里面执行 `/clear` 也行），发一条指令，窗口里就会出现一行。

终端、VS Code、桌面版读的都是同一个 `~/.claude/settings.json`，装一次全都生效。

遇到问题，运行 `./scripts/doctor.sh`，它会逐项检查，并告诉你哪条命令能修好。

### 开机自动启动

```bash
cp -R build/Meerkat.app /Applications/
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Meerkat.app", hidden:true}'
```

## 怎么用

| | |
|---|---|
| 移动窗口 | 拖窗口上不是按钮的地方 |
| 缩成只剩狐獴 | 点一下狐獴 |
| 隐藏 | 任何地方按 ⌃⌘M，或右键 → Hide Meerkat |
| 再显示 | 再按 ⌃⌘M，或点菜单栏里的爪印，或重新打开 Meerkat |
| 菜单（静音、退出等） | 右键窗口，或点爪印 |
| 查看文件夹、完整指令和计数 | 鼠标悬停在某一行上 |
| 关掉一行 | 悬停，点时间位置上出现的 ×。这个会话有新动静时（你发了新消息、它又要你确认、状态变了）会再出现 |
| 找回关掉的行 | 点顶部 MEERKAT 旁边的"N dismissed"，或右键 → Show dismissed sessions |

窗口浮在其他窗口上面，切换桌面空间也跟着走，不占程序坞和 ⌘Tab。

隐藏后它照样放哨：提示音照常响，菜单栏的爪印会变成需要你处理的会话的颜色（橙色是等你，红色是出错）。

小提示：带刘海的 MacBook 菜单栏图标一多，新图标会被挤到看不见。看不到爪印的话，关掉一个用不上的菜单栏 app，或者直接用 ⌃⌘M。

## 卸载

```bash
./scripts/enable-usage.sh --disable   # 只有你设置过状态栏备用方案时才需要
./install.sh --uninstall              # 从 settings.json 里移除 Meerkat 的 hook
```

然后退出 Meerkat（右键 → Quit Meerkat），删掉开机启动项和 `/Applications` 里的副本（如果有），也可以 `rm -rf ~/.meerkat`。先退出再删，不然运行中的 Meerkat 会把文件夹再建出来。

## 已知的局限

- **云端会话看不到**：它们不读你本机的设置文件。
- **需要信任工作区**：在还没接受信任提示的文件夹里，hook 不会运行。
- **"needs you"会比你的操作晚一点消失**：你批准了权限后，要等那一轮工具跑完才会变回去，中间没有 hook 能通知它。
- **额度接口没有公开文档**：Claude Code 和 claude.ai 都在用，但格式随时可能变。Meerkat 读不懂的数据宁可不显示，也不会编一个数字。
- **额度需要用 Claude 套餐登录**：用 API Key 登录的没有套餐，也就没有额度可显示。

更多细节（工作原理、每个事件做什么、自检脚本）见[英文 README](README.md)。

## 许可证

[MIT](LICENSE)
