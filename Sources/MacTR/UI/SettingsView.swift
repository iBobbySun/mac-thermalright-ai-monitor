// SettingsView.swift — Settings window (SwiftUI)
//
// Tabs: General | Display | Agents | Device | About

import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var openCodeKeyInput = ""
    @State private var ollamaKeyInput = ""

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalSettings
            }

            Tab("Display", systemImage: "display") {
                displaySettings
            }

            Tab("Agents", systemImage: "person.2") {
                agentSettings
            }

            Tab("Device", systemImage: "cable.connector") {
                deviceSettings
            }

            Tab("About", systemImage: "info.circle") {
                aboutView
            }
        }
        .frame(width: 500, height: 800)
    }

    // MARK: - General Tab

    private var generalSettings: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                Text("Requires .app bundle to work (not available in debug builds)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                Picker("Interval", selection: $state.refreshInterval) {
                    Text("0.5s (default)").tag(0.5)
                    Text("1.0s").tag(1.0)
                    Text("2.0s").tag(2.0)
                }
                .onChange(of: state.refreshInterval) {
                    state.applySettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Display Tab

    private var displaySettings: some View {
        Form {
            Section("Display Set") {
                Picker("Active Set", selection: $state.currentSet) {
                    ForEach(DisplaySet.allCases) { set in
                        Text(set.rawValue).tag(set)
                    }
                }
                .onChange(of: state.currentSet) {
                    state.applySettings()
                }
            }

            Section("Brightness") {
                HStack {
                    Slider(value: brightnessBinding, in: 1...10, step: 1) {
                        Text("Level")
                    }
                    Text("\(state.brightness)")
                        .monospacedDigit()
                        .frame(width: 24)
                }
                .onChange(of: state.brightness) {
                    state.applySettings()
                }
                Text("1 = original, 10 = maximum")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dashboard Layout") {
                Picker("Orientation", selection: $state.agentLayoutDirection) {
                    Text("Horizontal").tag(AgentLayoutDirection.horizontal)
                    Text("Vertical").tag(AgentLayoutDirection.vertical)
                }
                .pickerStyle(.segmented)
                .onChange(of: state.agentLayoutDirection) {
                    state.applySettings()
                }

                Text("Vertical stacks CPU, Agents, and Memory from top to bottom. "
                     + "Which agents appear is set in the Agents tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Rotation") {
                Toggle("Rotate 180°", isOn: $state.rotateDisplay)
                    .onChange(of: state.rotateDisplay) {
                        state.applySettings()
                    }
                Text("Enable if display appears upside down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Agents Tab

    private var agentSettings: some View {
        Form {
            Section {
                ForEach(AgentKind.allCases) { agent in
                    Toggle(isOn: agentBinding(agent)) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(.secondary)
                                .frame(width: 8, height: 8)
                            Text(agent.displayName)
                        }
                    }
                    .disabled(!state.canSelectAgent(agent) || state.isLastSelectedAgent(agent))
                }
            } header: {
                Text("Dashboard Agents")
            } footer: {
                Text("Pick at most 2 agents to show at once (at least 1 stays on). "
                     + "Selected: \(state.selectedAgents.count)/\(AgentDisplayConfig.maxVisibleAgents). "
                     + "Orientation is under Display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(state.openCodeKeyConfigured ? .green : .secondary)
                            .frame(width: 8, height: 8)
                        Text(state.openCodeKeyConfigured ? "已配置" : "未配置")
                        if state.openCodeKeyConfigured {
                            Text("· MD5 \(fingerprintText(state.openCodeKeyFingerprint))")
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                SecureField("OpenCode API Key", text: $openCodeKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(state.openCodeKeyTesting)

                HStack(spacing: 8) {
                    Button("保存并测试") {
                        let candidate = openCodeKeyInput
                        Task {
                            if await state.saveAndTestOpenCodeKey(candidate) {
                                openCodeKeyInput = ""
                            }
                        }
                    }
                    .disabled(state.openCodeKeyTesting
                              || openCodeKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("清除") {
                        state.clearOpenCodeKey()
                        openCodeKeyInput = ""
                    }
                    .disabled(!state.openCodeKeyConfigured || state.openCodeKeyTesting)

                    if state.openCodeKeyTesting {
                        ProgressView().controlSize(.small)
                    }
                }

                if !state.openCodeKeyStatus.isEmpty {
                    Text(state.openCodeKeyStatus)
                        .font(.caption)
                        .foregroundStyle(state.openCodeKeyStatus.hasPrefix("✅") ? .green : .secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("OpenCode Usage")
            } footer: {
                Text("AES-GCM at rest; only the MD5 fingerprint is shown. Queries "
                     + "opencode.ai/zen/go/v1/usage every 60 s — no request without a key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(state.ollamaKeyConfigured ? .green : .secondary)
                            .frame(width: 8, height: 8)
                        Text(state.ollamaKeyConfigured ? "已配置" : "未配置")
                        if state.ollamaKeyConfigured {
                            Text("· MD5 \(fingerprintText(state.ollamaKeyFingerprint))")
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                SecureField("Ollama API Key", text: $ollamaKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(state.ollamaKeyTesting)

                HStack(spacing: 8) {
                    Button("保存并测试") {
                        let candidate = ollamaKeyInput
                        Task {
                            if await state.saveAndTestOllamaKey(candidate) {
                                ollamaKeyInput = ""
                            }
                        }
                    }
                    .disabled(state.ollamaKeyTesting
                              || ollamaKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("清除") {
                        state.clearOllamaKey()
                        ollamaKeyInput = ""
                    }
                    .disabled(!state.ollamaKeyConfigured || state.ollamaKeyTesting)

                    if state.ollamaKeyTesting {
                        ProgressView().controlSize(.small)
                    }
                }

                if !state.ollamaKeyStatus.isEmpty {
                    Text(state.ollamaKeyStatus)
                        .font(.caption)
                        .foregroundStyle(state.ollamaKeyStatus.hasPrefix("✅") ? .green : .secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Ollama Usage")
            } footer: {
                Text("AES-GCM at rest (key from ollama.com/settings/keys). Queries "
                     + "ollama.com/api/balance + /api/usage every 60 s — no request without a key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func fingerprintText(_ fingerprint: String?) -> String {
        guard let fingerprint, fingerprint.count >= 8 else {
            return "—"
        }
        return String(fingerprint.prefix(8)) + "…"
    }

    /// A checkbox that reflects the selection and flips it through AppState
    /// (which enforces the 2-agent cap and persists the choice).
    private func agentBinding(_ agent: AgentKind) -> Binding<Bool> {
        Binding(
            get: { state.selectedAgents.contains(agent) },
            set: { _ in state.toggleAgent(agent) }
        )
    }

    // MARK: - Device Tab

    private var deviceSettings: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status") {
                    HStack {
                        Circle()
                            .fill(state.isConnected ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(state.isConnected ? "Connected" : "Disconnected")
                    }
                }

                if let info = state.deviceInfo {
                    LabeledContent("Resolution", value: "\(info.width) × \(info.height)")
                    LabeledContent("PM / SUB / FBL", value: "\(info.pm) / \(info.sub) / \(info.fbl)")
                    LabeledContent("PID", value: String(format: "0x%04X", info.pid))
                }

                if !state.isConnected {
                    Button("Reconnect") {
                        state.connect()
                    }
                }
            }

            Section("Statistics") {
                LabeledContent("Frames Sent", value: "\(state.frameCount)")
                LabeledContent("Last Frame", value: "\(state.lastFrameSize / 1024) KB")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - About Tab

    private var aboutView: some View {
        VStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("MacTR")
                .font(.title)
                .fontWeight(.semibold)

            Text("macOS driver for Thermalright Trofeo Vision 9.16 LCD")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider().frame(width: 200)

            VStack(spacing: 4) {
                Text("Built with Swift 6.3 + libusb")
                Text("Protocol: LY Bulk (thermalright-trcc-linux)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
    }

    // MARK: - Helpers

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("[Settings] Launch at login: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { Double(state.brightness) },
            set: { state.brightness = Int($0) }
        )
    }
}
