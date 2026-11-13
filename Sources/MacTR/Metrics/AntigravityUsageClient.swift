// AntigravityUsageClient.swift — Antigravity (Google agent IDE) quota meter
//
// Antigravity has no public usage API and no API keys: it signs in with a Google
// account and enforces Pro-plan limits per model group. The IDE does, however,
// ship a local language server that already knows the numbers. This file talks to
// that server directly and never touches the account's OAuth tokens:
//
//   1. `ps` → the running `language_server` whose argv contains
//      `--app_data_dir antigravity` (or `antigravity-ide`) → `--csrf_token`
//   2. `lsof` → that pid's loopback listening ports
//   3. Connect-RPC (JSON over HTTP, HTTPS with a self-signed cert as fallback):
//
//        POST http://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
//        X-Codeium-Csrf-Token: <csrf_token>
//        Connect-Protocol-Version: 1
//        {}
//
// Canonical response (verified live against a Pro account):
//   {"response":{"groups":[
//     {"displayName":"Gemini Models","buckets":[
//        {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":1,"resetTime":"…Z"},
//        {"bucketId":"gemini-5h","window":"5h","remainingFraction":1,"resetTime":"…Z"}]},
//     {"displayName":"Claude and GPT models","buckets":[…3p-weekly, 3p-5h…]},
//     {"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"gemini-argon-wtu-weekly",…}]}
//   ]}}
//
// `remainingFraction` is what REMAINS (0…1), so used% = (1 - fraction) * 100.
// The card shows the Gemini group's two windows (5-hour + weekly); the other
// groups collapse into the activity line. Wrong/missing CSRF answers
// 401 {"code":"unauthenticated"} — the host-bridge sidecar ports answer 401 to
// everything, so a port only counts once it returns a 2xx summary.
//
// Everything is local and read-only. If Antigravity is not running the client
// reports `.notRunning` and makes no request; no credentials are stored or read.

import Foundation

// MARK: - Errors

enum AntigravityUsageError: Error, Equatable, Sendable {
    case notRunning
    case unreachable
    case unauthorized
    case decoding

    /// Compact text for the right-aligned status slot (`AgentUsage.statusLabel`).
    var shortLabel: String {
        switch self {
        case .notRunning: "未运行"
        case .unreachable: "未连接"
        case .unauthorized: "鉴权失败"
        case .decoding: "解析失败"
        }
    }

    /// One human sentence for the dashboard activity line.
    var message: String {
        switch self {
        case .notRunning:
            "启动 Antigravity 后自动恢复"
        case .unreachable:
            "无法连接 Antigravity 本地额度服务"
        case .unauthorized:
            "Antigravity 本地服务拒绝了 CSRF 校验"
        case .decoding:
            "Antigravity 返回了无法解析的额度数据"
        }
    }
}

// MARK: - Parsed values

/// One quota window inside a model group.
struct AntigravityBucket: Sendable {
    let bucketId: String
    let window: String          // "5h" / "weekly" / …
    let remainingFraction: Double?
    let resetAt: Date?
}

struct AntigravityGroup: Sendable {
    let displayName: String
    let buckets: [AntigravityBucket]
}

/// Everything one dashboard refresh needs.
struct AntigravityQuotaSnapshot: Sendable {
    /// Every window the app shows, ordered group-by-group (5小时 before 周):
    /// Gemini 5小时 / Gemini 周 / Claude/GPT 5小时 / Claude/GPT 周 / Argon 周.
    let quotas: [AgentQuota]
    /// Group names as reported by the IDE, e.g. ["Gemini Models", "…"].
    let groupNames: [String]
    /// One-line summary for the activity area, e.g. "Gemini · Claude/GPT · Argon".
    let activitySummary: String?
}

// MARK: - State

struct AntigravityUsageState: Sendable {
    let quotas: [AgentQuota]
    let activitySummary: String?
    let lastSuccessAt: Date?
    let lastError: AntigravityUsageError?
    let isRefreshing: Bool
}

// MARK: - Client

final class AntigravityUsageClient: @unchecked Sendable {

    // MARK: Constants

    private static let rpcPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let requestTimeout: TimeInterval = 2.5
    private static let successInterval: TimeInterval = 60
    private static let failureInterval: TimeInterval = 15
    /// Bounds a refresh when several sibling ports all hang.
    private static let maxAttempts = 6

