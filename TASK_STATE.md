# TASK_STATE

## 2026-11-12 接入 Ollama Cloud 用量（balance + usage 双接口）

- 完成内容：新增第 4 个 agent「Ollama」，走 `GET https://ollama.com/api/balance` 与 `GET https://ollama.com/api/usage?range=24h`（Bearer API Key，两者每 60 s 并发一次）；卡片显示额度剩余 % + 重置时间 + 近 24h Token / In / Out，活动行显示近 24h 花费、请求数与已购余额；设置页 Agents Tab 新增「Ollama Usage」录入区（状态 + MD5 指纹 + 保存并测试 / 清除）；同屏上限仍为 2（4 个 agent 任选 2）。版本 1.4.0 → 1.5.0。
- 关键决策：额度按套餐形态自适应——新 credits 套餐 1 行「额度」（`1 - balance_usd/allowance_usd`，重置取 `period.until`），legacy 套餐 2 行「会话 / 周」（`100 - remaining_percent`），两种行数都落在既有渲染分支（1 行 + Token、2 行 + Token），渲染器不新增布局；`allowance_usd = 0` / 缺字段 / 负余额分别退化为「剩余 --」/ nil / clamp 100%，不伪造数字；任一接口 200 即算成功（balance 503 时仍显示 Token，usage 失败时 Token 显示 `—`），401/403 视为账户级失败不保留伪数据；429 按 `Retry-After` 退避（下限 60 s、上限 600 s），失败间隔 30 s、单飞、revision 变更强制刷新、无 Key 零请求；Token 口径是滚动 24 h，故 `AgentUsage` 新增 `tokenWindowCaption`（默认 nil → 「今日 Token」），Ollama 传「近24h Token」，避免把 24 小时窗口谎称为自然日；Key 存储把 `OpenCodeKeyStore` 泛化为 `AgentKeyStore`（`APIKeyAgent` 命名空间 + 每 agent 独立 `kdf.secret`），OpenCode 原有 `opencode.apiKey.*` / `opencode.kdf.secret` 键名逐字节保留，无需迁移或重新输入。
- 修改文件：新增 `Sources/MacTR/Metrics/AgentKeyStore.swift`（替代并删除 `OpenCodeKeyStore.swift`）、新增 `Sources/MacTR/Metrics/OllamaUsageClient.swift`、`Sources/MacTR/Metrics/AgentUsageCollector.swift`、`Sources/MacTR/Rendering/DesignTokens.swift`（`Color.ollama` + `AgentKind.ollama`）、`Sources/MacTR/Rendering/MonitorRenderer.swift`、`Sources/MacTR/App/AppState.swift`、`Sources/MacTR/App/MacTRApp.swift`（`--ollama-usage` / `--ollama-parse` / `--ollama-key-selftest`，通用化 Key 自测）、`Sources/MacTR/UI/SettingsView.swift`（Agents Tab 双 Key 段落，窗口 500×560 → 500×680，状态与指纹合并一行以容纳 4 个开关）、`Sources/MacTR/Resources/Info.plist`、`README.md`、`README.en.md`、`TASK_STATE.md`。
- 验证结果：release 构建 + `codesign --verify --deep --strict` 通过，无新增 warning；解析夹具 11 组逐条核对（credits / legacy / 401 字符串 error 体 / 503 错误体 / allowance 0 / 负余额 clamp / 畸形 JSON；usage 标准 / 空 totals / 401 / 畸形）；实网探测：无 Key 不发请求、假 Key 返回「Key 无效（401）」、真实 Key 返回「✅ 已连通 · 额度剩余 100% · 近24h In 23.5M / Out 155K」，真实数据渲染显示「近24h $0.3054 · 216 次请求」「剩余 99% · 重置 12-12 09:44」；Ollama Key 加密往返一致、指纹与 `md5 -s` 一致、plist 零明文、自测后原值恢复；OpenCode 回归：selftest 往返 OK、实网「滚动剩余 98% / 周剩余 74% / 月剩余 87%」，claude+codex 像素布局不变（「今日 Token」标题走默认回落）；快照矩阵 1540×480 / 1920×480 / 519×1404 覆盖 ollama 单栏、ollama+opencode、ollama+claude、codex+ollama、claude+codex 回归及未配置态，无重叠越界；设置页实机截图确认 4 个开关全部可见、两个 Key 段落与指纹完整显示。

## 2026-11-09 接入 OpenCode 用量（API）与「最多同屏 2 个 Agent」

