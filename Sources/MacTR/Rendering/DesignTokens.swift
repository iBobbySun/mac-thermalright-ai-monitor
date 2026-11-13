// DesignTokens.swift — Colors, fonts, and layout constants
//
// Ported from trcc_monitor.py color/layout definitions.
// All values match the Python prototype for visual consistency.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Colors

enum Color {
    static let bgTop = CGColor(red: 10/255, green: 12/255, blue: 20/255, alpha: 1)
    static let bgBot = CGColor(red: 16/255, green: 18/255, blue: 28/255, alpha: 1)
    static let panelBG = CGColor(red: 20/255, green: 23/255, blue: 34/255, alpha: 1)
    static let border = CGColor(red: 38/255, green: 42/255, blue: 58/255, alpha: 1)

    static let textW = CGColor(red: 230/255, green: 235/255, blue: 245/255, alpha: 1)
    static let textS = CGColor(red: 140/255, green: 148/255, blue: 168/255, alpha: 1)
    static let textL = CGColor(red: 100/255, green: 108/255, blue: 130/255, alpha: 1)
    static let textD = CGColor(red: 70/255, green: 76/255, blue: 95/255, alpha: 1)

    static let blue = CGColor(red: 66/255, green: 133/255, blue: 244/255, alpha: 1)
    static let blueD = CGColor(red: 30/255, green: 60/255, blue: 120/255, alpha: 1)
    static let green = CGColor(red: 52/255, green: 211/255, blue: 153/255, alpha: 1)
    static let greenD = CGColor(red: 24/255, green: 95/255, blue: 70/255, alpha: 1)
    static let orange = CGColor(red: 251/255, green: 191/255, blue: 36/255, alpha: 1)
    static let orangeD = CGColor(red: 110/255, green: 84/255, blue: 16/255, alpha: 1)
    static let red = CGColor(red: 239/255, green: 68/255, blue: 68/255, alpha: 1)
    static let redD = CGColor(red: 110/255, green: 30/255, blue: 30/255, alpha: 1)
    static let purple = CGColor(red: 167/255, green: 139/255, blue: 250/255, alpha: 1)
    static let purpleD = CGColor(red: 75/255, green: 62/255, blue: 115/255, alpha: 1)
    static let cyan = CGColor(red: 34/255, green: 211/255, blue: 238/255, alpha: 1)
    static let cyanD = CGColor(red: 15/255, green: 95/255, blue: 108/255, alpha: 1)
    static let magenta = CGColor(red: 217/255, green: 70/255, blue: 239/255, alpha: 1)
    static let magentaD = CGColor(red: 80/255, green: 28/255, blue: 90/255, alpha: 1)
    static let claude = CGColor(red: 217/255, green: 119/255, blue: 87/255, alpha: 1)  // Claude brand terracotta
    /// OpenCode brand token. Shares the magenta value (no dedicated brand hue yet),
    /// kept as its own symbol so the agent accent can be re-tinted in one place.
    static let opencode = CGColor(red: 217/255, green: 70/255, blue: 239/255, alpha: 1)
    /// Ollama is a monochrome brand, so the card accent is a light steel blue —
    /// clearly distinct from Codex cyan, OpenCode magenta and Claude terracotta.
    /// Kept as its own symbol so the tint can be changed in one place.
    static let ollama = CGColor(red: 154/255, green: 205/255, blue: 255/255, alpha: 1)
    /// Antigravity (Google's agent IDE) is a multi-hue brand; lime keeps it visually
    /// apart from Codex cyan, OpenCode magenta, Claude terracotta and Ollama blue.
    static let antigravity = CGColor(red: 163/255, green: 230/255, blue: 53/255, alpha: 1)

    static let barBG = CGColor(red: 30/255, green: 34/255, blue: 48/255, alpha: 1)

    /// Color by percentage threshold: green < 50, orange < 75, red >= 75
    static func forPercent(_ pct: Double) -> CGColor {
        pct < 50 ? green : (pct < 75 ? orange : red)
    }

    static func forPercentDark(_ pct: Double) -> CGColor {
        pct < 50 ? greenD : (pct < 75 ? orangeD : redD)
    }

