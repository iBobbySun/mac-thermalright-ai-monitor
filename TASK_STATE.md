# TASK_STATE

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