- 完成内容：OpenCode Zen 订阅额度（滚动 / 周 / 月）经 `GET https://opencode.ai/zen/go/v1/usage`（Bearer）接入 AI Agents 面板，复用 Claude/Codex 的卡片渲染（项目名、状态点、剩余百分比、重置时间、进度条）；设置页新增 **Agents** Tab：三个 agent 的显示开关（最多同屏 2 个）+ OpenCode API Key 录入 / 保存并测试 / 清除；Key 以 MD5 派生密钥 + AES-GCM 加密后存本机偏好设置，界面仅显示 MD5 指纹；未配置 Key 时零网络请求。
- 关键决策：MD5 单向不可逆，只存哈希会导致无法再调用 API，因此落地为「MD5(本机随机 secret‖每次保存的 salt) 派生 AES-128 密钥 → AES-GCM 加密存 payload」，UI 只暴露 MD5 指纹，README 明确标注这是本机混淆级保护而非抗本地攻击的强加密；用量接口只返回 status/percent/resetsAt，故 OpenCode 栏「今日 Token」统一渲染 `—` 而不伪造 0；额度恒输出 3 条（缺失窗口 usedPercent=nil）以免行数跳动，紧凑卡为 3 行额度新增「额度优先」分支（`!tokensAvailable || count >= 3`），Claude/Codex 现有像素布局保持不变；采集循环（约 2s）只做锁保护快照与节流判定（成功 60s / 失败 30s / 8s 超时 / 单飞），网络在 Task 内异步，绝不阻塞 metrics 队列；存储用 `UserDefaults(suiteName:)` 让 CLI 诊断与 GUI 共享同一域，当自身 bundle id 等于该域时改用 `.standard`，消除 macOS 的 "own bundle identifier as suite name" 警告；显示上限在 `AgentDisplayConfig.normalized` 强制裁剪到 2，设置页禁用第三个开关并禁止取消最后一个 agent；旧配置（`agentDisplay.showClaude/showCodex`）在 `agentDisplay.agents` 缺失时一次性迁移，保持用户既有视图。
- 修改文件：`Sources/MacTR/Metrics/AgentUsageCollector.swift`、新增 `Sources/MacTR/Metrics/OpenCodeKeyStore.swift`、`Sources/MacTR/Metrics/OpenCodeUsageClient.swift`、`Sources/MacTR/Rendering/DesignTokens.swift`、`Sources/MacTR/Rendering/MonitorRenderer.swift`、`Sources/MacTR/App/AppState.swift`、`Sources/MacTR/App/MacTRApp.swift`（新增 `--opencode-usage` / `--opencode-parse` / `--opencode-key-selftest` 诊断）、`Sources/MacTR/UI/SettingsView.swift`、`Sources/MacTR/Resources/Info.plist`（1.3.11 → 1.4.0）、`README.md`、`README.en.md`、`TASK_STATE.md`。
- 验证结果：release 构建与 `codesign --verify --deep --strict` 通过，`git diff --check` / `plutil -lint` / `bash -n` 通过，新增代码零 warning（仅既有 BongoCat/Pikachu 与 libusb link 警告）；解析器 6 组夹具（标准三窗口 / legacy `windows[]` / 401 错误体 / 空 JSON / percent 150 / 缺 resetsAt）逐条核对通过；真实网络下假 Key 返回「Key 无效（401）」，用户本机真 Key 返回「滚动剩余 97% / 周剩余 99% / 月剩余 100%」；加密往返读写一致、指纹与 `md5 -s` 一致、偏好设置二进制中零处明文 `sk-`、自测后原值自动恢复；快照（1540×480、1920×480、519×1404）覆盖 opencode 单栏、claude+opencode、codex+opencode 横纵、claude+codex 回归、三 agent 裁剪到 2 以及真实数据预览，均无重叠或越界，Claude/Codex 卡片与改动前一致；设置页实机截图确认 Agents Tab（Codex/OpenCode 开、Claude 禁用、2/2 提示、已配置状态与 MD5 指纹 b0b845a2…、清除按钮与加密说明）完整显示。
- 未解决问题：`/Applications/MacTR.app` 未替换（会覆盖现有安装，待用户确认）；未接 Thermalright LCD 做真机回归；OpenCode 成功路径目前只在用户本机 Key 上验证过一次。

## 2026-09-01 Codex 预留 5 小时并同时显示双额度

- 完成内容：Codex 与 Claude 一样固定输出“5 小时”和“7 天”两项额度；当前 Pro 事件不含 5 小时窗口时显示“5 小时剩余 --”，保留 7 天实时百分比和重置时间。
- 兼容决策：同时解析标准 `limit_id=codex` 事件的 `primary`/`secondary`，按 `window_minutes` 归类 300 分钟和 10080 分钟窗口，不假设两个字段的固定顺序；切换到会写入 5 小时窗口的套餐后将自动填入真实值。
- 修改文件：`Sources/MacTR/Metrics/AgentUsageCollector.swift`、`Sources/MacTR/Rendering/MonitorRenderer.swift`、`TASK_STATE.md`。
- 验证结果：本机当前 `prolite` 标准事件为 `primary.window_minutes=10080`、`secondary=null`；release 构建、严格签名、横向/纵向真实快照均通过，截图显示 Codex“5 小时剩余 --”和“7 天剩余 60%”；当前账号尚无 Plus 双窗口事件，因此未宣称完成真实 Plus 套餐回归。
- 发布结果：新版已发布至 `/Applications/MacTR.app` 并启动，构建与安装二进制 SHA-256 均为 `fbf6c6674672ae14c1e33edfa7398787147890035b85abecc5c518c09b912650`，System Events 回读窗口为 `MacTR Preview`；替换前版本保留为 `/Applications/MacTR-backup-20260901-161400.app`。

## 2026-09-01 Claude 同时显示 5 小时与 7 天额度

- 完成内容：将 Agent 额度模型从单一窗口扩展为有序额度列表；Claude 固定同时提供“5 小时”和“7 天”两项，Codex 保持现有单项标准额度。横向大卡片和纵向紧凑卡片均显示每项的剩余百分比、重置信息与独立进度条。
- 布局决策：纵向紧凑 Claude 卡片用原活动文本空间容纳第二条额度，保留项目名、计划步骤徽标和今日 Token，避免在固定卡片高度内重叠。
- 修改文件：`Sources/MacTR/Metrics/AgentUsageCollector.swift`、`Sources/MacTR/Rendering/MonitorRenderer.swift`、`TASK_STATE.md`。
- 验证结果：`MACTR_BUILD_DIR=/Users/sunbowei/build_dir/mac-thermalright-ai-monitor ./script/build_and_run.sh build` 完成 release 构建并通过严格签名校验；真实本地 Claude 数据的横向/纵向快照均同时显示“5 小时剩余 94%”与“7 天剩余 67%”；成品已发布至 `/Applications/MacTR.app` 并启动，进程可执行文件与构建成品 SHA-256 均为 `d7d3d436845bc6074ce81ac0adb74f4e40bf59e8fa7e85afdc3ae47563b8fa81`，System Events 回读窗口为 `MacTR Preview`。
- 回滚保护：替换前的安装包保留为 `/Applications/MacTR-backup-20260901-161200.app`。

## 2026-09-01 构建、发布并启动回修版

