import AppKit
import Foundation
import SwiftUI

enum Severity: Int, Comparable, Sendable {
    case healthy = 0
    case warning = 1
    case critical = 2

    static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func forPercent(_ percent: Double) -> Severity {
        if percent > 85 { return .critical }
        if percent >= 60 { return .warning }
        return .healthy
    }

    var color: Color {
        switch self {
        case .healthy: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .healthy: .systemGreen
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }
}

struct UsageSnapshot: Decodable, Sendable {
    let generatedAt: Date
    let stale: Bool?
    let staleReason: String?
    let accounts: [UsageAccount]
    /// (v2 wiring) The protocol epoch state usage.py emits, driving Switch/health routing.
    /// Absent (pre-v2 usage.py) decodes nil and is treated as v1 (the pre-v2 world).
    let epoch: String?
    /// (v2 wiring) Anomaly-only health surface; nil/empty in the healthy state.
    let health: Health?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case stale
        case staleReason = "stale_reason"
        case accounts
        case epoch
        case health
    }

    var epochState: EpochState { EpochState.from(epoch) }

    static func decode(from data: Data) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = parseISO8601(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        return try decoder.decode(UsageSnapshot.self, from: data)
    }

    var representsCachedData: Bool {
        if stale == true { return true }
        if let reason = staleReason?.lowercased(),
           reason.contains("stale") || reason.contains("cache") || reason.contains("lock") {
            return true
        }
        return accounts.contains(where: \.isCachedEntry)
    }

    var activeClaudeEmail: String? {
        accounts.first { $0.isClaude && $0.active }?.email
    }

    /// Apply the successful swap script's result immediately while retaining every usage value.
    /// A later usage poll replaces this snapshot and remains authoritative if the swap rolled back.
    func optimisticallyActivatingClaudeAccount(email: String) -> UsageSnapshot {
        guard accounts.contains(where: { $0.isClaude && $0.email == email }) else {
            return self
        }

        return UsageSnapshot(
            generatedAt: generatedAt,
            stale: stale,
            staleReason: staleReason,
            accounts: accounts.map { account in
                guard account.isClaude else { return account }
                return account.withActive(account.email == email)
            },
            epoch: epoch,
            health: health
        )
    }

    private static func parseISO8601(_ value: String) -> Date? {
        // ISO8601DateFormatter's .withFractionalSeconds accepts exactly 3 fractional
        // digits; the backend emits Python microseconds (6 digits) — truncate first.
        let normalized = value.replacingOccurrences(
            of: #"\.(\d{3})\d+"#,
            with: ".$1",
            options: .regularExpression
        )
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: normalized) { return date }

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: normalized)
    }
}

enum PlanCapsulePresentation {
    static func text(for plan: String?) -> String? {
        guard let plan, !plan.isEmpty else { return nil }
        return plan.uppercased()
    }
}

/// Pure policy for the account "Remove" affordance. The Remove control appears ONLY on parked
/// Claude account cards — never the active account (it owns the live keychain item, so you must
/// swap away first) and never Codex (its token is owned by the Codex CLI, not our bank). A
/// needs-relogin Claude account is still parked, so it remains removable. Side-effect-free so
/// visibility and the confirmation copy can be unit-tested without a view.
enum RemoveAccountPolicy {
    static func canRemove(_ account: UsageAccount) -> Bool {
        // An unresolved entry has no bank record to remove; showing Remove would also
        // leak the sentinel into the confirmation strip. (A stale-cache unresolved
        // entry can arrive active=false, so !active alone is not enough.)
        // A v2 monitor-only home has NO v1 bank record either — remove-account.sh (a v1
        // op) would fence/fail on it; un-seeding a home is a separate, owner-driven flow.
        account.isClaude && !account.active && !account.isUnresolved && !account.isMonitorOnly
    }

    static func confirmationTitle(email: String) -> String {
        "Remove \(email)?"
    }

    static let confirmationMessage =
        "Its usage will stop being tracked. You can re-add it by logging in again."

    static let confirmButtonTitle = "Remove"

