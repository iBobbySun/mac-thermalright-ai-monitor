// OpenCodeUsageClient.swift — OpenCode Zen quota meter (API-backed)
//
// OpenCode has no local session transcripts to mine, so unlike Claude/Codex this
// agent's numbers come from a remote endpoint:
//
//   GET https://opencode.ai/zen/go/v1/usage
//   Authorization: Bearer <api key>
//
// Canonical response:
//   {"usage":{"rolling":{"status":"ok","percent":52,"resetsAt":"...Z"},
//             "weekly":{...}, "monthly":{...}}}
// Legacy shape still accepted:
//   {"usage":{"windows":[{"name":"rolling","status":"ok","usagePercent":52,...}]}}
//
// The output is ALWAYS three AgentQuota rows in rolling/weekly/monthly order so
// the dashboard layout never jumps when a window disappears; a missing window
// simply carries usedPercent == nil.
//
// Throttling: a success is reused for 60 s, a failure retried after 30 s, and only
// one request may be in flight. `refreshIfNeeded()` never blocks the metrics loop —
// it only decides under the lock and spawns a detached Task for the network work,
// writing the result back under the same lock. No key is ever logged by this file.

import Foundation

// MARK: - Errors

enum OpenCodeUsageError: Error, Equatable, Sendable {
    case noKey
    case unauthorized
    case http(Int)
    case network
    case decoding

    /// Compact text for the right-aligned status slot (`AgentUsage.statusLabel`).
    var shortLabel: String {
        switch self {
        case .noKey: "未配置"
        case .unauthorized: "Key 无效"
        case .http(let code): "HTTP \(code)"
        case .network: "网络错误"
        case .decoding: "解析失败"
        }
    }

    /// One human sentence for the dashboard activity line. Must never contain a key.
    var message: String {
        switch self {
        case .noKey:
            "尚未配置 OpenCode API Key"
        case .unauthorized:
            "API Key 无效或已过期，请在 设置 → Agents 中更新"
        case .http(let code):
            "OpenCode 服务返回 HTTP \(code)"
        case .network:
            "无法连接 OpenCode 服务，请检查网络"
        case .decoding:
            "OpenCode 返回了无法解析的数据"
        }
    }
}

// MARK: - State

struct OpenCodeUsageState: Sendable {
    let isConfigured: Bool
    let quotas: [AgentQuota]        // always exactly 3: 滚动 / 周 / 月
    let lastSuccessAt: Date?
    let lastError: OpenCodeUsageError?
    let isRefreshing: Bool
}

// MARK: - Client

final class OpenCodeUsageClient: @unchecked Sendable {

    // MARK: Constants

    private static let usageURLString = "https://opencode.ai/zen/go/v1/usage"
    private static let requestTimeout: TimeInterval = 8
    private static let successInterval: TimeInterval = 60
    private static let failureInterval: TimeInterval = 30
    private static let requestCachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData

    /// Fixed window identity: (API key, dashboard label). Order is the display order.
    private static let windowKeys = ["rolling", "weekly", "monthly"]
    private static let windowLabels = ["滚动", "周", "月"]

    /// Placeholder rows shown before the first successful sync (and when unconfigured).
    static let placeholderQuotas: [AgentQuota] = windowLabels.map {
        AgentQuota(usedPercent: nil, resetsAt: nil,
                   resetIsEstimated: false, windowLabel: $0)
    }

    // MARK: State (guarded by `lock`)

    private let lock = NSLock()
    private var cachedQuotas: [AgentQuota] = OpenCodeUsageClient.placeholderQuotas
    private var lastSuccessAt: Date?
    private var lastError: OpenCodeUsageError?
    private var lastAttemptAt: Date?
    private var lastAttemptSucceeded = false
    private var inFlight = false
    /// Last `OpenCodeKeyStore.revision` observed; -1 forces the first refresh.
    private var observedKeyRevision = -1

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = OpenCodeUsageClient.requestTimeout
        configuration.timeoutIntervalForResource = OpenCodeUsageClient.requestTimeout
        configuration.requestCachePolicy = OpenCodeUsageClient.requestCachePolicy
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: - Public API