- 完成内容：通过项目统一入口重新构建 release App，将签名后的成品发布到 `/Applications/MacTR.app`，停止仓库 `dist` 旧实例并从正式安装路径启动。
- 发布回滚：被替换的旧安装包保留为 `/Applications/MacTR-backup-20260901-135102.app`，未做不可恢复删除。
- 验证结果：构建、plist lint、staging 与发布后两次 `codesign --verify --deep --strict` 均通过；源包、staging 和正式安装包的 MacTR 二进制 SHA-256 均为 `3dfc8864f03ea42e198c285def6cd48b0f2e4b75349523c6af52c5ce8db72251`；正式实例 PID 73616 持续运行自 `/Applications/MacTR.app/Contents/MacOS/MacTR`，System Events 回读 `visible=true`、窗口数 1、窗口名 `MacTR Preview`。

## 2026-09-01 回修 JPEG 质量、Codex 配额与断连预览

- 完成内容：JPEG 成功编码且体积低于上限 80% 时，将同输出配置的记忆质量上调 0.05，最高恢复到 0.9；恢复 Codex 标准额度时间戳的进程生命周期高水位，仅接受严格更新的读数，避免 3 天文件缓存裁剪后回退；LCD 帧循环未运行时，预览直接渲染新帧，不再以 0.5 秒同节拍缓存跳帧；AppleSMC 首次打开失败后进行负缓存，避免无可用服务的机器每 tick 重试。
- 关键决策：LCD 已连接时仍复用其新鲜帧以保留 CPU 优化，只有断连预览绕过缓存；历史会话目录缓存继续使用 `contentsOfDirectory(at:includingPropertiesForKeys:)` 批量元数据读取，并明确记录“若 Codex 未来 resume 旧会话文件，缓存必须失效或移除”的前提。
- 修改文件：`Sources/MacTR/Rendering/FrameRenderer.swift`、`Sources/MacTR/Metrics/AgentUsageCollector.swift`、`Sources/MacTR/App/AppState.swift`、`Sources/MacTR/Metrics/SystemMetricsCollector.swift`、`TASK_STATE.md`。
- 未解决问题：当前仍未连接 Thermalright LCD，连接态预览/LCD 共用帧和真实 USB 发送未做硬件回归。
- 验证结果：`MACTR_BUILD_DIR=/Users/sunbowei/build_dir/mac-thermalright-ai-monitor ./script/build_and_run.sh build` 完成 release 构建并通过 app 严格签名校验；JPEG 定向 smoke 中复杂帧压缩到 75,733 字节后，10 个富余帧从 23,360、28,436、32,186 逐步增长到 70,656 字节，证明质量记忆会回升；`bash -n script/build_and_run.sh` 与 `git diff --check` 通过。构建仅保留既有资源 `nonisolated(unsafe)` 和 Homebrew libusb macOS 26 link warning。

## 2026-09-01 完成 14 项 CPU、I/O、更新与 USB 优化

- 完成内容：将完全静态的渐变背景和三块面板外壳预渲染为布局级 CGImage；缓存最近渲染帧并在一个 LCD 帧间隔内供预览复用；把 GUI/独立预览绘制移到串行后台队列；复用三个固定格式的 `DateFormatter`；缓存少量代表性 HID 温度 service；为 SMC GPU key 增加命中缓存和连续 3 次全量失败后的负缓存；将 Agent 会话枚举改为 URL resource 批量元数据并缓存两天前目录；将 Claude/Codex 配额尾扫缩到 256KB 并按 size+mtime 跳过未变文件；把高频 JSONL 预筛改为字节匹配/字面量匹配；合并同一 Codex 会话的 activity/plan 尾读；移除 Sparkle 依赖、上游 feed、公钥和菜单入口；移除菜单栏 1 秒无条件刷新；修正 USB 写偏移并复用单一发送缓冲；JPEG 从同配置上一帧成功质量开始编码。
- 关键决策：保留既有 10 FPS 动画/2 FPS 空闲调度和跨午夜会话正确性，因此今天、昨天目录仍实时枚举，只有两天前目录视为不可变；HID 优先 `PMU tdie`/GPU 代表传感器并保留两个 fallback；无自有可信 appcast 时直接移除 Sparkle，确保 README 的“无网络请求”重新成立。
- 修改文件：`Package.swift`、中英文 README、`Sources/CThermalSensor/ThermalSensor.m`、App/Rendering/Metrics/USB 相关 Swift、`Sources/MacTR/Resources/Info.plist`、`script/build_and_run.sh`、`TASK_STATE.md`。
- 未解决问题：当前没有连接 Thermalright LCD，真实握手、分批 bulk write/ACK 和端到端 LCD JPEG 帧率仍需接硬件后运行 `--benchmark`；系统 Homebrew libusb 的 macOS 26 link warning 仍存在，但打包继续优先嵌入既有 macOS 15 vendored dylib。
- 验证结果：release 构建、`bash -n`、plist lint、`git diff --check`、Sparkle URL/符号/框架缺失检查和 `codesign --verify --deep --strict` 通过；真实本地数据与 quota/activity 初次解析成功，1920×480 snapshot 目检正常；同尺寸 10 FPS 渲染循环实测 5.6%/7.1% CPU，正常可见预览五次采样为 0.0/3.7/0.0/5.9/4.8%，相较修改前 14.8% 基线显著下降；稳态 5 秒 sample 中未出现渐变重画、`attributesOfItem`、GPU SMC 调用或 HID Product 查询，`readThermalSensors` 仅 2 个采样；Thread Sanitizer snapshot 无 race 报告；强制触发 JPEG 质量递减的 smoke benchmark 从首帧 38.79ms 降到同输出第二帧 1.68ms。

## 2026-08-12 交付 Dock 应用、启动预览与 App 图标

