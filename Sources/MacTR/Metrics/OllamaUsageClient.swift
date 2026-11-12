// OllamaUsageClient.swift — Ollama Cloud usage meter (API-backed)
//
// Ollama's local daemon (127.0.0.1:11434) has no quota route: usage lives on
// ollama.com and is gated by the Bearer keys minted at ollama.com/settings/keys.
// One refresh therefore asks two endpoints:
//
//   GET https://ollama.com/api/balance            (remaining credits / plan limits)
//   GET https://ollama.com/api/usage?range=24h    (requests, tokens, spend)
//   Authorization: Bearer <api key>
//
// Canonical balance (credit plan — docs.ollama.com/api/balance):
//   {"included":{"balance_usd":72.5,"allowance_usd":100,
//                "period":{"from":"...Z","until":"...Z"}},
//    "purchased":{"balance_usd":25}}
// Legacy plan (session + weekly limits instead of credits):
//   {"included":{"session":{"remaining_percent":75,"resets_at":"...Z"},
//                "weekly":{"remaining_percent":40,"resets_at":"...Z"}},
//    "purchased":{"balance_usd":25}}
// Canonical usage:
//   {"range":"24h","totals":{"request_count":15,"usage_usd":0.01718,
//    "input_tokens":106000,"cached_input_tokens":46000,"output_tokens":13600},...}
// Unauthorized (verified live against a bogus key):
//   {"error":"invalid credentials"}   ← `error` is a STRING here, not an object
//
// Quota rows: a credit plan yields ONE row ("额度", used % from balance/allowance);
// a legacy plan yields TWO ("会话", "周", used % from remaining_percent). Both fit
// existing dashboard layouts, so the renderer needs no new branch.
//
// Rate limit: 10 requests/minute/user shared across keys and devices, with
// `Retry-After` on 429. Two requests per 60 s (≈2/min) stays far below it.
//
// Throttling mirrors OpenCodeUsageClient: a success is reused for 60 s, a failure
// is retried after 30 s, only one refresh may be in flight, and a 429 pushes a
// backoff window (Retry-After, floored at 60 s, capped at 10 min). The metrics loop
// only ever pays for a lock-guarded snapshot read — the network runs in a Task.
// No key is ever logged by this file.

import Foundation

// MARK: - Errors

enum OllamaUsageError: Error, Equatable, Sendable {
    case noKey
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network
    case decoding

    /// Compact text for the right-aligned status slot (`AgentUsage.statusLabel`).
    var shortLabel: String {
        switch self {
        case .noKey: "未配置"
        case .unauthorized: "Key 无效"
        case .forbidden: "账户受限"
        case .rateLimited: "限流"
        case .http(let code): "HTTP \(code)"
        case .network: "网络错误"
        case .decoding: "解析失败"
        }
    }

    /// One human sentence for the dashboard activity line. Must never contain a key.
    var message: String {
        switch self {
        case .noKey:
            "尚未配置 Ollama API Key"
        case .unauthorized:
            "API Key 无效或已过期，请在 设置 → Agents 中更新"
        case .forbidden:
            "Ollama 账户受限（403）"
        case .rateLimited:
            "Ollama 接口限流（429），将自动退避后重试"
        case .http(let code):
            "Ollama 服务返回 HTTP \(code)"
        case .network:
            "无法连接 Ollama 服务，请检查网络"
        case .decoding:
            "Ollama 返回了无法解析的数据"
        }
    }
}

// MARK: - Parsed values

/// `GET /api/balance`. `quotas` is 1 row on a credit plan and 2 on a legacy plan.
struct OllamaBalance: Sendable {
    let quotas: [AgentQuota]
    let allowanceUSD: Double?
    let remainingUSD: Double?
    let purchasedUSD: Double?
}

/// `GET /api/usage?range=24h` totals.
struct OllamaUsageTotals: Sendable {
    let inputTokens: UInt64
    let outputTokens: UInt64
    let requestCount: Int
    let costUSD: Double?
}