    /// Snapshot for the renderer. Cheap, lock-protected, never touches the network.
    func state() -> OpenCodeUsageState {
        // Read the key store first: it has its own lock and must not be nested under ours.
        let configured = OpenCodeKeyStore.isConfigured

        lock.lock()
        defer { lock.unlock() }
        guard configured else {
            return OpenCodeUsageState(isConfigured: false,
                                      quotas: Self.placeholderQuotas,
                                      lastSuccessAt: nil,
                                      lastError: .noKey,
                                      isRefreshing: false)
        }
        return OpenCodeUsageState(isConfigured: true,
                                  quotas: cachedQuotas.count == Self.windowLabels.count
                                      ? cachedQuotas : Self.placeholderQuotas,
                                  lastSuccessAt: lastSuccessAt,
                                  lastError: lastError,
                                  isRefreshing: inFlight)
    }

    /// Called from the ~2 s metrics loop. Returns immediately; the request runs in a
    /// Task. Throttled to one refresh per 60 s on success and 30 s on failure, with a
    /// single in-flight request. Zero network activity when no key is configured.
    func refreshIfNeeded() {
        let currentRevision = OpenCodeKeyStore.revision

        guard let key = OpenCodeKeyStore.apiKey() else {
            lock.lock()
            cachedQuotas = Self.placeholderQuotas
            lastSuccessAt = nil
            lastError = .noKey
            lastAttemptAt = nil
            lastAttemptSucceeded = false
            inFlight = false
            observedKeyRevision = currentRevision
            lock.unlock()
            return
        }

        let now = Date()
        lock.lock()
        let revisionChanged = observedKeyRevision != currentRevision
        observedKeyRevision = currentRevision
        guard !inFlight else { lock.unlock(); return }
        if !revisionChanged, let lastAttempt = lastAttemptAt {
            let interval = lastAttemptSucceeded ? Self.successInterval : Self.failureInterval
            if now.timeIntervalSince(lastAttempt) < interval { lock.unlock(); return }
        }
        inFlight = true
        lastAttemptAt = now
        lock.unlock()

        Task { await self.performRefresh(key: key, revision: currentRevision) }
    }

    // MARK: - Networking

    private func performRefresh(key: String, revision: Int) async {
        let result = await Self.fetchQuotas(key: key, session: session)

        // A save/clear while this request was in flight invalidates its answer: drop
        // it and let the next tick refresh against the new key.
        let latestRevision = OpenCodeKeyStore.revision

        withLock {
            inFlight = false
            guard revision == latestRevision else { return }
            switch result {
            case .success(let quotas):
                cachedQuotas = quotas
                lastSuccessAt = Date()
                lastError = nil
                lastAttemptSucceeded = true
            case .failure(let error):
                // Keep the last known-good percents on screen; the status slot shows why.
                lastError = error
                lastAttemptSucceeded = false
            }
        }
    }