- 完成内容：将 MacTR 从仅菜单栏的 accessory 激活策略改为普通 Dock 应用；GUI 每次启动时立即显示 `MacTR Preview` 主窗口，不再受旧的断连自动预览偏好影响；新增 MacTR 专用 PNG/ICNS 图标和可重复的自包含 App 构建入口。
- 关键决策：预览窗口现在是正常 GUI 启动窗口；用户手动关闭后当次运行保持关闭，下次启动再显示。构建脚本把 Sparkle、AppIcon 和 macOS 15 版 `libusb` 封装进 App，并执行本地 ad-hoc 签名校验。
- 修改文件：`.gitignore`、`Package.swift`、`Sources/MacTR/App/MacTRApp.swift`、`Sources/MacTR/Resources/Info.plist`、`Sources/MacTR/Resources/AppIcon-1024.png`、`Sources/MacTR/Resources/AppIcon.icns`、`script/build_and_run.sh`。
- 未解决问题：App 仅作本地 ad-hoc 签名，未使用 Developer ID 或执行 Apple 公证；发行给其他用户时仍需正式签名与 notarization。
- 验证结果：`swift build -c release`、`bash -n script/build_and_run.sh`、`git diff --check` 和 `codesign --verify --deep --strict` 通过；实际启动 `/Users/sunbowei/Applications/MacTR.app` 后，系统返回 `activation_policy=0` (`regular`)、进程可见、窗口数为 1、`AXMain=true`、`AXMinimized=false`、窗口尺寸 `770x272`；在 `autoShowPreviewWhenLCDDisconnected=false` 时仍会自动显示启动窗口。

## 2026-08-03 提交并推送 MacTR 关闭行为修复

- 完成内容：将预览永久关闭、退出不重启、额度采集改动、构建启动入口和任务状态提交并推送到用户 fork。
- 关键决策：保留 `origin` 上游远端不变，使用已有 `fork` 远端 `iBobbySun/mac-thermalright-ai-monitor` 的 `main` 分支交付；不 force-push，不改写上游历史。
- 修改文件：
  - `TASK_STATE.md`
- 未解决问题：`origin/main` 仍比本地落后 5 个提交，这是上游远端未同步 fork 内容的正常状态；本次没有向上游直接推送。
- 验证结果：提交 `02af29b3e41986cf5a17f2aed9789db7a1bdb964` 已创建；`git push fork main` 成功；`git ls-remote fork refs/heads/main` 回读到同一提交；工作区提交前无未暂存业务改动。

## 2026-08-03 完成 MacTR 永久关闭验证

- 完成内容：完成预览自动显示的持久化关闭、菜单恢复开关、SwiftPM `.app` 构建入口，并卸载当前 `com.mactr.manual` `launchd` 常驻服务。
- 关键决策：关闭预览窗口会将自动预览偏好保存为关闭；“Preview Window”仍可手动打开；当前服务属于外部 `launchctl submit` 实例，直接卸载该精确服务，不修改用户其他 LaunchAgent。
- 修改文件：
  - `Sources/MacTR/App/MacTRApp.swift`
  - `script/build_and_run.sh`
  - `.codex/environments/environment.toml`
  - `TASK_STATE.md`
- 未解决问题：未对真实 Thermalright LCD 连接/断开做硬件实测；如果未来有其他工具重新提交新的 `KeepAlive` 服务，仍需卸载那个新服务。工作区原有的 `Sources/MacTR/Metrics/AgentUsageCollector.swift` 改动未触碰。
- 验证结果：`bash -n script/build_and_run.sh` 通过；`./script/build_and_run.sh --verify` 成功构建并启动 `dist/MacTR.app`；已补齐 Sparkle framework 并通过 `plutil -lint`；正常发送 AppleScript Quit 后进程消失，且 `launchctl list` 不再有 MacTR 匹配项；`git diff --check` 通过。构建仅保留既有 Info.plist、素材 `nonisolated(unsafe)` 和 libusb deployment-target warning。

## 2026-08-03 实现预览永久关闭与正常退出

- 完成内容：新增“Auto Preview When LCD Is Disconnected”持久化开关；用户关闭预览窗口后自动关闭该策略，应用重启或设备状态变化时不再自动打开；菜单仍可手动重新开启或单独打开预览窗口。
- 关键决策：默认保持原行为（首次运行仍自动预览），关闭窗口后将偏好写入 `UserDefaults`；仅改变自动显示策略，不删除手动 `Preview Window` 功能。按 macOS 构建规范新增统一的本地构建/启动入口。
- 修改文件：
  - `Sources/MacTR/App/MacTRApp.swift`
  - `script/build_and_run.sh`
  - `.codex/environments/environment.toml`
  - `TASK_STATE.md`
- 未解决问题：当前已加载的 `com.mactr.manual` `launchd` 常驻服务尚未卸载；在完成构建验证前，退出旧实例仍可能被该外部服务重新拉起。
- 验证结果：已完成源码和本地运行入口修改；待执行 `bash -n`、`swift build -c release`、启动检查，以及卸载 `com.mactr.manual` 后的退出验证。

## 2026-08-03 诊断关闭后 MacTR 自动重新打开

- 完成内容：检查当前 MacTR 进程父进程、`launchctl` 托管状态、打包启动配置，以及关闭/预览窗口代码路径，确认自动重新打开的两个来源。
- 关键决策：将“退出整个 MacTR 后被重新拉起”和“只关闭本机预览窗口后再次出现”分开判断；本次仅诊断，不卸载或修改现有启动服务，也不覆盖工作区已有改动。
- 修改文件：
  - `TASK_STATE.md`
- 未解决问题：当前实际加载的是由 `launchctl submit` 提交的 `com.mactr.manual` 服务，不是仓库中的 `packaging/com.beret21.MacTR.plist`；若要彻底停止自动拉起，需要后续明确执行该服务的卸载/禁用。LCD 未连接时的自动预览是否保留，也需要按用户意图决定。
- 验证结果：`launchctl print gui/502/com.mactr.manual` 显示程序为 `.build/release/MacTR`、`properties = keepalive | inferred program`、`runs = 6`、`last exit code = 0`、当前 PID 的 PPID 为 1；源码中 `Quit MacTR` 使用 `NSApp.terminate(nil)`，因此正常退出后仍被外部 `launchd` 服务拉起。另确认 `StatusBarController` 在 LCD 未连接时会在启动后约 2 秒调用 `showPreview()`，设备状态变化时也会再次调用；关闭预览窗口只停止定时器，不会解除该自动预览策略。未修改 `Sources/MacTR/App/MacTRApp.swift` 或其他业务源码。