    /// Rows shown before the first successful sync and while Antigravity is closed.
    /// Labels are the stable set a Pro account sees, so the card keeps its height.
    static let placeholderQuotas: [AgentQuota] = [
        "Gemini 5小时", "Gemini 周", "Claude/GPT 5小时", "Claude/GPT 周", "Argon 周",
    ].map { AgentQuota(usedPercent: nil, resetsAt: nil, resetIsEstimated: false,
                       windowLabel: $0) }

    /// A 189 pt compact card fits five dense rows; extra groups (if Google ever
    /// adds more) are dropped rather than overflowing the card.
    private static let maxQuotaRows = 5

    // MARK: State (guarded by `lock`)

    private let lock = NSLock()
    private var cachedQuotas: [AgentQuota] = AntigravityUsageClient.placeholderQuotas
    private var cachedSummary: String?
    private var lastSuccessAt: Date?
    private var lastError: AntigravityUsageError?
    private var lastAttemptAt: Date?
    private var lastAttemptSucceeded = false
    private var inFlight = false

    private let session: URLSession
    private let secureSession: URLSession
    private let trustDelegate = LoopbackTrustDelegate()

    init() {
        let sessions = Self.makeSessions()
        session = sessions.plain
        // The language server serves HTTPS with a self-signed cert; the trust
        // delegate below accepts it, and only 127.0.0.1 URLs ever use this session.
        secureSession = sessions.secure
    }