    /// Local-part of the address, used in the inline confirm strip's prompt. The full email is
    /// already on the card header directly above, so the strip only needs enough to disambiguate
    /// while leaving room for the Cancel/Remove buttons in the 320-wide popover.
    static func shortEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        return String(email[..<at])
    }

    /// Prompt shown inside the card when the remove affordance is armed (replaces the old modal
    /// confirmationDialog title). Kept short so "Remove <local>?  [Cancel] [Remove]" fits one row.
    static func inlinePrompt(email: String) -> String {
        "Remove \(shortEmail(email))?"
    }
}

/// Which single parked-Claude card, if any, currently has its inline "Remove <email>?" strip
/// revealed. This REPLACES the old SwiftUI `.confirmationDialog`, whose presentation binding
/// survived the popover losing key-window inside `MenuBarExtra(.window)` and left a sticky modal.
///
/// Modelled as a value type holding one Optional so the state machine is exhaustively
/// unit-testable without a view and the "only one card armed at a time" invariant holds
/// structurally (arming a card replaces any other). The actual removal is unaffected: the view
/// still calls `AppModel.removeAccount` -> `ActionScheduler`. `reset()` is invoked on every
/// popover open and close so a half-armed card can never re-render pre-armed on the next open.
struct InlineRemovalConfirmation: Equatable {
    private(set) var armedEmail: String?

    var isArmed: Bool { armedEmail != nil }

    func isArmed(email: String) -> Bool { armedEmail == email }

    /// Tapping the × on a card: arm it if disarmed, disarm it if it is the armed one. Arming a
    /// different card while one is already armed silently moves the strip (only one at a time).
    mutating func toggle(email: String) {
        armedEmail = (armedEmail == email) ? nil : email
    }

    /// Cancel button, or a completed removal: hide the strip.
    mutating func disarm() {
        armedEmail = nil
    }

    /// Popover open/close: never leave a card armed across a popover lifecycle.
    mutating func reset() {
        armedEmail = nil
    }
}

struct ActiveAccountDriftTracker {
    static let debounceInterval: TimeInterval = 120

    private var hasObservedSuccessfulPoll = false
    private var previousActiveEmail: String?
    private var lastTriggeredAt: Date?

    mutating func followUpEmail(
        afterSuccessfulPoll snapshot: UsageSnapshot,
        now: Date
    ) -> String? {
        let activeEmail = snapshot.activeClaudeEmail
        defer {
            previousActiveEmail = activeEmail
            hasObservedSuccessfulPoll = true
        }

        guard hasObservedSuccessfulPoll,
              activeEmail != previousActiveEmail,
              let activeEmail else {
            return nil
        }
        if let lastTriggeredAt,
           now.timeIntervalSince(lastTriggeredAt) < Self.debounceInterval {
            return nil
        }

        lastTriggeredAt = now
        return activeEmail
    }

    mutating func recordSuccessfulPoll(_ snapshot: UsageSnapshot) {
        previousActiveEmail = snapshot.activeClaudeEmail
        hasObservedSuccessfulPoll = true
    }
}

struct UsageAccount: Decodable, Identifiable, Sendable {
    let provider: String
    let email: String
    let active: Bool
    let plan: String?
    let status: String?
    let error: String?
    let fiveHour: UsageLimit?
    let sevenDay: UsageLimit?
    let worstLimit: WorstLimit?
    let modelCap: WorstLimit?
    let staleEntry: Bool?
    let fetchedAt: Double?
    let unresolved: Bool?
    let metadataEmail: String?
    /// (r13 #7) A v2 READY home whose credential is owned by the home CLI / archiver — usage.py
    /// never legacy-refreshes it. It has no v1 bank record, so v1 actuators (remove/re-bank)
    /// must never target it; its Ping routes through ping-account.sh's shadow|v2 home path.
    let monitorOnly: Bool?
    /// (r12 #13) Absolute epoch seconds until this v2 home's Ping is eligible again, from
    /// <home>/.ping-marker.json via usage.py. The app never reads that file itself.
    let cooldownUntil: Double?