## 2026-07-31 复核 Codex 与 bengalfox 额度池差异

- 完成内容：只读检查本机 Codex app-server 协议、二进制字符串、本地配置/功能缓存，以及当前 session 的模型和 rate-limit 元数据，分析 `limit_id=codex` 与 `limit_id=codex_bengalfox` 的关系及持续返回后者的原因。
- 关键决策：区分已确认事实与推断；已确认两者是服务端同时返回的独立 metered bucket，标准软件 Usage 使用 `codex`，而 `bengalfox` 没有本地开关或公开名称定义。当前持续返回后者推断为服务端对任务/账号的实验或产品路由，不能把内部代号武断映射为具体套餐、免费额度或模型。
- 修改文件：
  - `TASK_STATE.md`
- 未解决问题：OpenAI 官方公开资料未说明 `codex_bengalfox` 的业务含义、分配规则和退出条件；本地无法确定它是否免费、是否影响标准额度、何时切回 `codex`。只能等待服务端后续事件或官方说明。
- 验证结果：本机 app-server 多 bucket 快照曾同时包含 `codex` 和 `codex_bengalfox`；标准 `codex` 最后事件为 `2026-07-31T01:51:39.019Z`、已用 19%、固定 7 天窗口重置时间，`bengalfox` 随后持续返回 0%、7 天窗口且重置时间随请求滚动；切换前后 session 的模型均为 `gpt-5.6-sol`、来源均为 Codex Desktop；`~/.codex/config.toml`、Codex feature cache/Preferences 和本机 Codex 二进制中均未发现 `bengalfox` 配置字符串。

## 2026-07-31 复核 JSONL 额度与 Codex 软件差异

- 完成内容：只读核对最近 4 天 session JSONL 中各额度池的最后事件，确认 MacTR 显示 81% 而 Codex 软件显示 78% 的原因。
- 关键决策：本次不调用 app-server、不修改业务代码；纯本地模式只能展示最后写入 JSONL 的标准 `codex` 额度，不能从 Token 数量可靠推算实时额度。
- 修改文件：
  - `TASK_STATE.md`
- 未解决问题：标准 `codex` 额度事件停止写入后，本地显示会持续滞后；提高扫描频率无法解决源数据没有更新的问题。可后续在界面增加“最后更新时间”或过期标识，避免把旧值理解为实时值。
- 验证结果：标准 `limit_id=codex` 最后事件为 `2026-07-31T01:51:39.019Z`、`used_percent=19`、剩余 81%；之后到 `2026-07-31T02:42:05.097Z` 只继续写入 `limit_id=codex_bengalfox`、`used_percent=0`。约 50 分钟内缺少新的标准额度事件，与 Codex 软件已变化到剩余 78% 的现象吻合。

## 2026-07-31 切换 Codex 额度为纯本地 JSONL

- 完成内容：彻底移除 Codex app-server、`Process`、`Pipe`、协议轮询和网络额度读取；额度只扫描本机 session JSONL 中最新的标准 `limit_id=codex` 记录，并将扫描频率降为每 5 分钟一次。
- 关键决策：用户明确接受额度滞后，优先保证低系统开销和长期稳定；刷新节流不再依赖是否已有 cache，因此即使本地没有额度记录也不会高频重试；继续排除 `codex_bengalfox` 等独立额度池。
- 修改文件：
  - `Sources/MacTR/Metrics/AgentUsageCollector.swift`
  - `TASK_STATE.md`
- 未解决问题：JSONL 不是实时额度源，当前最后标准记录仍为已用 19%、剩余 81%，可能落后于 Codex UI；只有新的标准 `codex` rate-limit 事件写入本地日志后才会更新。
- 验证结果：`swift build -c release` 通过；源码和 release 二进制均不再包含 `app-server`、`account/rateLimits/read`、`Process`、`Pipe` 或 Darwin 轮询逻辑；无模拟参数生成 `/tmp/mactr-codex-jsonl-only.png`，目检显示 JSONL 最后记录“剩余额度 81%”；当前 release 已重启为 PID 67242、PPID 1，没有直接子进程；运行约 80 秒后 `vmmap` physical footprint 为 35.6 MiB，初次本地扫描峰值 105.6 MiB 已释放。

## 2026-07-31 Codex 实时额度资源开销审计

- 完成内容：审查 app-server 实时额度查询的进程、pipe、超时和回收路径；跨 3 个刷新周期采样 MacTR 与直接子进程；两次执行 `leaks` 并检查 heap、vmmap、zombie 和残留子进程。
- 关键决策：本次仅做审计，不修改业务代码；正常成功路径没有累积内存泄漏，但当前每 60 秒启动一次完整 Codex app-server 的瞬时开销偏高，且发现两个异常路径风险，需要后续修正节流条件和有界终止。
- 修改文件：
  - `TASK_STATE.md`
- 未解决问题：本条发现的子进程重试风暴、无界退出等待和每分钟 app-server 开销，已由上方“切换 Codex 额度为纯本地 JSONL”里程碑通过移除整个接口读取路径解决。
- 验证结果：190 秒共捕获 3 次 Codex 子进程，间隔约 62 秒，每次存活约 1-4 秒、峰值 RSS 约 80.7-82.7 MiB、CPU 峰值 6.5%-17.3%，无 zombie；MacTR 父进程 RSS 在采样期从起点下降约 4.7 MiB，未增长，平均 CPU 约 32.3%（主要来自既有 LCD 渲染/发送循环）；`vmmap` 显示当前 physical footprint 32.5 MiB、峰值 88.6 MiB、malloc heap 约 9.6 MiB；heap 中无存活 `NSTask`/`NSPipe`，`NSConcreteData` 仅 59 个约 1.8 KiB；两次 `leaks` 均为 287 个、14,320 bytes，内容是系统 AppIntents/XPC 循环，跨刷新周期没有增加。

