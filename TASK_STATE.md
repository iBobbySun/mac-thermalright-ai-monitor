# TASK_STATE

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