    var id: String { "\(provider):\(email)" }
    var isClaude: Bool { provider.lowercased() == "claude" }
    var isCodex: Bool { provider.lowercased() == "codex" }
    var isMonitorOnly: Bool { monitorOnly == true }
    var needsRelogin: Bool { status?.lowercased() == "needs-relogin" }
    /// A v2 home's Ping cooldown deadline (absolute), or nil when not cooling down.
    var cooldownUntilDate: Date? {
        guard let cooldownUntil, cooldownUntil.isFinite, cooldownUntil > 0 else { return nil }
        return Date(timeIntervalSince1970: cooldownUntil)
    }
    /// The keychain login the backend could not attribute to any banked account
    /// (fail-closed identity). The sentinel-email fallback covers a stale cache
    /// written before the backend emitted the structured flag.
    var isUnresolved: Bool { unresolved == true || email == "(active/unresolved)" }
    /// What the card header shows. The raw sentinel string is an internal state
    /// name and must never reach the UI.
    var displayName: String {
        guard isUnresolved else { return email }
        if let metadataEmail, !metadataEmail.isEmpty { return metadataEmail }
        return "New login"
    }
    var isCachedEntry: Bool {
        staleEntry == true || hasError
    }
    var hasError: Bool {
        guard let error else { return false }
        return !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var fetchedAtDate: Date? {
        guard let fetchedAt, fetchedAt.isFinite else { return nil }
        return Date(timeIntervalSince1970: fetchedAt)
    }
    var severity: Severity? {
        worstLimit.map { Severity.forPercent($0.percent) }
    }

    func withActive(_ active: Bool) -> UsageAccount {
        UsageAccount(
            provider: provider,
            email: email,
            active: active,
            plan: plan,
            status: status,
            error: error,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            worstLimit: worstLimit,
            modelCap: modelCap,
            staleEntry: staleEntry,
            fetchedAt: fetchedAt,
            unresolved: unresolved,
            metadataEmail: metadataEmail,
            monitorOnly: monitorOnly,
            cooldownUntil: cooldownUntil
        )
    }

    enum CodingKeys: String, CodingKey {
        case provider, email, active, plan, status, error, unresolved
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case worstLimit = "worst_limit"
        case modelCap = "model_cap"
        case staleEntry = "stale_entry"
        case fetchedAt = "fetched_at"
        case metadataEmail = "metadata_email"
        case monitorOnly = "monitor_only"
        case cooldownUntil = "cooldown_until"
    }
}

enum AccountOrdering {
    /// Preserve the backend's bank order exactly. Active state is presentation metadata and
    /// must never influence card position.
    static func claudeAccountsInSnapshotOrder(_ accounts: [UsageAccount]) -> [UsageAccount] {
        accounts.filter(\.isClaude)
    }
}

enum CardFreshness: Equatable, Sendable {
    case fresh
    case aging
    case stale
    case updating
}

enum AccountFreshness {
    static let agingThreshold: TimeInterval = 60
    static let staleThreshold: TimeInterval = 120

    static func age(fetchedAt: Date?, now: Date) -> TimeInterval? {
        guard let fetchedAt else { return nil }
        let age = now.timeIntervalSince(fetchedAt)
        guard age.isFinite else { return nil }
        return max(0, age)
    }

    static func state(
        for account: UsageAccount,
        now: Date,
        isUpdating: Bool = false,
        isForcedStale: Bool = false
    ) -> CardFreshness {
        if isUpdating { return .updating }
        if isForcedStale || account.isCachedEntry { return .stale }
        guard let age = age(fetchedAt: account.fetchedAtDate, now: now) else {
            return .stale
        }
        if age >= staleThreshold { return .stale }
        if age > agingThreshold { return .aging }
        return .fresh
    }

    static func caption(
        for account: UsageAccount,
        now: Date,
        freshness: CardFreshness
    ) -> String? {
        switch freshness {
        case .fresh, .aging:
            return nil
        case .stale:
            return TimeFormatting.cachedAgo(from: account.fetchedAtDate, now: now)
        case .updating:
            return "updating…"
        }
    }

    static func shouldPollOnOpen(accounts: [UsageAccount], now: Date) -> Bool {
        accounts.contains { account in
            guard let age = age(fetchedAt: account.fetchedAtDate, now: now) else {
                return true
            }
            return age > agingThreshold
        }
    }

    /// Confirmation freshness is deliberately stricter than process success: the target must
    /// have a verifiable timestamp and no backend cache/error marker.
    static func isValidConfirmationEntry(_ account: UsageAccount) -> Bool {
        account.fetchedAtDate != nil && !account.isCachedEntry
    }