    /// Color by macOS memory pressure level (1=normal, 2=warn, 4=critical).
    /// Severity comes from pressure, not from used% — a Mac using RAM as cache is not "in danger".
    static func forPressure(_ level: Int) -> CGColor {
        level >= 4 ? red : (level >= 2 ? orange : green)
    }

    static func forPressureDark(_ level: Int) -> CGColor {
        level >= 4 ? redD : (level >= 2 ? orangeD : greenD)
    }
}

// MARK: - Layout

enum Layout {
    static let width = 1920
    static let height = 480
    static let margin = 14
    static let gap = 10
    static let panelCount = 5
    static let panelWidth = (width - 2 * margin - (panelCount - 1) * gap) / panelCount
    static let panelHeight = height - 2 * margin
    static let panelY = margin

    /// X position for panel at index (0-based)
    static func panelX(_ index: Int) -> Int {
        margin + index * (panelWidth + gap)
    }
}

enum AgentKind: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case opencode
    case ollama
    case antigravity

    var id: String { rawValue }

    /// Panel header / Settings label.
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .ollama: return "Ollama"
        case .antigravity: return "Antigravity"
        }
    }

    /// Declaration order — it decides the on-screen column order
    /// (claude → codex → opencode → ollama → antigravity).
    var sortIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

enum AgentLayoutDirection: String, CaseIterable, Identifiable, Sendable {
    case horizontal
    case vertical

    var id: String { rawValue }
}

struct AgentDisplayConfig: Equatable, Sendable {
    private enum DefaultsKey {
        /// Canonical key: comma-separated `AgentKind` raw values, e.g. "codex,opencode".
        static let agents = "agentDisplay.agents"
        static let layoutDirection = "agentDisplay.layoutDirection"
        /// Pre-OpenCode keys, read once for migration and never written again.
        static let legacyShowClaude = "agentDisplay.showClaude"
        static let legacyShowCodex = "agentDisplay.showCodex"
    }

    /// The dashboard shows at most two agent columns/cards at a time.
    static let maxVisibleAgents = 2

    /// Selected agents, in declaration order. `normalized` is the canonical form.
    var selectedAgents: [AgentKind]
    var layoutDirection: AgentLayoutDirection

    static let defaultValue = AgentDisplayConfig(
        selectedAgents: [.codex],
        layoutDirection: .horizontal)

    /// Deduplicated, enum-ordered, capped at `maxVisibleAgents`; empty falls back to `[.codex]`.
    var normalized: AgentDisplayConfig {
        var seen: Set<AgentKind> = []
        let unique = selectedAgents.filter { seen.insert($0).inserted }
        let ordered = unique.sorted { $0.sortIndex < $1.sortIndex }
        let capped = Array(ordered.prefix(Self.maxVisibleAgents))
        return AgentDisplayConfig(
            selectedAgents: capped.isEmpty ? Self.defaultValue.selectedAgents : capped,
            layoutDirection: layoutDirection)
    }

    var visibleAgents: [AgentKind] { normalized.selectedAgents }

    func shows(_ agent: AgentKind) -> Bool { normalized.selectedAgents.contains(agent) }

    /// True when the agent is already selected or another one can still be added.
    func canSelect(_ agent: AgentKind) -> Bool {
        let agents = normalized.selectedAgents
        return agents.contains(agent) || agents.count < Self.maxVisibleAgents
    }

    /// Flip one agent in/out of the selection. Adding is a no-op when already full.
    mutating func toggle(_ agent: AgentKind) {
        var agents = normalized.selectedAgents
        if let index = agents.firstIndex(of: agent) {
            agents.remove(at: index)
        } else if agents.count < Self.maxVisibleAgents {
            agents.append(agent)
        }
        selectedAgents = agents
        self = normalized
    }