## 2026-07-31 接入 Codex 实时动态额度

- 完成内容：将 Codex 额度主数据源从 session JSONL 改为 Codex app-server 正式接口 `account/rateLimits/read`；每 60 秒读取 `rateLimitsByLimitId.codex.primary` 并动态计算剩余额度，接口不可用且没有实时缓存时才回退到 JSONL；重新构建并重启当前 release 实例。
- 关键决策：81% 不是固定值，而是旧 JSONL 中 `used_percent=19` 的当时结果，但该记录会滞后；实时接口返回多额度池快照，因此明确选择标准 `codex` bucket，不使用 `codex_bengalfox`，也不在源码中保存任何固定百分比。Codex 子进程按次启动，读取完成即退出，避免常驻额外服务。
- 修改文件：
  - `Sources/MacTR/Metrics/AgentUsageCollector.swift`
  - `TASK_STATE.md`
- 未解决问题：本条 app-server 实时读取方案已被上方“切换 Codex 额度为纯本地 JSONL”里程碑完整移除，不再是当前运行实现。
- 验证结果：`swift build -c release` 通过；正式接口在截图显示 80% 后读取到 `usedPercent=21`、剩余 79%、`resetsAt=1785906380`，说明额度已随使用动态变化；无模拟参数生成 `/tmp/mactr-codex-live-quota.png`，目检显示“剩余额度 79%”，与紧邻接口读数一致；当前 release 已由 `launchd` 重启为 PID 61434、PPID 1，跨过完整刷新周期运行约 2 分 25 秒后 RSS 约 80.4 MiB，查询完成后无残留子进程。

## 2026-07-31 修复 Codex 多额度池误覆盖

- 完成内容：额度扫描在比较时间戳前过滤非标准 `rate_limits.limit_id`，只使用普通 `codex` 限额池，同时兼容旧日志中缺少 `limit_id` 的记录；重新构建 release，并替换当前运行实例。
- 关键决策：不按所有额度池的全局最新时间直接覆盖缓存；`codex_bengalfox` 等独立池不代表界面所需的账号标准额度，因此跳过，缺少 ID 的旧格式仍按标准额度处理。
- 修改文件：
  - `Sources/MacTR/Metrics/AgentUsageCollector.swift`
  - `TASK_STATE.md`
- 未解决问题：本条解决了额度池误覆盖，但 JSONL 仍可能滞后；用户已在上方“切换 Codex 额度为纯本地 JSONL”里程碑明确接受该取舍。release 构建的既有 Info.plist、素材 `nonisolated(unsafe)` 和 libusb deployment target warning 未在本次处理。
- 验证结果：`swift build -c release` 通过；无模拟参数生成 `/tmp/mactr-codex-quota-fix-real.png`，目检确认显示“剩余额度 81%”；带 `--cores` 的快照会使用硬编码模拟额度，已排除为验证干扰；旧 PID 52661 已正常停止，新 release 由 `launchd` 托管，PID 57297、PPID 1，并持续驻留运行。

## 2026-07-31 Codex 剩余额度误显示 100% 诊断

- 完成内容：核对当前运行中的 release 进程、Codex 最近会话内的脱敏 rate-limit 数值，以及 MacTR 的额度选择和渲染逻辑，定位剩余额度 100% 与实际 81% 不一致的原因。
- 关键决策：本次仅回答原因，不修改业务代码；根因是 `updateCodexQuota()` 只按事件时间戳选择最新额度，没有区分 `rate_limits.limit_id`，导致普通 `codex` 额度被时间更新的 `codex_bengalfox` 独立额度池覆盖。
- 修改文件：
  - `TASK_STATE.md`
- 未解决问题：本条诊断发现的多额度池误覆盖已由上方“修复 Codex 多额度池误覆盖”里程碑解决。
- 验证结果：普通 `codex` 最新事件为 `2026-07-31T01:51:39.019Z`、`used_percent=19`、剩余 81%；`codex_bengalfox` 后续事件为 `2026-07-31T02:02:27.257Z`、`used_percent=0`；当前 `.build/release/MacTR` 进程 PID 52661 已运行约 3 分钟；源码按最新时间戳缓存后执行 `100 - used`，与误显示 100% 完全吻合。

## 2026-07-31 提交并推送内存修复

- 完成内容：将内存增长、生命周期竞态、USB/SMC 资源释放及此前预览标题栏调整提交为 `0cf667b`；在本地新增 `fork` 远端，并将 `main` 推送到 `iBobbySun/mac-thermalright-ai-monitor`。
- 关键决策：保留 `origin` 指向上游 `m1ng-li/mac-thermalright-ai-monitor`；由于当前 GitHub 账号 `iBobbySun` 对上游没有写权限，不改写上游远端，而是使用已有 fork 完成交付。
- 修改文件：
  - `TASK_STATE.md`
- 未解决问题：`origin/main` 无法由当前账号直接推送，GitHub 返回 HTTP 403；需要上游维护者授权或通过 fork 发起 Pull Request 才能进入上游仓库。
- 验证结果：功能提交 `0cf667b` 创建成功；`git push fork main` 成功；`git ls-remote fork refs/heads/main` 读回 `0cf667b1e4e72fa57024cfae3c0e29f2d2740fbe`，与本地功能提交一致。

## 2026-07-31 修复 MacTR 长期内存增长与资源竞态

