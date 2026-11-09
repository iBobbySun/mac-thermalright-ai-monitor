// AgentUsageCollector.swift — Claude Code / Codex CLI usage collection
//
// Parses local session transcripts to report today's token usage and the
// agent's latest activity:
//   Claude: ~/.claude/projects/<proj>/<session>.jsonl — per-message "usage"
//   Codex:  ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl — "token_count" events
//   Quota:  Claude Desktop usage history/audit + latest standard Codex rate-limit event
//
// Files are read incrementally (per-file byte offsets) so the steady-state
// cost per tick is one directory metadata snapshot plus any appended bytes —
// full parses happen only on first scan and day rollover.

import Foundation

// MARK: - Data Structures

struct AgentQuota: Sendable {
    let usedPercent: Double?        // rate-limit window usage, 0...100
    let resetsAt: Date?
    let resetIsEstimated: Bool      // true when inferred from local window samples
    let windowLabel: String         // e.g. "5小时" / "7天"
}

struct AgentUsage: Sendable {
    let available: Bool             // data directory exists at all
    let todayInputTokens: UInt64    // includes cache read/write tokens
    let todayOutputTokens: UInt64
    let secondsSinceActive: Int?    // nil = no session today
    let project: String?            // cwd basename of most recent session
    let activity: String?           // latest tool call / message summary
    let quotas: [AgentQuota]
    let needsAttention: Bool        // turn finished / waiting for user — flash the column
    let isWorking: Bool             // actively running a turn — slow breathing background
    let stepCurrent: Int?           // active plan step (1-based); nil = no plan
    let stepTotal: Int?             // total plan steps
    let stepText: String?           // description of the active step
    let tokensAvailable: Bool       // false = the source exposes no token counts (OpenCode API)
    let statusLabel: String?        // overrides the right-aligned "now / 12m ago / not found" text
    var todayTotalTokens: UInt64 { todayInputTokens + todayOutputTokens }

    init(available: Bool, todayInputTokens: UInt64, todayOutputTokens: UInt64,
         secondsSinceActive: Int?, project: String?, activity: String?,
         quotas: [AgentQuota] = [],
         needsAttention: Bool = false, isWorking: Bool = false,
         stepCurrent: Int? = nil, stepTotal: Int? = nil, stepText: String? = nil,
         tokensAvailable: Bool = true, statusLabel: String? = nil) {
        self.available = available
        self.todayInputTokens = todayInputTokens
        self.todayOutputTokens = todayOutputTokens
        self.secondsSinceActive = secondsSinceActive
        self.project = project
        self.activity = activity
        self.quotas = quotas
        self.needsAttention = needsAttention
        self.isWorking = isWorking
        self.stepCurrent = stepCurrent
        self.stepTotal = stepTotal
        self.stepText = stepText
        self.tokensAvailable = tokensAvailable
        self.statusLabel = statusLabel
    }
}

struct AgentsSnapshot: Sendable {
    let claude: AgentUsage
    let codex: AgentUsage
    let opencode: AgentUsage
}

// MARK: - Collector