    /// Clear trust failures only for accounts individually proven valid by this snapshot.
    static func reconciledForcedStaleAccountIDs(
        _ existing: Set<String>,
        with accounts: [UsageAccount]
    ) -> Set<String> {
        var remaining = existing
        for account in accounts where isValidConfirmationEntry(account) {
            remaining.remove(account.id)
        }
        return remaining
    }
}

/// Plain-language lead-in for the popover's top "cached data" badge. The backend fail-softs to the
/// last-good reading on any transient upstream failure (429/403/5xx/network) and marks the served
/// entry `stale_entry` — but that served entry is the PREVIOUS GOOD one and no longer carries the
/// failing run's error, so a cached-with-data entry usually can't be attributed to rate-limiting.
/// A "rate-limited" claim is therefore only honest when a 429 marker actually survives in the
/// snapshot: the active account's `error` string (present when there was no cache to fall back to,
/// e.g. "HTTP 429"), or a snapshot-level `stale_reason`. Absent that we say the honest generic
/// thing. Pure so the wording can be unit-tested without a view.
enum CachedDataBadgeText {
    static func headline(activeError: String?, staleReason: String?) -> String {
        if mentionsRateLimit(activeError) || mentionsRateLimit(staleReason) {
            return "rate-limited · cached"
        }
        return "cached data"
    }

    private static func mentionsRateLimit(_ text: String?) -> Bool {
        guard let text = text?.lowercased() else { return false }
        return text.contains("429") || text.contains("rate limit") || text.contains("rate-limit")
    }
}

enum UsagePollMode: Equatable, Sendable {
    case regular
    case forceFresh(String)
    case only(String)
}

enum UsagePollEnvironment {
    static func values(for mode: UsagePollMode = .regular) -> [String: String] {
        var values = ["ACCOUNT_BANK_PARKED_MAX_AGE": "600"]
        switch mode {
        case .regular:
            break
        case .forceFresh(let target) where !target.isEmpty:
            values["ACCOUNT_BANK_FORCE_FRESH"] = target
        case .only(let email) where !email.isEmpty:
            values["ACCOUNT_BANK_ONLY"] = email
        case .forceFresh, .only:
            break
        }
        return values
    }
}

/// Only ordinary and popover-starred refreshes can coalesce while another usage poll runs.
/// Switch confirmations remain inline FIFO work and therefore never enter this merge path.
enum PendingRefreshRequest: Equatable, Sendable {
    case regular
    case starred

    var pollMode: UsagePollMode {
        switch self {
        case .regular: .regular
        case .starred: .forceFresh("*")
        }
    }

    static func merged(
        _ current: PendingRefreshRequest?,
        with incoming: PendingRefreshRequest
    ) -> PendingRefreshRequest {
        if current == .starred || incoming == .starred { return .starred }
        return .regular
    }
}

struct StarredRefreshDebouncer {
    static let interval: TimeInterval = 60

    private(set) var lastAcceptedAt: Date?

    mutating func accept(now: Date) -> Bool {
        if let lastAcceptedAt,
           now.timeIntervalSince(lastAcceptedAt) < Self.interval {
            return false
        }
        lastAcceptedAt = now
        return true
    }
}

enum SwitchTimingDiagnostics {
    static func milliseconds(startUptime: UInt64, endUptime: UInt64) -> Int {
        guard endUptime >= startUptime else { return 0 }
        return Int((endUptime - startUptime) / 1_000_000)
    }

    static func line(scriptMilliseconds: Int, confirmMilliseconds: Int) -> String {
        "switch: script \(max(0, scriptMilliseconds))ms, confirm \(max(0, confirmMilliseconds))ms"
    }
}

struct UsageLimit: Decodable, Sendable {
    /// (review #1) Tolerant: the backend may emit `{"utilization": null}` for a window with no
    /// active data (a monitor-only home with no live window). Optional so an explicit null
    /// decodes to nil (via decodeIfPresent) INSTEAD of throwing valueNotFound and dropping the
    /// whole snapshot. Presentation treats nil as "no window" — never 0% masquerading as data.
    let utilization: Double?
    let resetsAt: Date?

    /// A window worth rendering: it has a real utilization value.
    var hasData: Bool { utilization != nil }

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct WorstLimit: Decodable, Sendable {
    let kind: String
    let percent: Double
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case kind, percent
        case resetsAt = "resets_at"
    }
}

enum TimeFormatting {
    static let cooldown: TimeInterval = 1_800