- 完成内容：为指标采集启动阶段和每轮循环增加短生命周期 `autoreleasepool`；使用 generation 和锁保护指标循环的 stop/start 生命周期；将 DisplayEngine 的运行标志和渲染设置改为锁保护快照，并修正系统唤醒时 USB 队列无法退出帧循环的问题；USB hotplug 现保存并释放两组 VID/PID 的全部 notification iterator；指标采集器析构时关闭 SMC connection。
- 关键决策：保持 Agent JSONL 采集、预览窗口和 LCD 渲染功能不变，仅修复对象释放边界、并发状态所有权和 IOKit 资源生命周期；保留此前未提交的预览标题栏 UI 修改，不覆盖或回退用户现有变更。
- 修改文件：
  - `Sources/MacTR/Rendering/MonitorRenderer.swift`
  - `Sources/MacTR/App/AppState.swift`
  - `Sources/MacTR/USB/USBHotplug.swift`
  - `Sources/MacTR/Metrics/SystemMetricsCollector.swift`
  - `TASK_STATE.md`
- 未解决问题：当前没有连接 Thermalright LCD，USB 插拔回调和真实设备睡眠唤醒重连未做硬件实测；包内没有 XCTest target。项目仍有既有构建 warning（未声明的 Info.plist resource、素材 `nonisolated(unsafe)` 和 libusb deployment target），与本次修复无关。
- 验证结果：普通 `swift build` 通过；`swift build --sanitize thread` 通过，Thread Sanitizer 运行约 60 秒无数据竞争报告；修复后正常 App 运行约 3 分钟 physical footprint 在 33-42 MiB 间波动，最终约 37.7 MiB、堆总量约 10.1 MiB，未修版同场景约 6 分钟曾增长至 263.2 MiB；`leaks` 仅剩约 9.38 KiB 的系统 AppIntents/XPC 项；快照生成成功且尺寸为 `519x1404`；`git diff --check` 通过；测试进程均已停止。

## 2026-07-31 MacTR 长期内存增长与系统重启诊断

- 完成内容：结合 2026-07-31 的 panic/Jetsam 诊断、当前源码审查和本机动态堆采样，复现并定位 `MacTR` 的持续内存增长；在临时 Git worktree 中验证最小修复后已清理测试进程和临时 worktree。
- 关键决策：根因判定为 `MonitorRenderer.metricsLoop()` 的长生命周期 GCD 闭包没有按轮次建立 `autoreleasepool`；`AgentUsageCollector` 每约 2 秒读取并解析 Claude/Codex JSONL，产生的 `NSData`、`CFString`、`NSDictionary` 和 `_NSJSONReader` 临时对象直到采集循环退出才释放。`leaks` 只报告约 14 KiB 的系统 AppIntents/XPC 循环，因此传统强引用泄露不是本次几十 GiB 增长的主因。此次请求为诊断，未直接修改正式源码。
- 修改文件：
  - `TASK_STATE.md`
- 未解决问题：本条诊断当时发现的 `autoreleasepool`、跨线程状态和 USB iterator 问题，已由上方“修复 MacTR 长期内存增长与资源竞态”里程碑解决。
- 验证结果：Jetsam 中 `MacTR` UUID `BC98B777-A597-33C8-BD29-ED4573B91849` 与当前 `.build/release/MacTR` 一致；panic 时 `MacTR` 常驻内存约 27.5 GiB。未修版动态测试约 6 分钟内 physical footprint 从 40.1 MiB 增至 263.2 MiB，堆中 `NSConcreteData` 约 200.5 MiB、`CFString (Storage)` 约 23.4 MiB、`_NSJSONReader` 4,748 个；仅在临时副本为 `metricsLoop()` 单轮加入 `autoreleasepool` 后，约 4 分钟 physical footprint 稳定在 35-37 MiB，堆总量约 10.4 MiB。`swift build` 通过；测试进程与临时 worktree 已清理。

## 2026-07-30 移除预览窗口标题栏置顶复选框

- 完成内容：移除预览窗口标题栏右上角的“置顶”复选框；`--preview` 独立预览窗口和菜单栏 App 的自动/手动预览窗口都不再添加标题栏附件控件。
- 关键决策：保留既有 `UserDefaults` 置顶状态和菜单栏 `Always on Top` 菜单项，避免删除置顶能力本身；本次仅移除窗口标题栏 UI。
- 修改文件：
  - `Sources/MacTR/App/MacTRApp.swift`
  - `TASK_STATE.md`
- 未解决问题：项目仍有与本次 UI 调整无关的既有构建 warning（Info.plist resource 声明、素材文件 `nonisolated(unsafe)`、libusb deployment target 提示），本次未处理。
- 验证结果：`swift build` 通过；`git diff --check` 通过；已用 `rg` 确认 `MacTRApp.swift` 中不再存在标题栏置顶按钮创建/同步逻辑。

## 2026-07-24 移除 CPU/Memory 装饰显示

- 完成内容：移除 CPU 面板中的皮卡丘渲染；移除 Memory 面板中的 Bongo Cat/小猫渲染，并将底部日期与系统信息左移填补空位；移除不再需要的 CPU 高负载动画帧率触发。
- 关键决策：仅调整显示层，不删除内嵌素材文件，避免扩大改动范围；Memory 底部保留日期/系统信息与时钟，不留原小猫占位。
- 修改文件：
  - `Sources/MacTR/Rendering/MonitorRenderer.swift`
  - `TASK_STATE.md`
- 未解决问题：项目仍有与本次显示调整无关的构建 warning（Info.plist resource 声明、素材文件 `nonisolated(unsafe)` 提示、libusb deployment target 提示），本次未处理。
- 验证结果：`swift build` 通过；`git diff --check` 通过；已用 `.build/debug/MacTR --snapshot /tmp/mactr-no-decorations.png --cores 10` 生成并目检快照，确认 CPU 区域无皮卡丘、Memory 区域无小猫。

## 2026-07-24 预览窗口始终置顶开关

- 完成内容：为本机预览窗口增加始终置顶开关；`--preview` 独立预览窗口和菜单栏 App 的自动/手动预览窗口共用同一开关状态。
- 关键决策：使用 `NSWindow.Level.floating` 实现置顶，用 `UserDefaults` 保存开关状态；窗口标题栏提供“置顶”复选框，菜单栏提供 `Always on Top` 菜单项。
- 修改文件：
  - `Sources/MacTR/App/MacTRApp.swift`
  - `TASK_STATE.md`