    static func load() -> AgentDisplayConfig {
        let defaults = UserDefaults.standard
        let layoutDirection = (defaults.string(forKey: DefaultsKey.layoutDirection)
            .flatMap(AgentLayoutDirection.init(rawValue:))) ?? defaultValue.layoutDirection

        let agents: [AgentKind]
        if let raw = defaults.string(forKey: DefaultsKey.agents) {
            agents = raw.split(separator: ",").compactMap {
                AgentKind(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased())
            }
        } else {
            // One-time migration from the old two-toggle config. Missing legacy keys
            // keep the historical default: Claude off, Codex on.
            let showClaude = defaults.object(forKey: DefaultsKey.legacyShowClaude) as? Bool ?? false
            let showCodex = defaults.object(forKey: DefaultsKey.legacyShowCodex) as? Bool ?? true
            var migrated: [AgentKind] = []
            if showClaude { migrated.append(.claude) }
            if showCodex { migrated.append(.codex) }
            agents = migrated
        }
        return AgentDisplayConfig(selectedAgents: agents,
                                  layoutDirection: layoutDirection).normalized
    }

    func save() {
        let config = normalized
        let defaults = UserDefaults.standard
        defaults.set(config.selectedAgents.map(\.rawValue).joined(separator: ","),
                     forKey: DefaultsKey.agents)
        defaults.set(config.layoutDirection.rawValue, forKey: DefaultsKey.layoutDirection)
        // Legacy keys are intentionally left in place so an older build still reads a
        // sane config after a rollback.
    }

    // MARK: - Init

    init(selectedAgents: [AgentKind], layoutDirection: AgentLayoutDirection) {
        self.selectedAgents = selectedAgents
        self.layoutDirection = layoutDirection
    }
}

struct DashboardLayout: Sendable {
    let agentDisplay: AgentDisplayConfig

    var visibleAgents: [AgentKind] { agentDisplay.visibleAgents }
    var isVertical: Bool { agentDisplay.layoutDirection == .vertical }
    var agentPanelSlots: Int {
        visibleAgents.count <= 1 || isVertical ? 2 : 3
    }
    var naturalAgentsWidth: Int {
        agentPanelSlots * Layout.panelWidth + (agentPanelSlots - 1) * Layout.gap
    }
    var totalPanelSlots: Int { 2 + agentPanelSlots }
    var verticalWidth: Int {
        let currentVerticalWidth = 2 * Layout.margin + naturalAgentsWidth
        return Int((Double(currentVerticalWidth) * 2.0 / 3.0).rounded())
    }
    var width: Int {
        if isVertical {
            return verticalWidth
        }
        return Layout.width - (Layout.panelCount - totalPanelSlots) * (Layout.panelWidth + Layout.gap)
    }
    var height: Int {
        if isVertical {
            return 2 * Layout.margin + 3 * Layout.panelHeight + 2 * Layout.gap
        }
        return Layout.height
    }

    func panelX(_ index: Int) -> Int {
        Layout.panelX(index)
    }

    func panelY(_ row: Int) -> Int {
        Layout.margin + row * (Layout.panelHeight + Layout.gap)
    }

    var contentX: Int { Layout.margin }
    var contentWidth: Int { isVertical ? verticalWidth - 2 * Layout.margin : naturalAgentsWidth }
    var cpuX: Int { isVertical ? contentX : panelX(0) }
    var cpuY: Int { isVertical ? panelY(0) : Layout.panelY }
    var cpuWidth: Int { isVertical ? contentWidth : Layout.panelWidth }
    var agentsX: Int { isVertical ? contentX : panelX(1) }
    var agentsY: Int { isVertical ? panelY(1) : Layout.panelY }
    var agentsWidth: Int {
        isVertical ? contentWidth : naturalAgentsWidth
    }
    var memoryX: Int { isVertical ? contentX : panelX(1 + agentPanelSlots) }
    var memoryY: Int { isVertical ? panelY(2) : Layout.panelY }
    var memoryWidth: Int { isVertical ? contentWidth : Layout.panelWidth }
}

// MARK: - Fonts

enum Fonts {
    private struct FontKey: Hashable {
        let size: CGFloat
        let weight: NSFont.Weight
    }

    nonisolated(unsafe) private static var cache: [FontKey: NSFont] = [:]

    static func system(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let key = FontKey(size: size, weight: weight)
        if let cached = cache[key] {
            return cached
        }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        cache[key] = font
        return font
    }

    static func mono(_ size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - Brightness

enum Brightness {
    /// Brightness levels 1-10. Factor = 1.0 + (level-1) * 0.3
    static func factor(for level: Int) -> CGFloat {
        let clamped = max(1, min(10, level))
        return 1.0 + CGFloat(clamped - 1) * 0.3
    }
}