/// Everything one dashboard refresh needs, combined from both endpoints.
struct OllamaUsageSnapshot: Sendable {
    let quotas: [AgentQuota]
    let inputTokens: UInt64
    let outputTokens: UInt64
    let requestCount: Int
    let costUSD: Double?
    let allowanceUSD: Double?
    let remainingUSD: Double?
    let purchasedUSD: Double?
    /// False when the usage endpoint failed — the card must render `—`, never a fake 0.
    let tokensAvailable: Bool
    /// False when the balance endpoint failed — quota rows render "剩余 --".
    let balanceAvailable: Bool
    /// Set when exactly one endpoint succeeded; the activity line explains the gap.
    let partialFailure: OllamaUsageError?
}

// MARK: - State

struct OllamaUsageState: Sendable {
    let isConfigured: Bool
    let snapshot: OllamaUsageSnapshot
    let lastSuccessAt: Date?
    let lastError: OllamaUsageError?
    let isRefreshing: Bool
}

// MARK: - Client

final class OllamaUsageClient: @unchecked Sendable {

    // MARK: Constants

    private static let balanceURLString = "https://ollama.com/api/balance"
    private static let usageURLString = "https://ollama.com/api/usage?range=24h"
    private static let requestTimeout: TimeInterval = 8
    private static let successInterval: TimeInterval = 60
    private static let failureInterval: TimeInterval = 30
    private static let rateLimitFloor: TimeInterval = 60
    private static let rateLimitCeiling: TimeInterval = 600
    private static let requestCachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData

    /// Shown before the first successful sync and whenever no balance is readable.
    /// One row keeps the card at the "single quota + tokens" geometry.
    static let placeholderQuotas: [AgentQuota] = [
        AgentQuota(usedPercent: nil, resetsAt: nil, resetIsEstimated: false,
                   windowLabel: "额度"),
    ]

    static let placeholder = OllamaUsageSnapshot(
        quotas: placeholderQuotas, inputTokens: 0, outputTokens: 0, requestCount: 0,
        costUSD: nil, allowanceUSD: nil, remainingUSD: nil, purchasedUSD: nil,
        tokensAvailable: false, balanceAvailable: false, partialFailure: nil)

    // MARK: State (guarded by `lock`)

    private let lock = NSLock()
    private var cachedSnapshot = OllamaUsageClient.placeholder
    private var lastSuccessAt: Date?
    private var lastError: OllamaUsageError?
    private var lastAttemptAt: Date?
    private var lastAttemptSucceeded = false
    private var inFlight = false
    /// Last `AgentKeyStore.ollama.revision` observed; -1 forces the first refresh.
    private var observedKeyRevision = -1
    /// Set after a 429; no request is attempted before it expires.
    private var backoffUntil: Date?

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = OllamaUsageClient.requestTimeout
        configuration.timeoutIntervalForResource = OllamaUsageClient.requestTimeout
        configuration.requestCachePolicy = OllamaUsageClient.requestCachePolicy
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: - Public API

    /// Snapshot for the renderer. Cheap, lock-protected, never touches the network.
    func state() -> OllamaUsageState {
        // Read the key store first: it has its own lock and must not be nested under ours.
        let configured = AgentKeyStore.ollama.isConfigured

        lock.lock()
        defer { lock.unlock() }
        guard configured else {
            return OllamaUsageState(isConfigured: false,
                                    snapshot: Self.placeholder,
                                    lastSuccessAt: nil,
                                    lastError: .noKey,
                                    isRefreshing: false)
        }
        return OllamaUsageState(isConfigured: true,
                                snapshot: cachedSnapshot,
                                lastSuccessAt: lastSuccessAt,
                                lastError: lastError,
                                isRefreshing: inFlight)
    }

