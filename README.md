# MacTR —— 利民 LCD 上的 AI Agent & 系统监控

[中文](README.md) · [English](README.en.md)

把利民 CPU 散热器上的 1920×480 LCD 变成一块实时仪表盘,既显示 Mac 的系统状态,**又能看到你的 AI 编程助手此刻在干什么** —— 全部原生运行于 macOS,无需 Windows。

![真机实拍](img/photo.jpg)

<sub>装在利民 Trofeo Vision 9.16 散热器上的实拍效果。</sub>

![仪表盘](img/dashboard.gif)

<sub>实时演示(假数据)。两个 agent 都在"工作"→ 面板呼吸、Bongo Cat 敲键盘、皮卡丘随 CPU 负载蹦跳放电、时钟走字。</sub>

> 基于 [beret21/MacTR](https://github.com/beret21/MacTR) 改造,核心是一块实时追踪
> [Claude Code](https://claude.com/claude-code)、[Codex](https://openai.com/codex)
> 会话以及 [OpenCode Zen](https://opencode.ai) / [Ollama](https://ollama.com) / [Antigravity](https://antigravity.google) 订阅额度的 **AI Agents** 面板。

## 亮点

### 🤖 AI Agents 面板
读取**本地**的 Claude Code / Codex 会话日志(只读),在配置 API Key 后读取 OpenCode Zen 与 Ollama Cloud 的用量,并从 Antigravity 正在运行的本地服务读取 Pro 额度,同屏显示 1–2 个 agent 的:

- **当前项目**和**它最后说的话** —— 消息里的 Markdown 表格会被渲染成对齐的表格,而不是原始的 `| … |` 文本。
- **计划 / 步骤进度** —— `步骤 4/6` 徽章 + 分段进度条,从 Codex 的 `update_plan` 和 Claude 的 `TodoWrite` 解析而来。上一轮已完成的旧计划会自动消失。
- **今日 Token 用量** —— 总量 + In/Out,用简洁的 `万 / 亿` 格式(Ollama 显示近 24 小时窗口;OpenCode 与 Antigravity 的接口不返回 token,显示 `—`)。
- **剩余额度** —— Claude(5 小时 / 7 天)与 Codex(5 小时 / 7 天)来自本地会话记录,OpenCode(滚动 / 周 / 月)来自其用量接口,Ollama(本月额度,或 legacy 套餐的会话 / 周)来自 `/api/balance`,Antigravity 的 5 个窗口(Gemini、Claude+GPT 各有 5 小时 + 周,加 Argon 周)来自其本地 language server;统一显示剩余百分比 + 重置时间。
- **实时状态** —— agent 工作时该栏**缓慢呼吸**,完成一轮或需要你输入时**闪烁**约 10 秒提醒。

### 🖥️ 系统面板
- **CPU** —— 占用率环形表、每核 P/E 柱状条、温度(经 IOHIDEventSystemClient,无需 sudo)、负载平均值。
- **内存** —— 按内存压力着色的占用环、Active/Wired/Compressed/Available 明细、整宽时钟、日期、开机时长、进程数。

### 🐱⚡ 会互动的桌宠
- **Bongo Cat**:agent 工作时在键盘上啪嗒啪嗒敲字,空闲时打盹。
- **皮卡丘**:CPU 负载越高电弧越猛;agent 运行时它还会蹦跳、左右转身。

### ⚙️ 底层
- **自适应帧率** —— 只有在有动画时(agent 工作、CPU 高负载)LCD 才跑约 15fps,其余时间降到 2fps 省电。
- **USB 热插拔** —— 插拔、睡眠/唤醒后自动重连。
- **本机预览** —— 没接 LCD 时改为渲染到窗口,方便无硬件开发调试。
- **菜单栏应用** —— 后台运行,无 Dock 图标。

## 硬件

| | |
|---|---|
| **产品** | [利民 Trofeo Vision 9.16 LCD](https://www.thermalright.com/product/trofeo-vision-9-16-lcd-black/) |
| **屏幕** | 9.16" IPS,1920 × 480 |
| **接口** | USB Type-C(USB 2.0) |
| **设备** | `0416:5408`(LY Bulk 协议) |

## 环境要求

- Apple Silicon Mac(M1–M5)
- macOS 15(Sequoia)或更新
- [Homebrew](https://brew.sh) 并安装 `libusb`
- 较新的 Swift 工具链(Xcode 16+,或经 Homebrew 的 Swift 6.1+)

## 构建与运行

```bash
brew install libusb pkg-config

git clone https://github.com/m1ng-li/mac-thermalright-ai-monitor.git
cd mac-thermalright-ai-monitor
export MACTR_BUILD_DIR="$HOME/build_dir/mac-thermalright-ai-monitor"
swift build --scratch-path "$MACTR_BUILD_DIR" -c release

"$MACTR_BUILD_DIR/release/MacTR"          # 菜单栏应用;驱动 LCD,或没接 LCD 时弹预览窗口
```

> 如果系统的 Command Line Tools 损坏、`swift build` 在解析包清单时报错,
> 装 Homebrew 的 Swift 工具链(`brew install swift`),改用
> `/opt/homebrew/opt/swift/bin/swift build --scratch-path "$MACTR_BUILD_DIR" -c release`。

### 开机(登录)自启

```bash
cp packaging/com.beret21.MacTR.plist ~/Library/LaunchAgents/   # 先改里面的路径
launchctl load -w ~/Library/LaunchAgents/com.beret21.MacTR.plist
```

## 运行模式

```bash
"$MACTR_BUILD_DIR/release/MacTR"                 # 菜单栏应用(有 LCD 走 LCD,没有则预览窗口)
"$MACTR_BUILD_DIR/release/MacTR" --preview       # 强制打开本机预览窗口
"$MACTR_BUILD_DIR/release/MacTR" --demo          # 用精美假数据驱动 LCD(方便拍照 / 展示)
"$MACTR_BUILD_DIR/release/MacTR" --snapshot x.png --cores 10        # 渲染一帧假数据到 PNG
"$MACTR_BUILD_DIR/release/MacTR" --gif x.gif --frames 48 --fps 12 --scale 2   # 生成演示 GIF
"$MACTR_BUILD_DIR/release/MacTR" --benchmark 120 # 测量 LCD 可达帧率
"$MACTR_BUILD_DIR/release/MacTR" --opencode-usage # 诊断:打印 OpenCode Key 状态与滚动/周/月三个窗口
"$MACTR_BUILD_DIR/release/MacTR" --ollama-usage   # 诊断:打印 Ollama Key 状态与实时额度 / 今天用量
"$MACTR_BUILD_DIR/release/MacTR" --ollama-parse balance|usage @body.json   # 离线校验解析器(不联网)
"$MACTR_BUILD_DIR/release/MacTR" --antigravity-usage   # 诊断:发现本地 language server 并读取 Antigravity 额度
"$MACTR_BUILD_DIR/release/MacTR" --antigravity-parse @body.json   # 离线校验额度解析器(不联网)
```

同一时刻只能有一个进程占用 USB 设备 —— 用 `--demo` / `--benchmark` 前先停掉正在运行的实例。

## Agent 数据怎么读取

除了下面这张表里的来源,MacTR 不访问任何网络或 API(本 fork 已移除 Sparkle 自动更新组件)。Claude / Codex 只读取它们本来就写到本地磁盘的会话记录;OpenCode 与 Ollama 的用量是**可选**的,只有在设置里填入各自的 API Key 后才会查询;Antigravity 的额度**只在本地**通过它自己的 language server 读取,不经过任何第三方服务。

| Agent | 来源 | 解析内容 |
|---|---|---|
| Claude Code | `~/.claude/projects/*/*.jsonl` | 助手消息、`usage` token、`TodoWrite` |
| Codex | `~/.codex/sessions/YYYY/MM/DD/*.jsonl` | agent 消息、`token_count`、`rate_limits`、`update_plan` |
| OpenCode | `GET https://opencode.ai/zen/go/v1/usage`(Bearer API Key,可选) | 滚动 / 周 / 月额度百分比与重置时间 |
| Ollama | `GET https://ollama.com/api/balance` + `/api/usage?range=24h`(Bearer API Key,可选) | 本月额度(或 legacy 会话/周)、今天(本地自然日)token / 请求数 / 花费 |
| Antigravity | 本地 language server `RetrieveUserQuotaSummary`(loopback Connect-RPC,需 IDE 运行) | Gemini / Claude+GPT / Argon 模型组的 5 小时 + 周额度与重置时间 |

Token 总量按本地自然日统计;某个 agent 今天还没跑过时,面板会优雅地显示它上一次会话的上下文。

### OpenCode 用量(可选)

1. 在 OpenCode Zen 控制台生成 API Key,打开 **设置 → Agents**,粘贴到 OpenCode 一栏,点「保存并测试」。
2. Key 不会以明文落盘:程序用 `MD5(本机随机 secret + 每次保存的随机 salt)` 派生 AES-128 密钥,把 Key 用 AES-GCM 加密后保存在本机偏好设置里,界面上只显示 Key 的 MD5 指纹(前 8 位)供你核对。这属于本机混淆级保护,能防"顺手看见",但不是抗本地攻击的强加密。
3. 配置后仪表盘每 60 秒查询一次额度;查询失败(Key 无效 / 断网 / 接口变更)会在该栏显示原因并自动重试,不影响其它面板。
4. 该接口只返回"状态 + 百分比 + 重置时间",因此 OpenCode 栏的「今日 Token」显示 `—`。清除 Key 后不再有任何网络请求。

### Ollama 用量(可选)

1. 在 [ollama.com/settings/keys](https://ollama.com/settings/keys) 生成 API Key,打开 **设置 → Agents**,粘贴到 Ollama 一栏,点「保存并测试」。
2. 加密方式与 OpenCode 完全一致(独立的随机 secret + salt → MD5 派生密钥 → AES-GCM),界面只显示 MD5 指纹前 8 位;清除后立即停止轮询。
3. 每 60 秒并发请求 `/api/balance` 与 `/api/usage?range=24h`(共 2 次/分钟,远低于官方 10 次/分钟的限流),遇到 429 会按 `Retry-After` 自动退避。
4. 额度按套餐形态自动适配:新的 credits 套餐显示「额度 剩余 %」(由 `balance_usd / allowance_usd` 换算)+ 本期重置时间;legacy 套餐显示「会话 / 周」两条。已购余额与今天的花费显示在活动行。
5. Token 统计口径是**本地自然日 00:00–24:00**:`/api/usage` 返回按小时分桶的数据,程序只汇总落在本地今天内的桶,因此该栏标题显示「今天 Token」。滚动 24 小时窗口总是覆盖今天至今,所以今天的桶不会缺失。

### Antigravity 用量(免配置)

1. **不需要任何 API Key**,也不需要登录信息:Antigravity 以 Google 账号登录,额度只对它自己的本地服务可见。MacTR 会找到正在运行的 `language_server` 进程,从它的启动参数取一次性 CSRF token,再向 `127.0.0.1` 上的 Connect-RPC `RetrieveUserQuotaSummary` 读取额度。
2. 卡片显示 **全部 5 个窗口**:`Gemini 5小时`、`Gemini 周`、`Claude/GPT 5小时`、`Claude/GPT 周`、`Argon 周`,每条都是剩余百分比 + 重置时间 + 进度条;竖屏紧凑卡用「密集行」样式(13 pt 标签 + 3 px 条)保证 5 行不越界。活动行显示模型组概览。
3. Antigravity 没运行时卡片显示「未运行」,不会发起任何请求;启动 IDE 后最多 60 秒自动恢复。刷新节奏为成功 60 秒 / 失败 15 秒。
4. 该接口只给百分比,没有 token 数,因此该栏不显示 Token 区块(OpenCode 同样处理),把空间留给额度和活动行。

### 仪表盘显示哪些 Agent

**设置 → Agents** 里勾选 Claude / Codex / OpenCode / Ollama / Antigravity,**最多同时显示 2 个**(已选满 2 个时其余选项会被禁用);布局方向仍在 **设置 → Display** 里切换。

## 隐私

除可选的 OpenCode / Ollama 用量查询外,一切都在本地、只读:无遥测、无第三方网络请求。Antigravity 的额度读取全程走 `127.0.0.1` 回环,不经过外网。外发请求只有两种,且各自以对应 agent 的 Key 作为 `Authorization: Bearer` 头,不发送任何本机数据:

- 配置 OpenCode Key 后,每 60 秒一次 `GET https://opencode.ai/zen/go/v1/usage`;
- 配置 Ollama Key 后,每 60 秒一次 `GET https://ollama.com/api/balance` 与一次 `GET https://ollama.com/api/usage?range=24h`。

不配置 Key 就完全没有对应的网络请求。Key 只保存在本机(加密方式见上文)。

## 致谢

- [beret21/MacTR](https://github.com/beret21/MacTR) —— 本项目所基于的原版 macOS 驱动
- [thermalright-trcc-linux](https://github.com/Lexonight1/thermalright-trcc-linux) —— LY Bulk 协议逆向
- [fermion-star/apple_sensors](https://github.com/fermion-star/apple_sensors) —— IOHIDEventSystemClient 温度读取
- [kuroni/bongocat-osu](https://github.com/kuroni/bongocat-osu) —— Bongo Cat 精灵图
- 皮卡丘立绘来自 [PokeAPI/sprites](https://github.com/PokeAPI/sprites) —— 宝可梦版权归 © 任天堂 / Creatures / GAME FREAK 所有,此处仅作装饰性致敬

> Bongo Cat 与皮卡丘纯属装饰。若你要分发构建产物,请注意它们的美术版权归各自所有者;
> 需要的话可替换或删除内嵌的 `BongoCatAsset.swift` / `PikachuAsset.swift`。

## 许可证

MIT(继承自上游项目)。第三方素材各自遵循其自身条款。

---

用 Swift + libusb 构建。与 [Claude Code](https://claude.com/claude-code) 协作开发。