- 未解决问题：项目仍有与本次置顶功能无关的构建 warning（素材文件 `nonisolated(unsafe)`、既有 AppKit actor 提示、libusb deployment target 提示），本次未处理。
- 验证结果：`swift build` 通过；`git diff --check` 通过。

## 2026-07-24 Agent 显示配置化与横纵布局

- 完成内容：新增 Claude/Codex 显示配置，默认只显示 Codex；新增 Agent 横向/纵向布局配置；单 Agent 或纵向布局时缩短整体画布/预览窗口宽度；设置变更后已打开的预览窗口会跟随调整尺寸；新增 `--agents` 与 `--agent-layout` 调试参数用于快照/预览/GIF 等渲染命令。
- 关键决策：将 Agent 配置持久化到 `UserDefaults`；保留 Codex 兜底，避免用户同时关闭 Claude/Codex 后出现空 Agent 区；横向双 Agent 使用原 1920 宽布局，单 Agent 或纵向双 Agent 使用较短宽度布局。
- 修改文件：
  - `Sources/MacTR/Rendering/DesignTokens.swift`
  - `Sources/MacTR/Rendering/MonitorRenderer.swift`
  - `Sources/MacTR/App/AppState.swift`
  - `Sources/MacTR/App/MacTRApp.swift`
  - `Sources/MacTR/UI/SettingsView.swift`
  - `TASK_STATE.md`
- 未解决问题：项目仍有与本次配置化无关的构建 warning（素材文件 `nonisolated(unsafe)`、Info.plist resource 声明、libusb deployment target 提示），本次未处理。
- 验证结果：`swift build` 通过；`git diff --check` 通过；已生成并目检 `/tmp/mactr-agents-default-codex.png`、`/tmp/mactr-agents-horizontal.png`、`/tmp/mactr-agents-vertical.png`，确认默认 Codex-only 为 `1540x480`、双 Agent 横向为 `1920x480`、双 Agent 纵向为 `1540x480`，且纵向 Token 区无裁切。

## 2026-07-24 Release 构建验证

- 完成内容：按要求执行 release 构建。
- 关键决策：仅执行构建验证，不改动功能代码。
- 修改文件：
  - `TASK_STATE.md`
- 未解决问题：release 构建仍有既有 warning（Info.plist resource 声明、素材文件 `nonisolated(unsafe)`、libusb deployment target 提示），本次未处理。
- 验证结果：`swift build -c release` 通过，产物链接成功。

## 2026-07-24 修正整体竖向显示布局

- 完成内容：修正 Vertical 布局语义，从原先仅调整 Agent 面板内部排列，改为整个 dashboard 竖向堆叠；Vertical 现在按 CPU、Agents、Memory 从上到下显示；背景、预览窗口尺寸、快照尺寸都跟随动态高度。
- 关键决策：保留 Claude/Codex 开关；Horizontal 仍维持原横向 dashboard；Vertical 使用较窄竖向画布，并在 Agent 区兼容单 Agent 与双 Agent 显示。
- 修改文件：
  - `Sources/MacTR/Rendering/DesignTokens.swift`
  - `Sources/MacTR/Rendering/DrawingPrimitives.swift`
  - `Sources/MacTR/Rendering/MonitorRenderer.swift`
  - `Sources/MacTR/App/AppState.swift`
  - `Sources/MacTR/App/MacTRApp.swift`
  - `Sources/MacTR/UI/SettingsView.swift`
  - `TASK_STATE.md`
- 未解决问题：release 构建仍有既有 warning（Info.plist resource 声明、素材文件 `nonisolated(unsafe)`、libusb deployment target 提示），本次未处理。
- 验证结果：`swift build` 通过；`swift build -c release` 通过；`git diff --check` 通过；已生成并目检 `/tmp/mactr-dashboard-vertical-codex.png` 和 `/tmp/mactr-dashboard-vertical-both.png`，确认竖向布局为 CPU 最上、Agent 居中、Memory 最下，尺寸为 `778x1404`。

## 2026-07-24 Vertical 宽度缩小三分之一

- 完成内容：将 Vertical 模式整体画布宽度缩小约 1/3，从 `778x1404` 调整为 `519x1404`；修正 Agent 面板在窄版画布中仍使用旧宽度导致裁切的问题。
- 关键决策：仅缩小 Vertical 模式，Horizontal 模式尺寸保持不变；按整体画布宽度乘 `2/3` 计算新宽度，并让 CPU、Agents、Memory 三个面板统一使用缩窄后的内容宽度。
- 修改文件：
  - `Sources/MacTR/Rendering/DesignTokens.swift`
  - `TASK_STATE.md`
- 未解决问题：release 构建仍有既有 warning（Info.plist resource 声明、素材文件 `nonisolated(unsafe)`、libusb deployment target 提示），本次未处理。
- 验证结果：`swift build` 通过；`swift build -c release` 通过；`git diff --check` 通过；已生成并目检 `/tmp/mactr-dashboard-vertical-codex-narrow.png` 和 `/tmp/mactr-dashboard-vertical-both-narrow.png`，确认尺寸为 `519x1404` 且 Agent 面板无横向裁切。

## 2026-07-24 提交与推送

- 完成内容：检查待提交变更，提交到本地 Git，并推送到用户指定远端。
- 关键决策：当前 `origin` 指向 `m1ng-li/mac-thermalright-ai-monitor`，本次按用户要求直接 push 到 `iBobbySun/mac-thermalright-ai-monitor`，不修改本地 remote 配置。
- 修改文件：
  - `TASK_STATE.md`
- 未解决问题：本地 `origin` 仍指向旧仓库，因此 `git status` 相对 `origin/main` 仍显示 ahead；目标仓库 `iBobbySun/mac-thermalright-ai-monitor` 已推送成功。
- 验证结果：`git diff --check` 通过；`swift build -c release` 通过；已 push 到 `https://github.com/iBobbySun/mac-thermalright-ai-monitor.git`，远端 `main` readback 成功。