    /// Called from the ~2 s metrics loop. Returns immediately; the requests run in a
    /// Task. Zero network activity when no key is configured.
    func refreshIfNeeded() {
        let currentRevision = AgentKeyStore.ollama.revision

        guard let key = AgentKeyStore.ollama.apiKey() else {
            lock.lock()
            cachedSnapshot = Self.placeholder
            lastSuccessAt = nil
            lastError = .noKey
            lastAttemptAt = nil
            lastAttemptSucceeded = false
            inFlight = false
            backoffUntil = nil
            observedKeyRevision = currentRevision
            lock.unlock()
            return
        }

        let now = Date()
        lock.lock()
        let revisionChanged = observedKeyRevision != currentRevision
        observedKeyRevision = currentRevision
        guard !inFlight else { lock.unlock(); return }
        if !revisionChanged, let until = backoffUntil, now < until { lock.unlock(); return }
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
        let result = await Self.fetchSnapshot(key: key, session: session)

        // A save/clear while these requests were in flight invalidates the answer:
        // drop it and let the next tick refresh against the new key.
        let latestRevision = AgentKeyStore.ollama.revision

        withLock {
            inFlight = false
            guard revision == latestRevision else { return }
            switch result {
            case .success(let snapshot):
                cachedSnapshot = snapshot
                lastSuccessAt = Date()
                lastError = nil
                lastAttemptSucceeded = true
                backoffUntil = nil
            case .failure(let error):
                // Keep the last known-good numbers on screen; the status slot shows why.
                lastError = error
                lastAttemptSucceeded = false
                if case .rateLimited(let retryAfter) = error {
                    let delay = min(max(retryAfter ?? Self.rateLimitFloor, Self.rateLimitFloor),
                                    Self.rateLimitCeiling)
                    backoffUntil = Date().addingTimeInterval(delay)
                }
            }
        }
    }

    /// Synchronous lock scope. `NSLock.lock()` is marked `noasync`, so the async
    /// write-back path must funnel its critical section through a sync helper.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Both endpoints in parallel; at most one of them failing still yields a usable
    /// snapshot (tokens without quota, or quota without tokens).
    private static func fetchSnapshot(key: String,
                                      session: URLSession) async -> Result<OllamaUsageSnapshot, OllamaUsageError> {
        async let balanceRequest = fetchBalance(key: key, session: session)
        async let usageRequest = fetchUsage(key: key, session: session)
        let (balance, usage) = await (balanceRequest, usageRequest)
        return combine(balance: balance, usage: usage)
    }

    private static func fetchBalance(key: String,
                                     session: URLSession) async -> Result<OllamaBalance, OllamaUsageError> {
        switch await requestData(urlString: balanceURLString, key: key, session: session) {
        case .success(let data): return parseBalance(data)
        case .failure(let error): return .failure(error)
        }
    }

    private static func fetchUsage(key: String,
                                   session: URLSession) async -> Result<OllamaUsageTotals, OllamaUsageError> {
        switch await requestData(urlString: usageURLString, key: key, session: session) {
        case .success(let data): return parseUsage(data)
        case .failure(let error): return .failure(error)
        }
    }