    /// Synchronous lock scope. `NSLock.lock()` is marked `noasync`, so the async
    /// write-back path above must funnel its critical section through a sync helper.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func fetchQuotas(key: String,
                                    session: URLSession) async -> Result<[AgentQuota], OpenCodeUsageError> {
        guard let url = URL(string: usageURLString) else { return .failure(.network) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MacTR", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failure(.network)
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.network) }

        switch http.statusCode {
        case 200...299:
            return parse(data)
        case 401:
            return .failure(.unauthorized)
        default:
            return .failure(.http(http.statusCode))
        }
    }

    // MARK: - Parsing

    /// Parses a response body into exactly three quotas (滚动 / 周 / 月). Also detects
    /// the API's error envelope so a fixture of a 401 body classifies as `.unauthorized`.
    static func parse(_ data: Data) -> Result<[AgentQuota], OpenCodeUsageError> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.decoding)
        }
        // {"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}
        if let error = root["error"] as? [String: Any], root["usage"] == nil {
            let type = (error["type"] as? String)?.lowercased()
            if type == "autherror" || type == "unauthorized" {
                return .failure(.unauthorized)
            }
            return .failure(.decoding)
        }
        return .success(quotas(from: windowObjects(in: root)))
    }

    /// Collects raw window objects keyed by canonical name. Tolerant of the legacy
    /// `windows` array living under `usage` or directly on the root, and of the
    /// named-window form appearing under `usage` or on the root.
    private static func windowObjects(in root: [String: Any]) -> [String: [String: Any]] {
        var windows: [String: [String: Any]] = [:]
        let usage = root["usage"] as? [String: Any]

        // Legacy arrays: {"usage":{"windows":[{"name":"rolling",...}]}}
        for candidate in [usage?["windows"], root["windows"]] {
            guard let list = candidate as? [[String: Any]] else { continue }
            for item in list {
                guard let name = (item["name"] as? String)?.lowercased(),
                      let key = canonicalWindowKey(name)
                else { continue }
                windows[key] = item
            }
        }

        // Canonical named windows: {"usage":{"rolling":{...}}}
        if let usage {
            for key in windowKeys where windows[key] == nil {
                if let window = usage[key] as? [String: Any] { windows[key] = window }
            }
        }
        // Tolerate the named windows sitting directly on the root object.
        for key in windowKeys where windows[key] == nil {
            if let window = root[key] as? [String: Any] { windows[key] = window }
        }
        return windows
    }

    private static func canonicalWindowKey(_ name: String) -> String? {
        switch name {
        case "rolling", "rolling_window", "5h", "five_hour": "rolling"
        case "weekly", "week", "7d", "seven_day": "weekly"
        case "monthly", "month", "30d": "monthly"
        default: nil
        }
    }

    private static func quotas(from windows: [String: [String: Any]]) -> [AgentQuota] {
        var quotas: [AgentQuota] = []
        quotas.reserveCapacity(windowKeys.count)
        for index in windowKeys.indices {
            let key = windowKeys[index]
            let label = windowLabels[index]
            if let window = windows[key] {
                quotas.append(quota(from: window, label: label))
            } else {
                quotas.append(AgentQuota(usedPercent: nil, resetsAt: nil,
                                         resetIsEstimated: false, windowLabel: label))
            }
        }
        return quotas
    }

    private static func quota(from window: [String: Any], label: String) -> AgentQuota {
        let status = (window["status"] as? String)?.lowercased()
        var percent = number(window["percent"])
        if percent == nil { percent = number(window["usagePercent"]) }
        if percent == nil { percent = number(window["usage_percent"]) }

        let usedPercent: Double?
        if let percent {
            usedPercent = min(max(percent, 0), 100)
        } else if let status, status != "ok" {
            // exhausted / limited / blocked with no explicit number — treat as spent.
            usedPercent = 100
        } else {
            usedPercent = nil
        }

        return AgentQuota(usedPercent: usedPercent,
                          resetsAt: resetDate(window["resetsAt"] ?? window["resets_at"]),
                          resetIsEstimated: false,
                          windowLabel: label)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    /// ISO8601 with milliseconds first, then the second-precision fallback. A
    /// malformed value is simply ignored (nil reset), not treated as a parse failure.
    private static func resetDate(_ value: Any?) -> Date? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    // MARK: - Settings-page probe

    /// One-shot request using a candidate key (settings "保存并测试"), returning a
    /// human-readable Chinese verdict. Never echoes the key.
    static func probe(key: String) async -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "❌ 未配置 API Key" }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.requestCachePolicy = requestCachePolicy
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)

        switch await fetchQuotas(key: trimmed, session: session) {
        case .success(let quotas):
            let parts = quotas.map { quota -> String in
                let remaining = quota.usedPercent.map { Int((100 - $0).rounded()) }
                return "\(quota.windowLabel)剩余 \(remaining.map { "\($0)%" } ?? "—")"
            }
            return "✅ 已连通 · " + parts.joined(separator: " / ")
        case .failure(let error):
            switch error {
            case .unauthorized: return "❌ Key 无效（401）"
            case .http(let code): return "❌ 服务异常（HTTP \(code)）"
            case .network: return "❌ 网络错误"
            case .decoding: return "❌ 解析失败"
            case .noKey: return "❌ 未配置 API Key"
            }
        }
    }
}