    static func clockString(
        _ date: Date,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func resetCaption(
        resetAt: Date,
        now: Date,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        let clock = clockString(resetAt, calendar: calendar, timeZone: timeZone, locale: locale)
        let remaining = max(0, Int(resetAt.timeIntervalSince(now)))
        return "resets \(clock) (\(relativeFuture(seconds: remaining)))"
    }

    /// Spelled-out relative duration for VoiceOver, e.g. "4 hours 22 minutes".
    static func spokenRelative(seconds: Int) -> String {
        if seconds <= 0 { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        func unit(_ count: Int, _ noun: String) -> String {
            "\(count) \(noun)\(count == 1 ? "" : "s")"
        }
        if days > 0 { return "\(unit(days, "day")) \(unit(hours, "hour"))" }
        if hours > 0 { return "\(unit(hours, "hour")) \(unit(minutes, "minute"))" }
        if minutes > 0 { return unit(minutes, "minute") }
        return "less than a minute"
    }

    static func updatedAgo(from date: Date?, now: Date) -> String {
        guard let date else { return "Updated —" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "Updated \(seconds)s ago" }
        if seconds < 3_600 { return "Updated \(seconds / 60)m ago" }
        if seconds < 86_400 { return "Updated \(seconds / 3_600)h ago" }
        return "Updated \(seconds / 86_400)d ago"
    }

    static func cachedAgo(from date: Date?, now: Date) -> String {
        guard let date else { return "cached —" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "cached \(seconds)s ago" }
        if seconds < 3_600 { return "cached \(seconds / 60)m ago" }
        if seconds < 86_400 { return "cached \(seconds / 3_600)h ago" }
        return "cached \(seconds / 86_400)d ago"
    }

    static func cooldownRemaining(lastPing: Date?, now: Date) -> TimeInterval {
        guard let lastPing else { return 0 }
        return max(0, cooldown - now.timeIntervalSince(lastPing))
    }

    private static func relativeFuture(seconds: Int) -> String {
        if seconds <= 0 { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(String(format: "%02d", minutes))m" }
        if minutes > 0 { return "in \(minutes)m" }
        return "in <1m"
    }
}

/// Timeout and escalation are selected by operation type, never by a call-site boolean.
/// Only the read-only usage poll may escalate to a process-tree SIGKILL. Mutating actions
/// get a long timeout and are allowed to continue after their TERM grace expires.
struct ScriptExecutionPolicy: Equatable, Sendable {
    let timeout: TimeInterval
    let terminationGrace: TimeInterval
    let sendsTreeSIGKILL: Bool

    static let usagePoll = ScriptExecutionPolicy(
        timeout: 15,
        terminationGrace: 0.25,
        sendsTreeSIGKILL: true
    )
    static let mutatingAction = ScriptExecutionPolicy(
        timeout: 90,
        terminationGrace: 10,
        sendsTreeSIGKILL: false
    )
    static let utility = ScriptExecutionPolicy(
        timeout: 10,
        terminationGrace: 1,
        sendsTreeSIGKILL: false
    )
}

enum WorkPriority {
    case background
    case userInitiated
}

/// Priority-aware FIFO bookkeeping for QuotaBar's single global work queue. Exactly one usage
/// poll or action runs at a time; user actions may pass pending polls but never in-flight work.
/// Pure and synchronous so ordering and queued-state can be unit-tested without spawning scripts.
struct ActionScheduler<Payload> {
    private(set) var pending: [(key: String, payload: Payload, priority: WorkPriority)] = []
    private(set) var queuedKeys: Set<String> = []
    private(set) var running = false

    var isEmpty: Bool { pending.isEmpty }

    /// Enqueue work for `key`. User work stays FIFO relative to other user work, but is inserted
    /// before the first pending background item. Work already removed by `dequeue()` is untouched.
    mutating func enqueue(key: String, payload: Payload, priority: WorkPriority) {
        if running { queuedKeys.insert(key) }
        let item = (key: key, payload: payload, priority: priority)
        if priority == .userInitiated,
           let firstBackground = pending.firstIndex(where: { $0.priority == .background }) {
            pending.insert(item, at: firstBackground)
        } else {
            pending.append(item)
        }
    }

    /// Start draining if idle. Returns true when the caller should launch the pump task.
    mutating func beginIfIdle() -> Bool {
        guard !running, !pending.isEmpty else { return false }
        running = true
        return true
    }

    /// Pop the next action (FIFO), clearing its queued mark. Returns nil and stops when drained.
    mutating func dequeue() -> (key: String, payload: Payload)? {
        guard !pending.isEmpty else {
            running = false
            return nil
        }
        let item = pending.removeFirst()
        queuedKeys.remove(item.key)
        return (key: item.key, payload: item.payload)
    }

    func isQueued(_ key: String) -> Bool { queuedKeys.contains(key) }
}

/// Pure layout decision for the account region (#13): hug content when small, switch to a
/// bounded ScrollView (footer pinned outside) once the estimate would exceed the cap.
enum PopoverLayout {
    static let claudeCardEstimate: CGFloat = 168
    static let reloginCardEstimate: CGFloat = 108
    static let codexCardEstimate: CGFloat = 150
    static let cardSpacing: CGFloat = 10
    static let maxAccountRegionHeight: CGFloat = 560

    static func estimatedHeight(
        claudeAccounts: Int,
        reloginAccounts: Int,
        hasCodex: Bool,
        isStale: Bool
    ) -> CGFloat {
        let normal = max(0, claudeAccounts - reloginAccounts)
        var total = CGFloat(normal) * claudeCardEstimate
            + CGFloat(reloginAccounts) * reloginCardEstimate
        var items = claudeAccounts
        if hasCodex {
            total += codexCardEstimate
            items += 1
        }
        guard items > 0 else { return 0 }
        total += CGFloat(items - 1) * cardSpacing
        total += (isStale ? 0 : 12) + 2
        return total
    }

    static func needsScroll(
        claudeAccounts: Int,
        reloginAccounts: Int,
        hasCodex: Bool,
        isStale: Bool
    ) -> Bool {
        estimatedHeight(
            claudeAccounts: claudeAccounts, reloginAccounts: reloginAccounts,
            hasCodex: hasCodex, isStale: isStale
        ) > maxAccountRegionHeight
    }

    static func regionHeight(
        claudeAccounts: Int,
        reloginAccounts: Int,
        hasCodex: Bool,
        isStale: Bool
    ) -> CGFloat {
        min(
            estimatedHeight(
                claudeAccounts: claudeAccounts, reloginAccounts: reloginAccounts,
                hasCodex: hasCodex, isStale: isStale
            ),
            maxAccountRegionHeight
        )
    }
}

/// Pure logic for the Codex manual-ping button: availability (binary resolved) and the
/// 30-minute cooldown. Kept side-effect-free so it can be unit-tested without pressing Ping.
enum CodexPing {
    static let cooldown: TimeInterval = 1_800

    static func isAvailable(binaryPath: String?) -> Bool {
        guard let binaryPath else { return false }
        return !binaryPath.isEmpty
    }

    static func remaining(lastPing: Date?, now: Date) -> TimeInterval {
        guard let lastPing else { return 0 }
        return max(0, cooldown - now.timeIntervalSince(lastPing))
    }

    static func buttonTitle(remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "Ping" }
        let minutes = max(1, Int(ceil(remaining / 60)))
        return "Ping · \(minutes)m"
    }
}

// MARK: - v2 wiring: epoch, Switch routing, health, ping cooldown

/// The protocol epoch usage.py reports (`epoch` field). Absent/nil == the pre-v2 world (v1);
/// "unknown" is a present-but-broken EPOCH, where the app stays on the safe v1 Switch path —
/// the scripts fence a real mutation regardless, so the worst case is a surfaced script error.
enum EpochState: String, Sendable, Equatable {
    case v1, shadow, v2, unknown

    static func from(_ raw: String?) -> EpochState {
        switch raw?.lowercased() {
        case "shadow": return .shadow
        case "v2": return .v2
        case "v1", "", nil: return .v1
        default: return .unknown
        }
    }

    /// (rollback-day) Only v2 repoints the Switch (future launches + assisted restart). Under
    /// v1 AND shadow the Switch is the v1 SEAMLESS swap (swap-account.sh): the owner rejected
    /// pin-at-launch and wants mid-session turn-level pickup, accepting v1's failure modes. So
    /// shadow, which still runs the archiver/registry (hence showsHealth), no longer repoints.
    /// unknown stays on the safe swap path too (a real mutation is script-fenced regardless).
    var usesRepointSwitch: Bool { self == .v2 }
    /// Health chrome (archiver / fork-drift / seed-audit) is only meaningful once the v2
    /// layer is live; under v1 there is no archiver/registry to be anomalous about.
    var showsHealth: Bool { self == .shadow || self == .v2 }
}

/// Pure Switch-routing decision: which script "Switch here" runs, and whether to offer an
/// assisted restart afterward. Side-effect-free so the routing table is a contract test.
enum SwitchRoute: Equatable, Sendable {
    case swap        // v1 / shadow / unknown: swap-account.sh <email> (in-place keychain swap)
    case repoint     // v2 only: claude-acct --switch <email> (future launches) + restart offer

    static func route(for epoch: EpochState) -> SwitchRoute {
        epoch.usesRepointSwitch ? .repoint : .swap
    }

    var offersRestart: Bool { self == .repoint }

    /// (rollback-day) The card action-button label. Under v1/shadow the button is the v1
    /// seamless "Swap here"; under v2 it stays "Switch here" (a repoint of future launches).
    var actionTitle: String { self == .repoint ? "Switch here" : "Swap here" }
}

/// Pure builder for the v1 seamless swap invocation (swap-account.sh). When the active account
/// is known from the SAME payload the UI rendered, it appends `--expect-active <active>` so a
/// stale click can't clobber a newer swap: swap-account.sh aborts (rc 3) under its lock if the
/// live active account no longer matches. Side-effect-free so the argv is a contract test. (rollback-day)
enum SwapInvocation {
    static func arguments(swapScript: String, target: String, activeEmail: String?) -> [String] {
        var args = [swapScript, target]
        if let active = activeEmail, !active.isEmpty, active != target {
            args.append(contentsOf: ["--expect-active", active])
        }
        return args
    }
}

/// One swap at a time, across every card. A queued swap carries the `--expect-active` snapshot it
/// was built from, so a second swap enqueued behind it runs against an expectation the first one
/// has already invalidated and aborts under the lock (rc 3). Per-card disabling doesn't catch that
/// — clicking B then C enqueues two — so the gate is global over the whole busy table.
enum SwitchGate {
    /// `AppModel.ActionKind.switchAccount.rawValue` (also the string the card views match on).
    static let switchKind = "switch"

    static func isBlocked(busyKinds: some Sequence<String>) -> Bool {
        busyKinds.contains(switchKind)
    }
}

/// Card copy for a failed swap. swap-account.sh exits 3 when its `--expect-active` guard finds a
/// different active account under the lock: another swap landed first, so this click was built
/// from a stale view. Its stderr is a lock diagnostic; the card says what to do instead.
enum SwapFailureText {
    static let staleActive = "Active account changed — try again"

    static func message(isSwitch: Bool, exitCode: Int32?, stderrLine: String) -> String {
        isSwitch && exitCode == 3 ? staleActive : stderrLine
    }
}

/// The health payload usage.py emits (`health`). Every field is optional and absent in the
/// healthy state, so the popover renders no health chrome unless something is genuinely wrong.
struct Health: Decodable, Sendable {
    struct Archiver: Decodable, Sendable {
        let heartbeatAge: Int?
        let epochParked: Bool?
        let blindHomes: [String]?
        enum CodingKeys: String, CodingKey {
            case heartbeatAge = "heartbeat_age"
            case epochParked = "epoch_parked"
            case blindHomes = "blind_homes"
        }
    }
    struct SeedAudit: Decodable, Sendable {
        let latestTs: Int?
        let latestLinkedCount: Int?
        let count: Int?
        enum CodingKeys: String, CodingKey {
            case latestTs = "latest_ts"
            case latestLinkedCount = "latest_linked_count"
            case count
        }
    }
    let archiver: Archiver?
    let forkDrift: [String: [String]]?
    let seedAudit: SeedAudit?
    enum CodingKeys: String, CodingKey {
        case archiver
        case forkDrift = "fork_drift"
        case seedAudit = "seed_audit"
    }
}

/// Pure anomaly reducer: turns the health payload + epoch into the SMALL set of lines the
/// popover may show. Everything returns nil/empty in the healthy state, so the view renders
/// no health chrome. Thresholds live here, one place — mirroring how freshness thresholds do.
enum HealthPresentation {
    static let archiverStaleThreshold = 600.0   // heartbeat stale past 10 min (task)

    /// ONE compact warning when the archiver heartbeat is stale (>10m) OR any home is blind.
    /// Only meaningful under shadow|v2; nil otherwise. An epoch_parked archiver (deliberately
    /// idle after a rollback to v1) never trips this — v1 hides health entirely.
    static func archiverWarning(_ health: Health?, epoch: EpochState) -> String? {
        guard epoch.showsHealth, let a = health?.archiver, a.epochParked != true else { return nil }
        let blindCount = (a.blindHomes ?? []).count
        let stale = Double(a.heartbeatAge ?? 0) > archiverStaleThreshold
        switch (blindCount > 0, stale) {
        case (true, true):
            return "Archiver stalled — \(blindCount) home\(plural(blindCount)) unwatched"
        case (true, false):
            return "\(blindCount) home\(plural(blindCount)) unwatched by the archiver"
        case (false, true):
            let mins = Int((Double(a.heartbeatAge ?? 0) / 60).rounded())
            return "Archiver heartbeat stale (\(mins)m)"
        case (false, false):
            return nil
        }
    }

    /// Fork-drift line: shared files that diverged in one or more homes (needs reconcile).
    static func forkDriftLine(_ health: Health?, epoch: EpochState) -> String? {
        guard epoch.showsHealth, let drift = health?.forkDrift, !drift.isEmpty else { return nil }
        let files = Set(drift.values.flatMap { $0 }).count
        let homes = drift.count
        return "Fork drift in \(homes) home\(plural(homes)) · \(files) shared file\(plural(files))"
    }

    /// Seed-audit review: surfaced only when a seeding event NEWER than the acknowledged
    /// timestamp shared files into homes. Dismissal (ack = latestTs) persists app-side so the
    /// line stays quiet once seen, reappearing only when a later seeding shares more.
    static func seedAuditReview(
        _ health: Health?, epoch: EpochState, ackedTs: Int
    ) -> (ts: Int, count: Int)? {
        guard epoch.showsHealth, let sa = health?.seedAudit,
              let ts = sa.latestTs, ts > ackedTs, (sa.latestLinkedCount ?? 0) > 0
        else { return nil }
        return (ts, sa.latestLinkedCount ?? 0)
    }

    /// True when NOTHING is anomalous — the popover shows no health chrome at all.
    static func isHealthy(_ health: Health?, epoch: EpochState, seedAuditAckTs: Int) -> Bool {
        archiverWarning(health, epoch: epoch) == nil
            && forkDriftLine(health, epoch: epoch) == nil
            && seedAuditReview(health, epoch: epoch, ackedTs: seedAuditAckTs) == nil
    }

    private static func plural(_ n: Int) -> String { n == 1 ? "" : "s" }
}

/// Maps a restart.py failure line to a compact per-session outcome (review #3). A stranded lease
/// — a successor spawned but not registered in time (rc 75) — becomes a recovery hint rather than
/// a bare "Script failed"; a refusal keeps its reason; an empty/generic line reads "failed".
enum RestartOutcomeText {
    static func outcome(forFailureLine line: String?) -> String {
        let l = (line ?? "").lowercased()
        if l.contains("lease intentionally held") || l.contains("not registered")
            || l.contains("did not complete") {
            return "needs recovery"
        }
        if l.hasPrefix("restart refused") || l.contains("aborted") {
            return line ?? "failed"
        }
        let trimmed = (line ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || l == "script failed") ? "failed" : trimmed
    }
}

/// Ping-cooldown remaining for a card: a v2 home's absolute `cooldown_until` (from usage.py)
/// takes precedence; otherwise the v1 per-account last_ping window. Pure so the presentation
/// is unit-tested without pressing Ping.
enum PingCooldown {
    static func remaining(for account: UsageAccount, v1LastPing: Date?, now: Date) -> TimeInterval {
        if let until = account.cooldownUntilDate {
            return max(0, until.timeIntervalSince(now))
        }
        return TimeFormatting.cooldownRemaining(lastPing: v1LastPing, now: now)
    }
}