    /// Ephemeral sessions for the loopback RPC: plain HTTP first, TLS with a
    /// permissive trust delegate as the fallback.
    private static func makeSessions() -> (plain: URLSession, secure: URLSession) {
        func configuration() -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = requestTimeout
            configuration.timeoutIntervalForResource = requestTimeout
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.waitsForConnectivity = false
            return configuration
        }
        return (URLSession(configuration: configuration()),
                URLSession(configuration: configuration(),
                           delegate: LoopbackTrustDelegate(), delegateQueue: nil))
    }

    // MARK: - Public API

    /// Snapshot for the renderer. Cheap, lock-protected, never touches the network.
    func state() -> AntigravityUsageState {
        lock.lock()
        defer { lock.unlock() }
        return AntigravityUsageState(
            quotas: cachedQuotas,
            activitySummary: cachedSummary,
            lastSuccessAt: lastSuccessAt,
            lastError: lastError,
            isRefreshing: inFlight)
    }

    /// Called from the ~2 s metrics loop. Returns immediately; discovery and the
    /// local RPC run in a Task. Throttled to 60 s on success and 15 s on failure.
    func refreshIfNeeded() {
        let now = Date()
        lock.lock()
        guard !inFlight else { lock.unlock(); return }
        if let lastAttempt = lastAttemptAt {
            let interval = lastAttemptSucceeded ? Self.successInterval : Self.failureInterval
            if now.timeIntervalSince(lastAttempt) < interval { lock.unlock(); return }
        }
        inFlight = true
        lastAttemptAt = now
        lock.unlock()

        Task { await self.performRefresh() }
    }

    // MARK: - Refresh

    private func performRefresh() async {
        let result = await Self.query()

        withLock {
            inFlight = false
            switch result {
            case .success(let snapshot):
                cachedQuotas = snapshot.quotas
                cachedSummary = snapshot.activitySummary
                lastSuccessAt = Date()
                lastError = nil
                lastAttemptSucceeded = true
            case .failure(let error):
                // Keep the last known-good rows; the status slot explains the gap.
                lastError = error
                lastAttemptSucceeded = false
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

    /// Discovery + RPC. Every failure is a normal, reportable state — Antigravity
    /// simply may not be running.
    static func query() async -> Result<AntigravityQuotaSnapshot, AntigravityUsageError> {
        guard let server = findLanguageServer() else { return .failure(.notRunning) }
        let ports = listeningPorts(pid: server.pid)
        guard !ports.isEmpty else { return .failure(.unreachable) }

        let sessions = makeSessions()
        var attempts = 0
        var sawDecoding = false
        // Plain HTTP first (one less failure mode); HTTPS with a permissive trust
        // delegate covers builds that only expose TLS. Sibling host-bridge ports
        // answer 401 to everything, so an auth failure never ends the probe early.
        for secure in [false, true] {
            for port in ports {
                guard attempts < maxAttempts else { break }
                attempts += 1
                switch await fetchSummary(port: port, csrf: server.csrf, secure: secure,
                                          session: secure ? sessions.secure : sessions.plain) {
                case .success(let data):
                    switch parse(data) {
                    case .success(let snapshot): return .success(snapshot)
                    case .failure: sawDecoding = true
                    }
                case .failure:
                    continue
                }
            }
        }
        if sawDecoding { return .failure(.decoding) }
        return .failure(.unreachable)
    }

    // MARK: - Process / port discovery

    private struct LanguageServer {
        let pid: Int32
        let csrf: String
    }

    /// Finds the Antigravity language server that is signed in for this user.
    private static func findLanguageServer() -> LanguageServer? {
        guard let output = runProcess("/bin/ps", ["-axo", "pid=,uid=,command="]) else { return nil }
        let uid = getuid()
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.drop(while: { $0 == " " })
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  let processUID = UInt32(fields[1]),
                  processUID == uid
            else { continue }

            let command = String(fields[2])
            guard command.contains("language_server"), command.contains("--app_data_dir") else { continue }

            let args = command.split(separator: " ")
            guard let dataDirIndex = args.firstIndex(of: "--app_data_dir"),
                  dataDirIndex + 1 < args.count,
                  args[dataDirIndex + 1].hasPrefix("antigravity")
            else { continue }
            guard let tokenIndex = args.firstIndex(of: "--csrf_token"),
                  tokenIndex + 1 < args.count
            else { continue }

            return LanguageServer(pid: pid, csrf: String(args[tokenIndex + 1]))
        }
        return nil
    }

    /// Loopback TCP ports the process is listening on (`lsof -Fn` output).
    private static func listeningPorts(pid: Int32) -> [Int] {
        let output = runProcess("/usr/sbin/lsof",
                                ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN", "-Fn"])
            ?? runProcess("/usr/bin/lsof",
                          ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN", "-Fn"])
        guard let output else { return [] }

        var ports: Set<Int> = []
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            let address = line.dropFirst()
            guard address.hasPrefix("127.0.0.1:"), let port = Int(address.split(separator: ":").last ?? ""),
                  port > 0
            else { continue }
            ports.insert(port)
        }
        return ports.sorted()
    }

    /// Runs a helper binary and drains stdout while it runs (no pipe deadlock).
    private static func runProcess(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - RPC

    private static func fetchSummary(port: Int, csrf: String, secure: Bool,
                                     session: URLSession) async -> Result<Data, AntigravityUsageError> {
        let scheme = secure ? "https" : "http"
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(rpcPath)") else {
            return .failure(.unreachable)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failure(.unreachable)
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.unreachable) }
        switch http.statusCode {
        case 200...299:
            return .success(data)
        case 401, 403:
            return .failure(.unauthorized)
        default:
            return .failure(.unreachable)
        }
    }

    // MARK: - Parsing

    /// Parses a `RetrieveUserQuotaSummary` body. Pure and offline-testable.
    static func parse(_ data: Data) -> Result<AntigravityQuotaSnapshot, AntigravityUsageError> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.decoding)
        }
        // Connect unary responses are wrapped in `{"response": …}`; tolerate bare bodies.
        let payload = (root["response"] as? [String: Any]) ?? root
        guard let rawGroups = payload["groups"] as? [[String: Any]] else {
            return .failure(.decoding)
        }

        let groups: [AntigravityGroup] = rawGroups.compactMap { group in
            guard let name = group["displayName"] as? String else { return nil }
            let buckets: [AntigravityBucket] = (group["buckets"] as? [[String: Any]] ?? [])
                .compactMap { bucket in
                    guard let id = bucket["bucketId"] as? String else { return nil }
                    return AntigravityBucket(
                        bucketId: id,
                        window: (bucket["window"] as? String) ?? "",
                        remainingFraction: number(bucket["remainingFraction"]),
                        resetAt: resetDate(bucket["resetTime"]))
                }
            return buckets.isEmpty ? nil : AntigravityGroup(displayName: name, buckets: buckets)
        }
        guard !groups.isEmpty else { return .failure(.decoding) }

        return .success(AntigravityQuotaSnapshot(
            quotas: quotaRows(for: groups),
            groupNames: groups.map(\.displayName),
            activitySummary: groups.isEmpty ? nil : summary(for: groups)))
    }

    /// Every group's windows in the dashboard's convention (5-hour before weekly),
    /// labelled with a short group prefix: "Gemini 5小时", "Claude/GPT 周", "Argon 周".
    private static func quotaRows(for groups: [AntigravityGroup]) -> [AgentQuota] {
        var rows: [AgentQuota] = []
        for group in groups {
            let prefix = shortGroupName(group.displayName)
            let ordered = group.buckets.sorted { windowRank($0.window) < windowRank($1.window) }
            for bucket in ordered {
                guard rows.count < maxQuotaRows else { break }
                rows.append(AgentQuota(
                    usedPercent: bucket.remainingFraction.map { clampPercent((1 - $0) * 100) },
                    resetsAt: bucket.resetAt,
                    resetIsEstimated: false,
                    windowLabel: "\(prefix) \(windowLabel(bucket.window))"))
            }
        }
        return rows.isEmpty ? placeholderQuotas : rows
    }

    private static func windowRank(_ window: String) -> Int {
        switch window.lowercased() {
        case "5h", "five_hour", "session": 0
        case "weekly", "week", "7d": 1
        default: 2
        }
    }

    private static func windowLabel(_ window: String) -> String {
        switch window.lowercased() {
        case "5h", "five_hour", "session": "5小时"
        case "weekly", "week", "7d": "周"
        case "": "额度"
        default: window
        }
    }

    /// "Gemini · Claude/GPT · Argon · 本地实时" for the activity area.
    private static func summary(for groups: [AntigravityGroup]) -> String? {
        let names = groups.map { shortGroupName($0.displayName) }
        guard !names.isEmpty else { return nil }
        return names.joined(separator: " · ") + " · 本地实时读取"
    }

    /// "Claude and GPT models" → "Claude/GPT"; "Gemini 4 Argon" → "Argon".
    private static func shortGroupName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("claude") && (lower.contains("gpt") || lower.contains("3p")) {
            return "Claude/GPT"
        }
        if lower.contains("argon") { return "Argon" }
        if lower.contains("gemini") { return "Gemini" }
        return name
    }

    private static func clampPercent(_ value: Double) -> Double { min(max(value, 0), 100) }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    // MARK: - Diagnostics

    /// Human-readable verdict for the CLI probe. Never prints the CSRF token.
    static func probe() async -> String {
        guard let server = findLanguageServer() else {
            return "❌ Antigravity 未运行（未找到 language_server 进程）"
        }
        let ports = listeningPorts(pid: server.pid)
        guard !ports.isEmpty else {
            return "❌ 找到 language_server (pid \(server.pid))，但未发现 loopback 监听端口"
        }

        let portList = ports.map(String.init).joined(separator: ", ")
        let sessions = makeSessions()
        var attempts = 0
        var sawUnauthorized = false
        var sawDecoding = false
        for secure in [false, true] {
            for port in ports {
                guard attempts < maxAttempts else { break }
                attempts += 1
                switch await fetchSummary(port: port, csrf: server.csrf, secure: secure,
                                          session: secure ? sessions.secure : sessions.plain) {
                case .success(let data):
                    switch parse(data) {
                    case .success(let snapshot):
                        let rows = snapshot.quotas.map { quota -> String in
                            let remaining = quota.usedPercent.map { Int((100 - $0).rounded()) }
                            return "\(quota.windowLabel)剩余 \(remaining.map { "\($0)%" } ?? "—")"
                        }
                        let groups = snapshot.groupNames.joined(separator: " / ")
                        return "✅ 已连通 · 端口 \(portList) · \(groups) · "
                            + rows.joined(separator: " / ")
                    case .failure: sawDecoding = true
                    }
                case .failure(.unauthorized): sawUnauthorized = true
                case .failure: continue
                }
            }
        }
        if sawDecoding { return "❌ 端口 \(portList) 返回了无法解析的数据" }
        if sawUnauthorized { return "❌ 端口 \(portList) 均拒绝 CSRF 校验" }
        return "❌ 无法连接端口 \(portList)"
    }
}

// MARK: - TLS

/// The Antigravity language server serves HTTPS with a self-signed certificate.
/// This delegate accepts the loopback server trust; it is only wired to the
/// session used for 127.0.0.1 requests.
private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