    private static func requestData(urlString: String, key: String,
                                    session: URLSession) async -> Result<Data, OllamaUsageError> {
        guard let url = URL(string: urlString) else { return .failure(.network) }
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
            return .success(data)
        case 401:
            return .failure(.unauthorized)
        case 403:
            return .failure(.forbidden)
        case 429:
            return .failure(.rateLimited(retryAfter: retryAfterInterval(http)))
        default:
            return .failure(.http(http.statusCode))
        }
    }

    /// `Retry-After` is either a number of seconds or an HTTP date.
    private static func retryAfterInterval(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(trimmed) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    // MARK: - Combining

    private static func combine(balance: Result<OllamaBalance, OllamaUsageError>,
                                usage: Result<OllamaUsageTotals, OllamaUsageError>)
        -> Result<OllamaUsageSnapshot, OllamaUsageError> {
        var balanceValue: OllamaBalance?
        var usageValue: OllamaUsageTotals?
        var balanceError: OllamaUsageError?
        var usageError: OllamaUsageError?

        switch balance {
        case .success(let value): balanceValue = value
        case .failure(let error): balanceError = error
        }
        switch usage {
        case .success(let value): usageValue = value
        case .failure(let error): usageError = error
        }

        // A rejected key (or a blocked account) makes neither answer trustworthy.
        if let fatal = accountLevelError(balanceError, usageError) { return .failure(fatal) }

        guard balanceValue != nil || usageValue != nil else {
            return .failure(preferredError(balanceError, usageError) ?? .decoding)
        }

        return .success(OllamaUsageSnapshot(
            quotas: balanceValue?.quotas ?? placeholderQuotas,
            inputTokens: usageValue?.inputTokens ?? 0,
            outputTokens: usageValue?.outputTokens ?? 0,
            requestCount: usageValue?.requestCount ?? 0,
            costUSD: usageValue?.costUSD,
            allowanceUSD: balanceValue?.allowanceUSD,
            remainingUSD: balanceValue?.remainingUSD,
            purchasedUSD: balanceValue?.purchasedUSD,
            tokensAvailable: usageValue != nil,
            balanceAvailable: balanceValue != nil,
            partialFailure: balanceError ?? usageError))
    }

    /// Auth-style failures are never "partial": both endpoints share the same key.
    private static func accountLevelError(_ first: OllamaUsageError?,
                                         _ second: OllamaUsageError?) -> OllamaUsageError? {
        for error in [first, second].compactMap({ $0 }) {
            switch error {
            case .unauthorized, .forbidden: return error
            default: continue
            }
        }
        return nil
    }

    /// Pick the most actionable of two failures (a 503 is the least informative).
    private static func preferredError(_ first: OllamaUsageError?,
                                       _ second: OllamaUsageError?) -> OllamaUsageError? {
        let errors = [first, second].compactMap { $0 }
        return errors.min { rank($0) < rank($1) }
    }

    private static func rank(_ error: OllamaUsageError) -> Int {
        switch error {
        case .unauthorized: 0
        case .forbidden: 1
        case .rateLimited: 2
        case .network: 3
        case .decoding: 4
        case .http(let code): code == 503 ? 6 : 5
        case .noKey: 7
        }
    }

    // MARK: - Parsing

    /// Parses `/api/balance` into 1 quota row (credit plan) or 2 (legacy plan).
    /// Every field is optional on purpose: a surprise shape degrades to "剩余 --"
    /// instead of blanking the card.
    static func parseBalance(_ data: Data) -> Result<OllamaBalance, OllamaUsageError> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.decoding)
        }
        if let error = errorEnvelope(root) { return .failure(error) }
        guard let included = root["included"] as? [String: Any] else { return .failure(.decoding) }

        let purchased = (root["purchased"] as? [String: Any])
            .flatMap { number($0["balance_usd"]) }

        if let legacy = legacyQuotas(included) {
            return .success(OllamaBalance(quotas: legacy, allowanceUSD: nil,
                                          remainingUSD: nil, purchasedUSD: purchased))
        }

        let allowance = number(included["allowance_usd"])
        let remaining = number(included["balance_usd"])
        let period = included["period"] as? [String: Any]

        // used% only exists when there is a denominator; 0 allowance means the plan
        // has no included credits, so the row stays "剩余 --" rather than "剩余 100%".
        var usedPercent: Double?
        if let allowance, allowance > 0, let remaining {
            usedPercent = min(max((1 - remaining / allowance) * 100, 0), 100)
        }
        let quota = AgentQuota(usedPercent: usedPercent,
                               resetsAt: resetDate(period?["until"]),
                               resetIsEstimated: false,
                               windowLabel: "额度")
        return .success(OllamaBalance(quotas: [quota], allowanceUSD: allowance,
                                      remainingUSD: remaining, purchasedUSD: purchased))
    }

    /// Parses `/api/usage?range=24h` totals. Missing counters read as 0, not a failure.
    static func parseUsage(_ data: Data) -> Result<OllamaUsageTotals, OllamaUsageError> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.decoding)
        }
        if let error = errorEnvelope(root) { return .failure(error) }
        guard let totals = root["totals"] as? [String: Any] else { return .failure(.decoding) }

        return .success(OllamaUsageTotals(
            inputTokens: tokenCount(totals["input_tokens"]),
            outputTokens: tokenCount(totals["output_tokens"]),
            requestCount: Int(number(totals["request_count"]) ?? 0),
            costUSD: number(totals["usage_usd"])))
    }

    /// Legacy plans report what REMAINS; the dashboard stores what is USED.
    private static func legacyQuotas(_ included: [String: Any]) -> [AgentQuota]? {
        let windows = [("session", "会话"), ("weekly", "周")]
        var quotas: [AgentQuota] = []
        for (key, label) in windows {
            guard let window = included[key] as? [String: Any] else { continue }
            let remaining = number(window["remaining_percent"])
            let used = remaining.map { min(max(100 - $0, 0), 100) }
            quotas.append(AgentQuota(usedPercent: used,
                                     resetsAt: resetDate(window["resets_at"]),
                                     resetIsEstimated: false,
                                     windowLabel: label))
        }
        return quotas.isEmpty ? nil : quotas
    }

    /// `{"error":"invalid credentials"}` — the live shape of a 401 (error is a string).
    /// An unrecognised error body is a decoding problem, not an auth problem.
    private static func errorEnvelope(_ root: [String: Any]) -> OllamaUsageError? {
        let message: String?
        if let text = root["error"] as? String {
            message = text
        } else if let object = root["error"] as? [String: Any] {
            message = (object["message"] as? String) ?? (object["type"] as? String)
        } else {
            message = nil
        }
        guard let message, !message.isEmpty else { return nil }
        let lower = message.lowercased()
        if lower.contains("credential") || lower.contains("unauthor") || lower.contains("auth") {
            return .unauthorized
        }
        if lower.contains("suspend") || lower.contains("forbidden") {
            return .forbidden
        }
        return .decoding
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func tokenCount(_ value: Any?) -> UInt64 {
        guard let raw = number(value), raw > 0 else { return 0 }
        return UInt64(min(raw, Double(UInt64.max)))
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

        switch await fetchSnapshot(key: trimmed, session: session) {
        case .success(let snapshot):
            var parts: [String] = []
            if let quota = snapshot.quotas.first(where: { $0.usedPercent != nil }),
               let used = quota.usedPercent {
                parts.append("\(quota.windowLabel)剩余 \(Int((100 - used).rounded()))%")
            }
            if snapshot.tokensAvailable {
                parts.append("近24h In \(compactTokens(snapshot.inputTokens))"
                             + " / Out \(compactTokens(snapshot.outputTokens))")
            }
            if let purchased = snapshot.purchasedUSD, purchased > 0 {
                parts.append(String(format: "已购 $%.2f", purchased))
            }
            var verdict = "✅ 已连通"
            if !parts.isEmpty { verdict += " · " + parts.joined(separator: " · ") }
            if let partial = snapshot.partialFailure {
                verdict += "（\(partial.shortLabel)）"
            }
            return verdict
        case .failure(let error):
            switch error {
            case .unauthorized: return "❌ Key 无效（401）"
            case .forbidden: return "❌ 账户受限（403）"
            case .rateLimited: return "❌ 触发限流（429），请稍后再试"
            case .http(let code): return "❌ 服务异常（HTTP \(code)）"
            case .network: return "❌ 网络错误"
            case .decoding: return "❌ 解析失败"
            case .noKey: return "❌ 未配置 API Key"
            }
        }
    }

    /// 106000 → "106K", 1420000 → "1.4M".
    private static func compactTokens(_ value: UInt64) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