final class AgentUsageCollector: @unchecked Sendable {

    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let fileResourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
    ]

    /// API-backed quota source for OpenCode Zen (no local transcripts to read).
    /// The client does its own throttling and never blocks this collector's thread.
    private let openCodeClient = OpenCodeUsageClient()

    private lazy var localDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private lazy var sessionDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()
    private lazy var timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private struct FileStamp: Equatable {
        let modificationDate: Date
        let size: UInt64
    }

    private struct SessionFile {
        let path: String
        let modificationDate: Date
        let size: UInt64
        var stamp: FileStamp { FileStamp(modificationDate: modificationDate, size: size) }
    }

    private typealias ClaudeRateLimitReading = (
        type: String?, used: Double?, resets: Date?, timestamp: String
    )
    private struct CachedClaudeReadings {
        let stamp: FileStamp
        let readings: [ClaudeRateLimitReading]
    }

    /// A reset boundary carried across launches so it outlives the source that
    /// produced it — Claude Desktop's history stops sampling while the app is closed,
    /// and a 429's `quotaLimits` block scrolls out of the transcript tail.
    private struct PersistedReset {
        let resetsAt: Date
        let isEstimated: Bool
    }

    private static let fiveHourTypes: Set<String> = ["five_hour"]
    private static let sevenDayTypes: Set<String> = [
        "seven_day", "seven_day_opus", "seven_day_sonnet",
        "seven_day_oauth_apps", "seven_day_overage_included",
    ]
    private static let sevenDayWindow: TimeInterval = 7 * 24 * 60 * 60
    private static let quotaLimitScanFileLimit = 24
    private static let quotaLimitInitialScanBytes: UInt64 = 2 * 1024 * 1024
    private static let fiveHourWindowKey = "claudeQuota.fiveHour"
    private static let sevenDayWindowKey = "claudeQuota.sevenDay"
    private static let resetsAtSuffix = ".resetsAt"
    private static let estimatedSuffix = ".estimated"

    private struct CodexQuotaReading {
        let quotas: [AgentQuota]
        let timestamp: String
    }
    private struct CachedCodexQuotaFile {
        let stamp: FileStamp
        let reading: CodexQuotaReading?
    }

    // Session directories older than yesterday cannot receive a cross-midnight active
    // session append under Codex's current file layout, so cache their prefetched URL
    // metadata after the first scan. If Codex starts resuming older session files, this
    // cache must be invalidated or removed.
    private var historicalCodexFiles: [String: [SessionFile]] = [:]
    private var claudeAuditCache: [String: CachedClaudeReadings] = [:]
    // Rejected-request readings are accumulated across ticks rather than re-derived:
    // offsets advance past lines already seen, and the newest reading per rate-limit
    // type is retained for the lifetime of the process.
    private var claudeQuotaLimitOffsets: [String: UInt64] = [:]
    private var claudeQuotaLimitByType: [String: ClaudeRateLimitReading] = [:]
    private var codexQuotaFileCache: [String: CachedCodexQuotaFile] = [:]

    // Incremental state, reset on day rollover
    private var dayKey = ""
    private var todayStartISO = ""      // lexical threshold for ISO8601 "Z" timestamps
    private var claudeOffsets: [String: UInt64] = [:]
    private var claudeSeenIDs: Set<String> = []
    private var claudeInput: UInt64 = 0
    private var claudeOutput: UInt64 = 0
    private var codexOffsets: [String: UInt64] = [:]
    private var codexInput: UInt64 = 0
    private var codexOutput: UInt64 = 0

    // Attention edge tracking — flash only for the first N seconds after the
    // waiting/done state appears, not for as long as it persists
    private let flashDuration: TimeInterval = 10
    private var claudePrevAttention = false
    private var claudeAttentionSince: Date?
    private var codexPrevAttention = false
    private var codexAttentionSince: Date?

    // Claude Desktop writes small, local-only usage samples plus the active limit's
    // reset time. Cache both plan windows so the high-frequency metrics loop does not
    // repeatedly traverse Desktop session directories.
    private var claudeQuotaCache: [AgentQuota] = [
        AgentQuota(usedPercent: nil, resetsAt: nil,
                   resetIsEstimated: false, windowLabel: "5小时"),
        AgentQuota(usedPercent: nil, resetsAt: nil,
                   resetIsEstimated: false, windowLabel: "7天"),
    ]
    private var claudeQuotaLastRefresh: Date?
    private let claudeQuotaRefreshInterval: TimeInterval = 5 * 60

    // Last-known Codex quota (account-global). The full rate-limit block appears only
    // occasionally and the newest reading may be in a different file than the active
    // one, so we track the newest-by-timestamp across recent files and cache it.
    private var codexQuotaCache: [AgentQuota] = [
        AgentQuota(usedPercent: nil, resetsAt: nil,
                   resetIsEstimated: false, windowLabel: "5小时"),
        AgentQuota(usedPercent: nil, resetsAt: nil,
                   resetIsEstimated: false, windowLabel: "7天"),
    ]
    private var codexQuotaTS = ""            // process-lifetime timestamp high-water mark
    private var codexQuotaLastRefresh: Date?
    private let codexQuotaRefreshInterval: TimeInterval = 5 * 60

    func collect() -> AgentsSnapshot {
        rolloverIfNeeded()
        return AgentsSnapshot(claude: collectClaude(), codex: collectCodex(),
                              opencode: collectOpenCode())
    }

    /// Reset accumulators at local midnight. Timestamps in both formats are
    /// UTC ISO8601 ("...Z"), so "today" = lexical compare against the local
    /// midnight rendered in UTC.
    private func rolloverIfNeeded() {
        let key = localDayFormatter.string(from: Date())
        guard key != dayKey else { return }
        dayKey = key

        todayStartISO = timestampFormatter.string(from: Calendar.current.startOfDay(for: Date()))

        claudeOffsets = [:]; claudeSeenIDs = []; claudeInput = 0; claudeOutput = 0
        codexOffsets = [:]; codexInput = 0; codexOutput = 0
    }

    // MARK: - Claude

    private func collectClaude() -> AgentUsage {
        updateClaudeQuota()
        let quota = claudeQuotaCache
        let root = home + "/.claude/projects"
        guard fm.fileExists(atPath: root) else {
            return AgentUsage(available: false, todayInputTokens: 0, todayOutputTokens: 0,
                              secondsSinceActive: nil, project: nil, activity: nil,
                              quotas: quota)
        }

        let todayStart = Calendar.current.startOfDay(for: Date())
        var latestPath: String?
        var latestMtime = Date.distantPast

        for projDir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dirPath = root + "/" + projDir
            for file in sessionFiles(in: dirPath, cacheHistorical: false) {
                // Latest session overall (any day) — drives the activity/project
                // display so the column isn't blank on a day with no runs yet
                if file.modificationDate > latestMtime {
                    latestMtime = file.modificationDate
                    latestPath = file.path
                }

                // Token counting is scoped to today only
                guard file.modificationDate >= todayStart else { continue }
                consumeNewLines(path: file.path, size: file.size, offsets: &claudeOffsets,
                                prefilter: "\"type\":\"assistant\"") { line in
                    self.accumulateClaudeLine(line)
                }
            }
        }

        var project: String?
        var activity: String?
        var secondsAgo: Int?
        var attention = false
        var working = false
        var step: (current: Int, total: Int, text: String)?
        if let path = latestPath {
            let ago = max(0, Int(Date().timeIntervalSince(latestMtime)))
            secondsAgo = ago
            let rawWaiting: Bool
            (project, activity, rawWaiting, step) = claudeActivity(path: path)
            // Actively running = not waiting on the user AND the file just changed
            working = !rawWaiting && ago < 90
            attention = rawWaiting
            // Only flash for recent events — stale sessions shouldn't blink all day
            attention = attention && ago < 900
            // Rising edge starts a 10s flash window; afterwards the state may
            // persist (still waiting) but the flashing stops
            if attention && !claudePrevAttention { claudeAttentionSince = Date() }
            claudePrevAttention = attention
            if attention, let since = claudeAttentionSince,
               Date().timeIntervalSince(since) >= flashDuration {
                attention = false
            }
        }
        return AgentUsage(available: true, todayInputTokens: claudeInput,
                          todayOutputTokens: claudeOutput,
                          secondsSinceActive: secondsAgo,
                          project: project, activity: activity,
                          quotas: quota,
                          needsAttention: attention, isWorking: working,
                          stepCurrent: step?.current, stepTotal: step?.total,
                          stepText: step?.text)
    }

    private func accumulateClaudeLine(_ line: String) {
        guard let obj = parseJSON(line),
              obj["type"] as? String == "assistant",
              let ts = obj["timestamp"] as? String, ts >= todayStartISO,
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any]
        else { return }
        // Dedupe: continued/forked sessions copy earlier entries into new files
        if let id = msg["id"] as? String {
            guard claudeSeenIDs.insert(id).inserted else { return }
        }
        claudeInput += uint(usage["input_tokens"])
            + uint(usage["cache_creation_input_tokens"])
            + uint(usage["cache_read_input_tokens"])
        claudeOutput += uint(usage["output_tokens"])
    }

    /// Claude Desktop persists plan utilization locally in `plan-usage-history.json`,
    /// but that file carries percentages only. Exact reset epochs come from the two
    /// places Claude records the server's answer: a rejected request's `quotaLimits`
    /// block in the session transcript, and — on Desktop builds before 1.34493 —
    /// `rate_limit_info` in the session audit. Whatever is resolved is persisted, so a
    /// boundary observed once survives Claude Desktop being closed (which stops the
    /// history sampling that the estimator depends on).
    /// Every read is local and credential-free; no API request or subprocess is used.
    private func updateClaudeQuota() {
        if let last = claudeQuotaLastRefresh,
           Date().timeIntervalSince(last) < claudeQuotaRefreshInterval {
            return
        }
        claudeQuotaLastRefresh = Date()
        let now = Date()

        var historySamples: [(date: Date, fiveHour: Double?, sevenDay: Double?)] = []
        let historyPath = home + "/Library/Application Support/Claude/plan-usage-history.json"
        if let data = fm.contents(atPath: historyPath),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let samples = root["samples"] as? [[String: Any]] {
            for sample in samples {
                guard var epoch = (sample["t"] as? NSNumber)?.doubleValue,
                      let usage = sample["u"] as? [String: Any], !usage.isEmpty
                else { continue }
                if epoch > 10_000_000_000 { epoch /= 1000 }
                historySamples.append((
                    Date(timeIntervalSince1970: epoch),
                    (usage["fh"] as? NSNumber)?.doubleValue,
                    (usage["sd"] as? NSNumber)?.doubleValue
                ))
            }
            historySamples.sort { $0.date < $1.date }
        }
        let latest = historySamples.last

        // An expired reading remains useful history but must not dictate the active
        // window, so `newestReading` keeps only resets that are still ahead of us.
        let readings = claudeRateLimitReadings() + claudeQuotaLimitReadings()
        let fiveHourReading = newestReading(readings, matching: Self.fiveHourTypes, now: now)
        let sevenDayReading = newestReading(readings, matching: Self.sevenDayTypes, now: now)

        let estimatedFiveHour = fiveHourReading == nil
            ? estimatedFiveHourReset(
                samples: historySamples.map { ($0.date, $0.fiveHour) }, now: now
            )
            : nil
        let fiveHourReset = resolveReset(window: Self.fiveHourWindowKey,
                                         exact: fiveHourReading?.resets,
                                         estimate: estimatedFiveHour)
        let sevenDayReset = resolveReset(window: Self.sevenDayWindowKey,
                                         exact: sevenDayReading?.resets,
                                         estimate: nil)

        let fiveHourUsed = fiveHourReading.flatMap { $0.used } ?? latest?.fiveHour
        let sevenDayUsed = sevenDayReading.flatMap { $0.used } ?? latest?.sevenDay

        claudeQuotaCache = [
            AgentQuota(
                usedPercent: fiveHourUsed.map { min(max($0, 0), 100) },
                resetsAt: fiveHourReset?.resetsAt,
                resetIsEstimated: fiveHourReset?.isEstimated ?? false,
                windowLabel: "5小时"),
            AgentQuota(
                usedPercent: sevenDayUsed.map { min(max($0, 0), 100) },
                resetsAt: sevenDayReset?.resetsAt,
                resetIsEstimated: sevenDayReset?.isEstimated ?? false,
                windowLabel: "7天"),
        ]
    }

    /// Newest still-active reading for one window family.
    private func newestReading(_ readings: [ClaudeRateLimitReading],
                               matching types: Set<String>,
                               now: Date) -> ClaudeRateLimitReading? {
        var best: ClaudeRateLimitReading?
        for reading in readings {
            guard let type = reading.type, types.contains(type),
                  let resets = reading.resets, resets > now else { continue }
            if best == nil || reading.timestamp > best!.timestamp { best = reading }
        }
        return best
    }

    /// Merge a freshly derived boundary with the stored one. An exact reading always
    /// wins; an estimate only replaces another estimate, so a known-good epoch is not
    /// downgraded when the 429 that produced it scrolls out of the scan window. A
    /// stored boundary that has passed is dropped — the window has rolled over.
    private func resolveReset(window: String, exact: Date?, estimate: Date?) -> PersistedReset? {
        let now = Date()
        let stored = loadPersistedReset(window)
        let active = stored.flatMap { $0.resetsAt > now ? $0 : nil }
        var resolved = active
        if let exact, exact > now {
            resolved = PersistedReset(resetsAt: exact, isEstimated: false)
        } else if let estimate, estimate > now, active?.isEstimated ?? true {
            resolved = PersistedReset(resetsAt: estimate, isEstimated: true)
        }
        // Comparing against the raw stored value also clears a boundary that has
        // passed with nothing to replace it yet.
        if resolved?.resetsAt != stored?.resetsAt || resolved?.isEstimated != stored?.isEstimated {
            persistReset(window, resolved)
        }
        return resolved
    }

    private func loadPersistedReset(_ window: String) -> PersistedReset? {
        let defaults = UserDefaults.standard
        let epoch = defaults.double(forKey: window + Self.resetsAtSuffix)
        guard epoch > 0 else { return nil }
        return PersistedReset(resetsAt: Date(timeIntervalSince1970: epoch),
                              isEstimated: defaults.bool(forKey: window + Self.estimatedSuffix))
    }

    private func persistReset(_ window: String, _ reset: PersistedReset?) {
        let defaults = UserDefaults.standard
        guard let reset else {
            defaults.removeObject(forKey: window + Self.resetsAtSuffix)
            defaults.removeObject(forKey: window + Self.estimatedSuffix)
            return
        }
        defaults.set(reset.resetsAt.timeIntervalSince1970, forKey: window + Self.resetsAtSuffix)
        defaults.set(reset.isEstimated, forKey: window + Self.estimatedSuffix)
    }

    /// Estimate the active five-hour window only when history contains a credible
    /// boundary: a drop/reset followed by use, or a zero sample immediately before
    /// the first positive sample. Claude reports reset boundaries on ten-minute
    /// marks, so round the bracket midpoint before adding the five-hour window.
    private func estimatedFiveHourReset(
        samples: [(date: Date, used: Double?)], now: Date
    ) -> Date? {
        let values = samples.compactMap { sample -> (date: Date, used: Double)? in
            guard let used = sample.used else { return nil }
            return (sample.date, used)
        }.sorted { $0.date < $1.date }
        guard let latest = values.last,
              latest.used > 0,
              now.timeIntervalSince(latest.date) >= -5 * 60,
              now.timeIntervalSince(latest.date) <= 30 * 60
        else { return nil }

        var segmentStart = 0
        if values.count > 1 {
            for index in 1..<values.count {
                let previous = values[index - 1].used
                let current = values[index].used
                if (current <= 0 && previous > 0) || previous - current >= 10 {
                    segmentStart = index
                }
            }
        }

        guard let firstPositive = values[segmentStart...].firstIndex(where: { $0.used > 0 })
        else { return nil }

        let estimatedStart: Date
        if firstPositive > segmentStart,
           values[firstPositive - 1].used <= 0,
           values[firstPositive].date.timeIntervalSince(values[firstPositive - 1].date) <= 30 * 60 {
            let lower = values[firstPositive - 1].date
            let upper = values[firstPositive].date
            estimatedStart = lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
        } else if segmentStart > 0 {
            estimatedStart = values[firstPositive].date
        } else {
            return nil
        }

        let tenMinutes: TimeInterval = 10 * 60
        let roundedStart = Date(timeIntervalSince1970:
            (estimatedStart.timeIntervalSince1970 / tenMinutes).rounded() * tenMinutes)
        let reset = roundedStart.addingTimeInterval(5 * 60 * 60)
        return reset > now ? reset : nil
    }

    /// Rate-limit readings from Claude Desktop's session audits. Desktop 1.34493
    /// stopped appending these, so on current builds this yields nothing and the
    /// transcript scan below carries the load; older audit files still parse.
    private func claudeRateLimitReadings() -> [ClaudeRateLimitReading] {
        let base = home + "/Library/Application Support/Claude/local-agent-mode-sessions"
        var auditFiles: [SessionFile] = []
        for account in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
            let accountPath = base + "/" + account
            for profile in (try? fm.contentsOfDirectory(atPath: accountPath)) ?? [] {
                let profilePath = accountPath + "/" + profile
                for environment in (try? fm.contentsOfDirectory(atPath: profilePath)) ?? [] {
                    let path = profilePath + "/" + environment + "/audit.jsonl"
                    if let file = sessionFile(at: path) { auditFiles.append(file) }
                }
            }
        }
        return cachedReadings(for: auditFiles, cache: &claudeAuditCache,
                              scan: scanClaudeRateLimit)
    }

    /// Exact reset epochs recovered from rejected requests. Claude records the
    /// server's authoritative `quotaLimits` block on the assistant entry of a 429,
    /// which is the only live source left on current Desktop builds — the cost is
    /// that it only appears once a window has actually been exhausted.
    ///
    /// Read by byte offset rather than from a fixed tail: a rejected turn is followed
    /// by however much work the session does once the window reopens, which on a real
    /// transcript pushes the record hundreds of KB back within hours. Offsets see each
    /// appended line exactly once, so depth of history stops mattering after first sight.
    private func claudeQuotaLimitReadings() -> [ClaudeRateLimitReading] {
        let root = home + "/.claude/projects"
        // A reset epoch cannot outlive the longest window, so transcripts untouched
        // for longer than that can no longer hold an active one.
        let cutoff = Date().addingTimeInterval(-Self.sevenDayWindow)
        var files: [SessionFile] = []
        for projectDir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for file in sessionFiles(in: root + "/" + projectDir, cacheHistorical: false)
            where file.modificationDate >= cutoff {
                files.append(file)
            }
        }
        files.sort { $0.modificationDate > $1.modificationDate }
        files = Array(files.prefix(Self.quotaLimitScanFileLimit))

        let currentPaths = Set(files.map(\.path))
        claudeQuotaLimitOffsets = claudeQuotaLimitOffsets.filter { currentPaths.contains($0.key) }
        for file in files {
            if claudeQuotaLimitOffsets[file.path] == nil {
                // First sight: skip the bulk of an existing transcript but reach back far
                // enough to cover a rejection plus the work that followed it. The seek can
                // land mid-line; that one truncated line fails to parse and is dropped.
                claudeQuotaLimitOffsets[file.path] = file.size > Self.quotaLimitInitialScanBytes
                    ? file.size - Self.quotaLimitInitialScanBytes
                    : 0
            }
            consumeNewLines(path: file.path, size: file.size,
                            offsets: &claudeQuotaLimitOffsets,
                            prefilter: "\"quotaLimits\"") { line in
                self.absorbClaudeQuotaLimitLine(line)
            }
        }
        return Array(claudeQuotaLimitByType.values)
    }

    /// Keep the newest reading per rate-limit type. The literal also occurs inside
    /// message text (a transcript that discusses this format); requiring the key at
    /// the top level of the record rejects those.
    private func absorbClaudeQuotaLimitLine(_ line: String) {
        guard let obj = parseJSON(line),
              let timestamp = obj["timestamp"] as? String,
              let limits = obj["quotaLimits"] as? [String: Any],
              var epoch = ((limits["resetsAt"] ?? limits["resets_at"]) as? NSNumber)?.doubleValue
        else { return }
        let type = (limits["rateLimitType"] ?? limits["rate_limit_type"]) as? String
        let key = type ?? ""
        if let current = claudeQuotaLimitByType[key], timestamp <= current.timestamp { return }
        if epoch > 10_000_000_000 { epoch /= 1000 }
        // A rejected request means the window is spent, whatever the last local
        // utilization sample happened to say.
        let used: Double? = (limits["status"] as? String) == "rejected" ? 100 : nil
        claudeQuotaLimitByType[key] = (type, used, Date(timeIntervalSince1970: epoch), timestamp)
    }

    /// Re-scan only the files whose size or mtime moved, then flatten the cache.
    private func cachedReadings(for files: [SessionFile],
                                cache: inout [String: CachedClaudeReadings],
                                scan: (String) -> [ClaudeRateLimitReading])
        -> [ClaudeRateLimitReading] {
        let currentPaths = Set(files.map(\.path))
        cache = cache.filter { currentPaths.contains($0.key) }
        for file in files {
            if cache[file.path]?.stamp == file.stamp { continue }
            cache[file.path] = CachedClaudeReadings(stamp: file.stamp,
                                                    readings: scan(file.path))
        }
        return cache.values.flatMap(\.readings)
    }

    private func scanClaudeRateLimit(path: String) -> [ClaudeRateLimitReading] {
        // Desktop usually emits the event near the audit header; newer versions append
        // refreshed events. A 256 KB head + tail covers both without 16 MB reads.
        let chunks = [
            tailLines(path: path, maxBytes: 256 * 1024),
            tailLines(path: path, maxBytes: 0, headBytes: 256 * 1024),
        ]
        // Keyed by rate-limit type: one file can carry both windows, and keeping only
        // the newest entry overall would hide the other one.
        var newestByType: [String: ClaudeRateLimitReading] = [:]
        for lines in chunks {
            for line in lines.reversed() {
                guard hasLiteral(line, "\"rate_limit_info\""),
                      let obj = parseJSON(line),
                      let timestamp = obj["timestamp"] as? String,
                      let info = obj["rate_limit_info"] as? [String: Any]
                else { continue }
                let type = (info["rateLimitType"] ?? info["rate_limit_type"]) as? String
                if let current = newestByType[type ?? ""], timestamp <= current.timestamp {
                    continue
                }
                var used = (info["utilization"] as? NSNumber)?.doubleValue
                if let value = used, value <= 1 { used = value * 100 }
                var resets: Date?
                if var epoch = ((info["resetsAt"] ?? info["resets_at"]) as? NSNumber)?.doubleValue {
                    if epoch > 10_000_000_000 { epoch /= 1000 }
                    resets = Date(timeIntervalSince1970: epoch)
                }
                newestByType[type ?? ""] = (type, used, resets, timestamp)
            }
        }
        return Array(newestByType.values)
    }

    /// From the tail of the most recent session: project, the last thing Claude SAID
    /// (its latest text block, markdown preserved — never tool calls), the flash state,
    /// and TodoWrite plan progress.
    /// Attention heuristic: the LAST significant main-chain entry decides —
    ///   assistant text-only  → turn ended, Claude is waiting for the user → true
    ///   assistant tool_use   → still working → false
    ///   user-typed message   → user already responded → false
    private func claudeActivity(path: String)
        -> (project: String?, activity: String?, attention: Bool,
            step: (current: Int, total: Int, text: String)?) {
        var project: String?
        var message: String?
        var attention = false
        var stateDetermined = false
        var crossedUserTurn = false   // scanned past a real user message → older todos are stale
        var step: (Int, Int, String)?
        for line in tailLines(path: path, maxBytes: 256 * 1024).reversed() {
            let isAssistant = hasLiteral(line, "\"type\":\"assistant\"")
            let isUser = hasLiteral(line, "\"type\":\"user\"")
            guard isAssistant || isUser, let obj = parseJSON(line) else { continue }
            // Subagent side chains don't reflect the main conversation state
            if obj["isSidechain"] as? Bool == true { continue }

            if isUser, obj["type"] as? String == "user" {
                // A real user message (not a tool_result) is a turn boundary: a
                // TodoWrite older than it belongs to a finished request → stale.
                if isRealUserMessage(obj) { crossedUserTurn = true }
                if !stateDetermined {
                    attention = false
                    stateDetermined = true
                }
                continue
            }

            guard obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any]
            else { continue }
            if project == nil, let cwd = obj["cwd"] as? String {
                project = (cwd as NSString).lastPathComponent
            }
            var sawToolUse = false
            if let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    switch block["type"] as? String {
                    case "tool_use":
                        sawToolUse = true
                        // TodoWrite from the CURRENT turn only (before any user boundary)
                        if step == nil, !crossedUserTurn,
                           block["name"] as? String == "TodoWrite",
                           let input = block["input"] as? [String: Any],
                           let todos = input["todos"] as? [[String: Any]] {
                            step = parseClaudeTodos(todos)
                        }
                    case "text":
                        // The message Claude spoke — markdown preserved for table layout
                        if message == nil {
                            let t = cleanMultiline(block["text"] as? String ?? "")
                            if !t.isEmpty { message = t }
                        }
                    default:
                        break
                    }
                }
            }
            if !stateDetermined {
                attention = !sawToolUse   // text-only final message → your turn
                stateDetermined = true
            }
            // Stop once the message + state are known and the step is either found
            // or can no longer appear (we've passed the current user turn)
            if message != nil && stateDetermined && (step != nil || crossedUserTurn) { break }
        }
        return (project, message, attention, step)
    }

    /// A real user request, as opposed to a tool_result the harness feeds back mid-turn.
    private func isRealUserMessage(_ obj: [String: Any]) -> Bool {
        guard let msg = obj["message"] as? [String: Any] else { return false }
        if msg["content"] is String { return true }
        if let content = msg["content"] as? [[String: Any]] {
            return content.contains { ($0["type"] as? String) != "tool_result" }
        }
        return false
    }

    /// Claude TodoWrite todos → (currentStep, totalSteps, text). Same rule as Codex.
    private func parseClaudeTodos(_ todos: [[String: Any]]) -> (Int, Int, String)? {
        let items = todos.compactMap { t -> (text: String, status: String)? in
            guard let content = t["content"] as? String,
                  let status = t["status"] as? String else { return nil }
            let active = t["activeForm"] as? String
            return (status == "in_progress" ? (active ?? content) : content, status)
        }
        guard !items.isEmpty else { return nil }
        let total = items.count
        if let i = items.firstIndex(where: { $0.status == "in_progress" }) {
            return (i + 1, total, clean(items[i].text))
        }
        if let i = items.firstIndex(where: { $0.status != "completed" }) {
            return (i + 1, total, clean(items[i].text))
        }
        return (total, total, clean(items.last?.text ?? ""))
    }

    // MARK: - OpenCode (API-backed)

    /// OpenCode Zen exposes its subscription windows over HTTPS rather than in local
    /// session files. The client refreshes itself in the background (throttled to
    /// 60 s on success / 30 s on failure, one request in flight), so the high-frequency
    /// metrics loop only pays for a lock-guarded snapshot read here.
    ///
    /// The status slot semantics:
    ///   unconfigured      → 未配置
    ///   configured, first → 同步中
    ///   success           → nil (renderer shows "now" / "Xm ago" from secondsSinceActive)
    ///   failure           → error.shortLabel, last known quotas kept
    private func collectOpenCode() -> AgentUsage {
        openCodeClient.refreshIfNeeded()
        let state = openCodeClient.state()
        let age = state.lastSuccessAt.map { max(0, Int(Date().timeIntervalSince($0))) }

        guard state.isConfigured else {
            return AgentUsage(
                available: false, todayInputTokens: 0, todayOutputTokens: 0,
                secondsSinceActive: nil, project: "OpenCode Zen",
                activity: "在 设置 → Agents 中填入 OpenCode API Key",
                quotas: OpenCodeUsageClient.placeholderQuotas,
                tokensAvailable: false,
                statusLabel: "未配置")
        }

        if let error = state.lastError {
            return AgentUsage(
                available: true, todayInputTokens: 0, todayOutputTokens: 0,
                secondsSinceActive: age, project: "OpenCode Zen",
                activity: "刷新失败：\(error.message)（将自动重试）",
                quotas: state.quotas,
                tokensAvailable: false,
                statusLabel: error.shortLabel)
        }

        // Configured but the first response hasn't landed yet.
        guard state.lastSuccessAt != nil else {
            return AgentUsage(
                available: true, todayInputTokens: 0, todayOutputTokens: 0,
                secondsSinceActive: nil, project: "OpenCode Zen",
                activity: "正在获取 OpenCode 额度…",
                quotas: state.quotas,
                tokensAvailable: false,
                statusLabel: "同步中")
        }

        return AgentUsage(
            available: true, todayInputTokens: 0, todayOutputTokens: 0,
            secondsSinceActive: age, project: "OpenCode Zen",
            activity: "订阅额度实时同步 · 每 60 秒刷新",
            quotas: state.quotas,
            tokensAvailable: false,
            statusLabel: nil)
    }

    // MARK: - Codex

    private func collectCodex() -> AgentUsage {
        let root = home + "/.codex/sessions"
        guard fm.fileExists(atPath: root) else {
            return AgentUsage(available: false, todayInputTokens: 0, todayOutputTokens: 0,
                              secondsSinceActive: nil, project: nil, activity: nil)
        }

        // Session dirs are keyed by START date. Scan a rolling window of recent
        // days: today+yesterday for token counting (a session can span midnight),
        // plus older days only to locate the most recent session for the
        // activity/quota display when nothing has run today.
        let todayStart = Calendar.current.startOfDay(for: Date())
        var dirs: [(path: String, cacheHistorical: Bool)] = []
        for back in 0..<14 {
            if let d = Calendar.current.date(byAdding: .day, value: -back, to: Date()) {
                dirs.append((root + "/" + sessionDayFormatter.string(from: d), back >= 2))
            }
        }

        var latestPath: String?
        var latestMtime = Date.distantPast

        for dir in dirs {
            for file in sessionFiles(in: dir.path, cacheHistorical: dir.cacheHistorical) {
                // Latest session overall — drives activity/quota display
                if file.modificationDate > latestMtime {
                    latestMtime = file.modificationDate
                    latestPath = file.path
                }

                // Token counting is scoped to today only
                guard file.modificationDate >= todayStart else { continue }
                consumeNewLines(path: file.path, size: file.size, offsets: &codexOffsets,
                                prefilter: "\"token_count\"") { line in
                    self.accumulateCodexLine(line)
                }
            }
        }

        // Quota is account-global: the newest reading may live in a DIFFERENT session
        // file than the most-recently-modified one, so scan across recent files by
        // timestamp (throttled — it changes slowly).
        updateCodexQuota()

        var project: String?
        var activity: String?
        var secondsAgo: Int?
        let quotas = codexQuotaCache
        var attention = false
        var working = false
        var step: (current: Int, total: Int, text: String)?
        if let path = latestPath {
            let ago = max(0, Int(Date().timeIntervalSince(latestMtime)))
            secondsAgo = ago
            let rawWaiting: Bool
            let sessionTail = tailLines(path: path, maxBytes: 512 * 1024)
            (project, activity, rawWaiting) = codexActivity(path: path, tailLines: sessionTail)
            step = codexPlan(lines: sessionTail)
            // Actively running = not waiting on the user AND the file just changed
            working = !rawWaiting && ago < 90
            attention = rawWaiting && ago < 900
            if attention && !codexPrevAttention { codexAttentionSince = Date() }
            codexPrevAttention = attention
            if attention, let since = codexAttentionSince,
               Date().timeIntervalSince(since) >= flashDuration {
                attention = false
            }
        }
        return AgentUsage(available: true, todayInputTokens: codexInput,
                          todayOutputTokens: codexOutput,
                          secondsSinceActive: secondsAgo,
                          project: project, activity: activity,
                          quotas: quotas,
                          needsAttention: attention, isWorking: working,
                          stepCurrent: step?.current, stepTotal: step?.total,
                          stepText: step?.text)
    }

    /// Active `update_plan` → (currentStep, totalSteps, stepText), or nil.
    /// A plan only counts as CURRENT if it's newer than the last `task_complete`:
    /// once the planned task finished and a new turn began without its own plan, the
    /// stale plan must not linger on screen. Scanning newest-first, whichever comes
    /// first — a plan update or a task completion — decides.
    private func codexPlan(lines: [String]) -> (current: Int, total: Int, text: String)? {
        for line in lines.reversed() {
            let maybePlan = hasLiteral(line, "update_plan")
            let maybeDone = hasLiteral(line, "\"task_complete\"")
            guard maybePlan || maybeDone,
                  let obj = parseJSON(line),
                  let payload = obj["payload"] as? [String: Any]
            else { continue }

            // Newest turn already ended → no active plan
            if payload["type"] as? String == "task_complete" { return nil }

            // Two plan encodings across Codex versions:
            //  · custom_tool_call → `input`: JS source `tools.update_plan({plan:[…]})`
            //  · function_call    → `arguments`: JSON `{"plan":[…]}` (name == update_plan)
            if let input = payload["input"] as? String, hasLiteral(input, "update_plan") {
                return parseCodexPlan(input)
            }
            if payload["name"] as? String == "update_plan",
               let args = payload["arguments"] as? String {
                return parseCodexPlan(args)
            }
        }
        return nil
    }

    private func parseCodexPlan(_ input: String) -> (Int, Int, String)? {
        // Ordered [(step, status)] from the plan array. Key quoting is inconsistent
        // across Codex versions — `step:"…"` unquoted, `"status":"…"` quoted, or
        // vice-versa — so match each `{step, status}` pair with tolerant quoting.
        let pattern = "\"?step\"?\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*,\\s*"
            + "\"?status\"?\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        let steps: [(text: String, status: String)] = matches.map {
            (unescapeJS(ns.substring(with: $0.range(at: 1))),
             ns.substring(with: $0.range(at: 2)))
        }
        let total = steps.count
        // Current = the in_progress step; else the first not-yet-done step; else all done
        if let i = steps.firstIndex(where: { $0.status == "in_progress" }) {
            return (i + 1, total, clean(steps[i].text))
        }
        if let i = steps.firstIndex(where: { $0.status != "completed" }) {
            return (i + 1, total, clean(steps[i].text))
        }
        return (total, total, clean(steps.last?.text ?? ""))
    }

    private func unescapeJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Refresh from local session JSONL only. This intentionally trades freshness for
    /// low, predictable overhead: no subprocess, network request, or credential access.
    private func updateCodexQuota() {
        if let last = codexQuotaLastRefresh,
           Date().timeIntervalSince(last) < codexQuotaRefreshInterval {
            return
        }
        codexQuotaLastRefresh = Date()
        updateCodexQuotaFromTranscripts()
    }

    /// Find the newest standard quota reading across recent session files.
    private func updateCodexQuotaFromTranscripts() {
        let root = home + "/.codex/sessions"
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        var recentFiles: [SessionFile] = []
        for back in 0..<4 {
            guard let day = Calendar.current.date(byAdding: .day, value: -back, to: Date())
            else { continue }
            let dir = root + "/" + sessionDayFormatter.string(from: day)
            recentFiles.append(contentsOf: sessionFiles(in: dir, cacheHistorical: back >= 2)
                .filter { $0.modificationDate >= cutoff })
        }

        let currentPaths = Set(recentFiles.map(\.path))
        codexQuotaFileCache = codexQuotaFileCache.filter { currentPaths.contains($0.key) }
        for file in recentFiles {
            if codexQuotaFileCache[file.path]?.stamp == file.stamp { continue }
            codexQuotaFileCache[file.path] = CachedCodexQuotaFile(
                stamp: file.stamp,
                reading: scanCodexQuota(path: file.path))
        }

        var newest: CodexQuotaReading?
        for cached in codexQuotaFileCache.values {
            guard let reading = cached.reading else { continue }
            if newest == nil || reading.timestamp > newest!.timestamp {
                newest = reading
            }
        }
        if let newest, newest.timestamp > codexQuotaTS {
            codexQuotaTS = newest.timestamp
            codexQuotaCache = newest.quotas
        }
    }

    private func scanCodexQuota(path: String) -> CodexQuotaReading? {
        for line in tailLines(path: path, maxBytes: 256 * 1024).reversed() {
            guard hasLiteral(line, "used_percent"),
                  let obj = parseJSON(line),
                  let timestamp = obj["timestamp"] as? String,
                  let payload = obj["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any]
            else { continue }

            // Codex can emit independent experimental limit pools in the same
            // transcript. They must not override the account's standard quota.
            if let limitID = limits["limit_id"] as? String, limitID != "codex" {
                continue
            }

            var fiveHour: AgentQuota?
            var sevenDay: AgentQuota?
            for key in ["primary", "secondary"] {
                guard let window = limits[key] as? [String: Any],
                      let used = (window["used_percent"] as? NSNumber)?.doubleValue,
                      let minutes = (window["window_minutes"] as? NSNumber)?.intValue
                else { continue }

                var resets: Date?
                if let value = (window["resets_at"] as? NSNumber)?.doubleValue {
                    resets = Date(timeIntervalSince1970: value)
                }
                let quota = AgentQuota(
                    usedPercent: min(max(used, 0), 100),
                    resetsAt: resets,
                    resetIsEstimated: false,
                    windowLabel: quotaWindowLabel(minutes: minutes))
                if minutes <= 5 * 60 {
                    fiveHour = quota
                } else if minutes >= 7 * 24 * 60 {
                    sevenDay = quota
                }
            }

            guard fiveHour != nil || sevenDay != nil else { continue }
            return CodexQuotaReading(
                quotas: [
                    fiveHour ?? AgentQuota(usedPercent: nil, resetsAt: nil,
                                             resetIsEstimated: false, windowLabel: "5小时"),
                    sevenDay ?? AgentQuota(usedPercent: nil, resetsAt: nil,
                                           resetIsEstimated: false, windowLabel: "7天"),
                ],
                timestamp: timestamp)
        }
        return nil
    }

    private func quotaWindowLabel(minutes: Int?) -> String {
        guard let minutes else { return "额度" }
        if minutes <= 5 * 60 { return "5小时" }
        if minutes >= 7 * 24 * 60 { return "7天" }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))天" }
        if minutes % 60 == 0 { return "\(minutes / 60)小时" }
        return "\(minutes)分钟"
    }

    /// Sum per-request deltas (`last_token_usage`), NOT `total_token_usage`:
    /// forked/subagent sessions inherit the parent's cumulative totals, which
    /// would massively overcount today.
    private func accumulateCodexLine(_ line: String) {
        guard let obj = parseJSON(line),
              let ts = obj["timestamp"] as? String, ts >= todayStartISO,
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any]
        else { return }
        // input_tokens already includes cached_input_tokens; cache writes are separate
        codexInput += uint(last["input_tokens"]) + uint(last["cache_write_input_tokens"])
        codexOutput += uint(last["output_tokens"])
    }

    /// (project, activity, needsAttention). Attention: the last significant event is
    /// task_complete (done) or an approval request (waiting for the user); a newer
    /// user message or a running tool call cancels it.
    private func codexActivity(path: String, tailLines sessionTail: [String]) -> (String?, String?, Bool) {
        // cwd lives in the head session_meta line, but that line embeds the full
        // system prompt (tens of KB) so a JSON parse would need the whole line.
        // cwd appears before the prompt, so pull it by substring from a head chunk.
        var project: String?
        if let head = tailLines(path: path, maxBytes: 0, headBytes: 16 * 1024).first,
           let cwd = extractJSONString(head, key: "cwd") {
            project = (cwd as NSString).lastPathComponent
        }

        // Working signals (Codex is mid-turn) vs waiting signals (turn ended /
        // needs the user). Newest-first, the first of either decides — so an active
        // command after a prior task_complete correctly reads as "working", not "wait".
        // token_count is ignored for state: it fires after every response, including
        // the final one, and would mask the real last event.
        let workingTypes: Set<String> = [
            "custom_tool_call", "custom_tool_call_output", "function_call",
            "function_call_output", "agent_reasoning", "reasoning",
            "task_started", "user_message",
        ]
        // Activity = the last thing Codex SAID (agent_message / task_complete text),
        // never the shell commands it ran. If no message exists in the window (a long
        // command-only stretch), fall back to the latest reasoning title.
        var message: String?
        var reasoning: String?
        var attention = false
        var stateDetermined = false
        for line in sessionTail.reversed() {
            guard let obj = parseJSON(line),
                  let payload = obj["payload"] as? [String: Any],
                  let type = payload["type"] as? String
            else { continue }

            if !stateDetermined {
                if type == "task_complete" || hasLiteral(type, "approval_request") {
                    attention = true; stateDetermined = true
                } else if workingTypes.contains(type)
                            || (type == "message" && payload["role"] as? String == "user") {
                    attention = false; stateDetermined = true
                }
            }

            if message == nil {
                switch type {
                case "agent_message":
                    // Keep newlines/markdown so the renderer can lay out tables & lists
                    message = cleanMultiline(payload["message"] as? String ?? "")
                case "task_complete":
                    message = cleanMultiline(payload["last_agent_message"] as? String ?? "")
                default:
                    break
                }
                if message?.isEmpty == true { message = nil }
            }
            if reasoning == nil, type == "agent_reasoning" {
                let t = (payload["text"] as? String ?? "")
                    .replacingOccurrences(of: "**", with: "")
                let c = clean(t)
                if !c.isEmpty { reasoning = c }
            }

            if message != nil && stateDetermined { break }
        }
        let activity = message ?? reasoning
        return (project, activity, attention)
    }

    /// Pull a JSON string value by key via substring scan — cheaper than parsing,
    /// and works on a truncated head chunk or embedded JS source.
    private func extractJSONString(_ s: String, key: String) -> String? {
        guard let r = s.range(of: "\"\(key)\":\"") else { return nil }
        let out = readJSString(s, from: r.upperBound)
        return out.isEmpty ? nil : out
    }

    /// Read a double-quoted string value starting just after the opening quote.
    /// Resolves \" \\ \n \t and stops at the closing unescaped quote.
    private func readJSString(_ s: String, from start: String.Index) -> String {
        var out = ""
        var i = start
        var escaped = false
        while i < s.endIndex {
            let c = s[i]
            if escaped {
                switch c {
                case "n", "t": out.append(" ")
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                break
            } else {
                out.append(c)
            }
            i = s.index(after: i)
        }
        return out
    }

    // MARK: - File Helpers

    /// Enumerate JSONL files with URL resource prefetching. This avoids constructing
    /// an attributes dictionary (including xattrs) for every file on every tick.
    private func sessionFiles(in directory: String, cacheHistorical: Bool) -> [SessionFile] {
        if cacheHistorical, let cached = historicalCodexFiles[directory] {
            return cached
        }

        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        let urls = (try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(fileResourceKeys),
            options: [.skipsHiddenFiles])) ?? []
        let files = urls.compactMap { url -> SessionFile? in
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: fileResourceKeys),
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate
            else { return nil }
            return SessionFile(
                path: url.path,
                modificationDate: modificationDate,
                size: UInt64(max(0, values.fileSize ?? 0)))
        }
        if cacheHistorical {
            historicalCodexFiles[directory] = files
        }
        return files
    }

    private func sessionFile(at path: String) -> SessionFile? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: fileResourceKeys),
              values.isRegularFile == true,
              let modificationDate = values.contentModificationDate
        else { return nil }
        return SessionFile(
            path: path,
            modificationDate: modificationDate,
            size: UInt64(max(0, values.fileSize ?? 0)))
    }

    private func hasLiteral(_ string: String, _ literal: String) -> Bool {
        string.range(of: literal, options: .literal) != nil
    }

    private func containsBytes<C: Collection>(_ bytes: C, pattern: [UInt8]) -> Bool
        where C.Element == UInt8 {
        guard !pattern.isEmpty else { return true }
        guard bytes.count >= pattern.count else { return false }

        for start in bytes.indices {
            var index = start
            var matched = true
            for expected in pattern {
                guard index != bytes.endIndex, bytes[index] == expected else {
                    matched = false
                    break
                }
                bytes.formIndex(after: &index)
            }
            if matched { return true }
        }
        return false
    }

    /// Feed complete NEW lines (since the stored offset) matching `prefilter`
    /// to `handler`, then advance the offset past the last complete line.
    private func consumeNewLines(path: String, size: UInt64,
                                 offsets: inout [String: UInt64],
                                 prefilter: String,
                                 handler: (String) -> Void) {
        var offset = offsets[path] ?? 0
        if size < offset { offset = 0 }  // truncated/rotated — dedupe absorbs re-reads
        guard size > offset, let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return }

        // Only consume up to the last newline — the writer may be mid-line
        guard let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        offsets[path] = offset + UInt64(lastNL) + 1

        let complete = data[data.startIndex...lastNL]
        let prefilterBytes = Array(prefilter.utf8)
        for chunk in complete.split(separator: UInt8(ascii: "\n")) {
            guard containsBytes(chunk, pattern: prefilterBytes),
                  let line = String(data: Data(chunk), encoding: .utf8)
            else { continue }
            handler(line)
        }
    }

    /// Read complete lines from the tail (or head, if headBytes > 0) of a file.
    private func tailLines(path: String, maxBytes: Int, headBytes: Int = 0) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }

        let data: Data
        if headBytes > 0 {
            data = (try? fh.read(upToCount: headBytes)) ?? Data()
        } else {
            let size = (try? fh.seekToEnd()) ?? 0
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try? fh.seek(toOffset: start)
            data = (try? fh.readToEnd()) ?? Data()
        }
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            String(data: Data($0), encoding: .utf8)
        }
    }

    private func parseJSON(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private func uint(_ v: Any?) -> UInt64 {
        (v as? NSNumber)?.uint64Value ?? 0
    }

    /// Single line, capped length — display truncation happens at render time
    private func clean(_ s: String) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > 120 ? String(oneLine.prefix(120)) + "…" : oneLine
    }

    /// Multi-line preserving — keeps newlines/markdown structure (tables, lists)
    /// for the renderer to lay out. Caps length so a huge message can't dominate.
    private func cleanMultiline(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 800 ? String(trimmed.prefix(800)) + "…" : trimmed
    }
}
