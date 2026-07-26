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

/// (v102) A CONTINUOUS colour for the usage gauge, derived from the percentage alone. Purely
/// presentational: `Severity`'s three steps stay the authoritative semantics for the menu bar icon
/// and the card's status dot, which have to answer "is this account in trouble" at a glance and so
/// must not drift with every point of usage. The bar is a different question — it shows a quantity,
/// and a quantity that changes colour in one jump at 60% misreports how close 59% is to 61%.
///
/// The ramp is anchored ON Severity's own thresholds, so the two can never disagree where it
/// matters: at exactly 60 the bar IS the warning colour, at exactly 85 it IS the critical colour.
/// Below 40 it holds flat green rather than starting to yellow immediately — a quarter-full window
/// is not a soft warning, and tinting it like one is the noise this app exists to avoid.
enum GaugeRamp {
    /// (percent, colour) anchors, ascending. Between anchors the colour is interpolated.
    static let anchors: [(percent: Double, severity: Severity)] = [
        (0, .healthy), (40, .healthy), (60, .warning), (85, .critical), (100, .critical),
    ]

    /// Which two anchors a percentage falls between, and how far along. Pure, so the ramp's
    /// alignment with Severity's thresholds is a contract test rather than a visual judgement.
    struct Stop: Equatable {
        let from: Severity
        let to: Severity
        /// 0 = exactly `from`, 1 = exactly `to`.
        let fraction: Double
    }

    static func stop(forPercent percent: Double) -> Stop {
        let value = min(max(percent.isFinite ? percent : 0, 0), 100)
        for index in 1..<anchors.count where value <= anchors[index].percent {
            let lower = anchors[index - 1]
            let upper = anchors[index]
            let span = upper.percent - lower.percent
            let fraction = span > 0 ? (value - lower.percent) / span : 1
            return Stop(from: lower.severity, to: upper.severity, fraction: fraction)
        }
        let last = anchors[anchors.count - 1].severity
        return Stop(from: last, to: last, fraction: 1)
    }

    /// The interpolated colour, resolved per appearance. The blend happens INSIDE a dynamic
    /// NSColor provider so both anchors are resolved for the appearance actually being drawn —
    /// blending outside it would freeze light-mode components into a dark-mode popover.
    static func color(forPercent percent: Double) -> Color {
        let stop = stop(forPercent: percent)
        guard stop.from != stop.to else { return stop.to.color }
        return Color(nsColor: NSColor(name: nil) { appearance in
            var blended = stop.to.nsColor
            appearance.performAsCurrentDrawingAppearance {
                blended = mix(stop.from.nsColor, stop.to.nsColor, fraction: stop.fraction)
            }
            return blended
        })
    }

    private static func mix(_ from: NSColor, _ to: NSColor, fraction: Double) -> NSColor {
        guard let a = from.usingColorSpace(.sRGB), let b = to.usingColorSpace(.sRGB) else {
            return to
        }
        let t = CGFloat(min(max(fraction, 0), 1))
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t
        )
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

/// The plan chip's copy. (v102) The backend hands us its own vocabulary — today Claude collapses
/// every Max variant to `max` (bank_common.plan_tier) while Codex passes `plan_type` through — so
/// the chip is a presentation-side mapping, not a model change: the names people actually use for
/// their subscriptions, with anything unrecognised passing through uppercased exactly as before.
/// The key is normalised first (case, whitespace, `-` vs `_`, a `claude_` prefix) so a tier variant
/// reaching the app in any of its spellings still lands on the friendly name.
enum PlanCapsulePresentation {
    /// Ordered so the chip stays short enough for the 320-wide card header. The × is a real
    /// multiplication sign — "MAX 5x" reads as a typo at 9pt.
    static let friendlyNames: [String: String] = [
        "max": "MAX",
        "max_5x": "MAX 5×",
        "max_20x": "MAX 20×",
        "pro": "PRO",
        "free": "FREE",
    ]

    static func text(for plan: String?) -> String? {
        guard let plan else { return nil }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return friendlyNames[normalized(trimmed)] ?? trimmed.uppercased()
    }

    static func normalized(_ plan: String) -> String {
        var key = plan.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        if key.hasPrefix("claude_") { key.removeFirst("claude_".count) }
        return key
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

/// (v102) Pure policy for the "Un-seed…" affordance on a v2 monitor-only card. Those cards
/// deliberately hide the Remove ✕ — a home has no v1 bank record, so remove-account.sh would fence
/// on it — which left the only way to undo a seeding as a shell command the owner had to remember.
/// This is the affordance for that: a different operation with a different verb, offered ONLY where
/// it applies (a seeded home), never on a v1 banked account and never on the account currently
/// serving requests. Side-effect-free so visibility and copy are unit-tested without a view.
enum UnseedPolicy {
    static func canUnseed(_ account: UsageAccount) -> Bool {
        account.isClaude && account.isMonitorOnly && !account.active && !account.isUnresolved
    }

    static let actionTitle = "Un-seed…"
    static let confirmButtonTitle = "Un-seed"

    /// Same one-row shape as the remove strip: "Un-seed <local>?  [Cancel] [Un-seed]".
    static func inlinePrompt(email: String) -> String {
        "Un-seed \(RemoveAccountPolicy.shortEmail(email))?"
    }

    static let confirmationMessage =
        "Removes this account's pinned home. Its banked credentials and usage history are untouched."
}

/// (v102) The one-line caption a finished un-seed leaves on the card. The command reports what it
/// did — what it removed, what it archived — and that report is the answer to the only question the
/// owner has after tearing down a home, so it becomes the caption rather than a generic "Done".
///
/// Parsed from `unseed.py --json`, which the scripts side documents as the form QuotaBar drives:
/// the result dict on stdout, human text on stderr. Every field is optional and a decode failure
/// falls back to the command's own last line, so a shape change on the scripts side degrades to a
/// duller caption instead of a wrong one.
enum UnseedSummary {
    private struct Result: Decodable {
        let wouldRemove: Bool?
        let homeRemoved: Bool?
        let registryEntryRemoved: Bool?
        let keychainSlotDeleted: Bool?
        let archivedCredential: String?
        let archivedHomeHistory: String?
        let warnings: [String]?

        enum CodingKeys: String, CodingKey {
            case wouldRemove = "would_remove"
            case homeRemoved = "home_removed"
            case registryEntryRemoved = "registry_entry_removed"
            case keychainSlotDeleted = "keychain_slot_deleted"
            case archivedCredential = "archived_credential"
            case archivedHomeHistory = "archived_home_history"
            case warnings
        }
    }

    static func caption(fromStdout stdout: String) -> String {
        guard let result = try? JSONDecoder().decode(Result.self, from: Data(stdout.utf8)) else {
            return fallbackCaption(stdout)
        }

        // The clean no-op: a home that was already gone. Saying "removed nothing" would read as
        // a failure; it isn't one.
        if result.wouldRemove == false { return "nothing to un-seed" }

        var removed: [String] = []
        if result.homeRemoved == true { removed.append("home") }
        if result.keychainSlotDeleted == true { removed.append("keychain slot") }
        if result.registryEntryRemoved == true { removed.append("registry entry") }

        var archived: [String] = []
        if result.archivedCredential?.isEmpty == false { archived.append("credential") }
        if result.archivedHomeHistory?.isEmpty == false { archived.append("history") }

        var parts: [String] = []
        if !removed.isEmpty { parts.append("removed \(removed.joined(separator: ", "))") }
        if !archived.isEmpty { parts.append("archived \(archived.joined(separator: ", "))") }
        // A warning is the command telling us the removal left something worth knowing about
        // (today: a dangling v1 pointer). It outranks the inventory — carry it verbatim.
        if let warning = result.warnings?.first(where: { !$0.isEmpty }) {
            parts.append(warning)
        }
        guard !parts.isEmpty else { return "nothing to un-seed" }
        return parts.joined(separator: " · ")
    }

    /// Only reached if the payload stops being JSON. The FIRST line, never the last: the human
    /// rendering ends on a "recover:" hint, so captioning the card with its last line would
    /// state the recovery advice as though it were the outcome.
    private static func fallbackCaption(_ stdout: String) -> String {
        let lines = stdout
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first ?? "Un-seeded"
    }
}

/// (v102) Card copy for a REFUSED un-seed. unseed.py computes every refusal before it touches
/// anything and reports it as an exit code, so a refusal is a safe outcome with a specific cause —
/// but its stderr reason is a paragraph written for a terminal, and the card has one short line.
/// The codes that mean something to the owner get their own copy (same idea as rc 3 from
/// swap-account.sh); anything else keeps the script's own first line rather than being flattened.
enum UnseedFailureText {
    static func message(exitCode: Int32?, stderrLine: String) -> String {
        switch exitCode {
        // Two different situations share rc 74, and they need different actions from the owner.
        // The refusal sentence distinguishes them, so the card tells them which one to take.
        case 74:
            let reason = stderrLine.lowercased()
            if reason.contains("accounts/current") {
                return "Future launches still point here — switch to another account first"
            }
            // (v102-r2) The third cause of rc 74: a pinned launch admitted on this home whose
            // process is still alive. It is not a registered session yet — the owner is looking
            // at a Terminal that just opened, not a session in the list — so saying "a session"
            // would send them looking for something they cannot see.
            if reason.contains("pinned launch") {
                return "A pinned session is starting on this home — quit that window first"
            }
            return "A session is still live on this home — quit it first"
        case 78: return "Seeding in flight — try again once it finishes"
        case 70: return "Bank busy — try again in a moment"
        case 73: return "Needs confirmation — try again"
        // rc 75 is fail-closed and safe to retry (nothing is destroyed unarchived), but its
        // cause varies — a locked keychain, an unreadable registry — so the reason is the
        // useful part and it stays verbatim.
        default: return stderrLine
        }
    }
}

/// (v102) The "Pinned session…" affordance: open a Terminal running `claude-acct <email>`, which
/// launches Claude Code pinned to that account's home for the life of that window. Offered only
/// where homes exist at all (shadow|v2) and only for an account we can name — an unresolved login
/// has no registry entry to map, and a needs-relogin account would open a dead session.
enum PinnedSessionPolicy {
    static func canOpen(_ account: UsageAccount, epoch: EpochState) -> Bool {
        guard epoch == .shadow || epoch == .v2 else { return false }
        return account.isClaude && !account.isUnresolved && !account.needsRelogin
    }

    static let actionTitle = "Pinned session…"
    static let help =
        "Open a Terminal running Claude Code pinned to this account, leaving other sessions alone."
    /// (v102-r2) Shown instead while an un-seed holds the homes tree — see PinnedLaunchGate.
    static let blockedHelp =
        "Unavailable while an account is being un-seeded — the homes it would launch from are "
        + "being torn down."
}

/// (v102) The unresolved ("UNLINKED") card's copy and action, which differ by epoch. Under v1 and
/// shadow the keychain login IS the live rail, so linking it to a banked account is the one useful
/// thing to do and `bank-account.sh` can do it. Under v2 it is a leftover: sessions pin their own
/// home, the legacy slot only drains whatever old sessions still hold it, and a re-bank is fenced
/// (rc 78) — so offering the button would be offering a flow the epoch refuses. Pure so the
/// epoch-by-epoch surface is a contract test.
enum UnresolvedCardPresentation {
    static func showsLinkButton(epoch: EpochState) -> Bool { epoch != .v2 }

    static func caption(epoch: EpochState, displayName: String) -> String {
        guard epoch == .v2 else {
            return "This login isn't linked to a tracked account yet. Link it to attribute usage."
        }
        return "pre-cutover login — drains \(displayName), expires with old sessions"
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
    /// (v102) Which destructive action the armed strip is confirming. Remove forgets a v1 bank
    /// record; un-seed tears down a v2 home. They are different operations on different cards, but
    /// they share this one slot so the "only one strip open anywhere" invariant still holds
    /// structurally — a card cannot be armed for both at once, and arming either disarms the other.
    enum Kind: Equatable {
        case remove
        case unseed
    }

    struct Armed: Equatable {
        let email: String
        let kind: Kind
    }

    private(set) var armed: Armed?

    var armedEmail: String? { armed?.email }

    var isArmed: Bool { armed != nil }

    func isArmed(email: String) -> Bool { armed?.email == email }

    func isArmed(email: String, kind: Kind) -> Bool {
        armed == Armed(email: email, kind: kind)
    }

    /// Tapping the × on a card: arm it if disarmed, disarm it if it is the armed one. Arming a
    /// different card while one is already armed silently moves the strip (only one at a time).
    mutating func toggle(email: String, kind: Kind = .remove) {
        let candidate = Armed(email: email, kind: kind)
        armed = (armed == candidate) ? nil : candidate
    }

    /// Cancel button, or a completed removal: hide the strip.
    mutating func disarm() {
        armed = nil
    }

    /// Popover open/close: never leave a card armed across a popover lifecycle.
    mutating func reset() {
        armed = nil
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

    /// (v102) The account region's own top inset. It exists to open a gap below the popover's top
    /// edge, so it applies ONLY when the cards are the first thing in the popover. When a cached
    /// badge or a health banner sits above them, that inset stacked on top of the VStack's 10pt
    /// spacing pushed the first card 22pt clear of the banner — a gap wide enough to read as a
    /// section break between the warning and the account it is warning about. Zeroing it there
    /// leaves exactly the 10pt card rhythm, so the banner sits in the stack like another card.
    /// The estimator has to agree with the view or the ScrollView's frame is off by the difference.
    static func topInset(isStale: Bool, hasHealthBanner: Bool) -> CGFloat {
        (isStale || hasHealthBanner) ? 0 : 12
    }

    static func estimatedHeight(
        claudeAccounts: Int,
        reloginAccounts: Int,
        hasCodex: Bool,
        isStale: Bool,
        hasHealthBanner: Bool
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
        total += topInset(isStale: isStale, hasHealthBanner: hasHealthBanner) + 2
        return total
    }

    static func needsScroll(
        claudeAccounts: Int,
        reloginAccounts: Int,
        hasCodex: Bool,
        isStale: Bool,
        hasHealthBanner: Bool
    ) -> Bool {
        estimatedHeight(
            claudeAccounts: claudeAccounts, reloginAccounts: reloginAccounts,
            hasCodex: hasCodex, isStale: isStale, hasHealthBanner: hasHealthBanner
        ) > maxAccountRegionHeight
    }

    static func regionHeight(
        claudeAccounts: Int,
        reloginAccounts: Int,
        hasCodex: Bool,
        isStale: Bool,
        hasHealthBanner: Bool
    ) -> CGFloat {
        min(
            estimatedHeight(
                claudeAccounts: claudeAccounts, reloginAccounts: reloginAccounts,
                hasCodex: hasCodex, isStale: isStale, hasHealthBanner: hasHealthBanner
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
        PingCountdown.title(remaining: remaining)
    }
}

/// (v102) The ping button's cooldown label, for both the Claude cards and the Codex card. It used
/// to round up to whole minutes, so a 30-minute cooldown showed the same "Ping · 12m" for sixty
/// seconds at a stretch and read as a stuck button rather than a running clock. M:SS ticks once a
/// second against the model's shared clock, which the popover drives only while it is open — so the
/// countdown is live when it is being looked at and costs nothing when it is not. Being text, it
/// needs no reduce-motion branch; the label is set in monospaced digits so it doesn't jitter.
enum PingCountdown {
    static func title(remaining: TimeInterval) -> String {
        guard let clock = clock(remaining: remaining) else { return "Ping" }
        return "Ping · \(clock)"
    }

    /// M:SS (seconds always two digits), or nil once the cooldown has lapsed. Rounded UP so the
    /// label never shows 0:00 on a button that is still disabled.
    static func clock(remaining: TimeInterval) -> String? {
        guard remaining.isFinite else { return nil }
        let seconds = Int(remaining.rounded(.up))
        guard seconds > 0 else { return nil }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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

/// (v102-r2) THE update-check allowlist, as a decision rather than a string.
///
/// The app makes exactly one network request, to one document. "One endpoint" was enforced by
/// pinning the URL literal — but the system URL loader follows redirects by default, so a 302
/// from that literal would have taken the connection (and the product/version User-Agent, and
/// this machine's IP) to whatever host the response named. Nothing secret rides along; the point
/// is that the boundary the app claims is the boundary it actually has.
///
/// So the allowlist is a predicate, applied twice: to the URL before the request is made (an
/// edited literal disables the check instead of retargeting it) and to the URL that actually
/// answered. Redirects are refused outright at the session delegate, which is what makes the
/// second check a belt to the first's braces rather than the only guard.
enum UpdateEndpoint {
    static let host = "api.github.com"
    static let path = "/repos/ronit111/quotabar/releases/latest"

    /// HTTPS, that exact host, that exact path, and nothing else: no query, no userinfo, no
    /// non-default port. Case-insensitive on scheme and host because URLs are; exact on path
    /// because paths are not.
    static func isAllowed(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host,
              url.path == path,
              url.query == nil, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443
        else { return false }
        return true
    }
}

/// (v102-r2) The one gate that has to exist app-side rather than script-side, because a pinned
/// launch is the one action that does NOT go through the FIFO: it opens a Terminal and returns,
/// so the queue that serializes every other actuator against an un-seed never sees it.
///
/// The scripts close the real hole — `claude-acct` records a launch admission under the same lock
/// un-seed takes, and un-seed refuses while one is live — so the worst this gate prevents is an
/// owner clicking "Pinned session…" and watching the Terminal fail with "no READY home". That is
/// still the wrong thing to show someone who just asked for a session, and offering both controls
/// as live while one is tearing down the very home the other would open reads as a UI that does
/// not know what it is doing. Blocked across ALL cards, not just the one being un-seeded: while a
/// teardown is in flight the whole homes tree is under the seeding barrier anyway.
enum PinnedLaunchGate {
    /// `AppModel.ActionKind.unseedAccount.rawValue`.
    static let unseedKind = "unseed"

    static func isBlocked(busyKinds: some Sequence<String>) -> Bool {
        busyKinds.contains(unseedKind)
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
    /// (v102) The one NON-anomaly entry on this pipe: a plan-tier change the poll already
    /// HEALED. It rides the health payload because that is the only channel the app reads, and
    /// because the change has to stay visible now that the UNLINKED chip it used to surface as
    /// is gone. Present only while a notice is pending; it self-expires after 24h.
    struct HealedPlanChange: Decodable, Sendable {
        let fromPlan: String?
        let toPlan: String?
        let email: String?
        let ts: Int?
        enum CodingKeys: String, CodingKey {
            case fromPlan = "from"
            case toPlan = "to"
            case email, ts
        }
    }
    let archiver: Archiver?
    let forkDrift: [String: [String]]?
    let seedAudit: SeedAudit?
    let healedPlanChange: HealedPlanChange?
    enum CodingKeys: String, CodingKey {
        case archiver
        case forkDrift = "fork_drift"
        case seedAudit = "seed_audit"
        case healedPlanChange = "healed_plan_change"
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

    /// (v102) A plan-tier change the poll already re-banked. Deliberately NOT epoch-gated, unlike
    /// every other row here: the archiver/registry rows describe v2 machinery, but a subscription
    /// can change under a v1 user just as easily, and the heal that follows runs in the same poll
    /// either way. Reports settled fact, so the view styles it as information, not as a warning.
    /// Dismissal is remembered by timestamp app-side as well as acknowledged script-side, so a
    /// failed ack can't turn a one-time notice into permanent chrome.
    static func healedPlanChange(_ health: Health?, ackedTs: Int) -> (ts: Int, text: String)? {
        guard let change = health?.healedPlanChange,
              let ts = change.ts, ts > ackedTs,
              let email = change.email, !email.isEmpty,
              let to = PlanCapsulePresentation.text(for: change.toPlan)
        else { return nil }
        // Kept to one line at 11pt in a 320-wide popover. The prose form ("is now X (was Y)")
        // wrapped and broke "re-banked" across lines, which reads as a defect in a row whose
        // whole job is to be unalarming; the transition arrow says the same thing in half the
        // width and is the idiom this app already uses for compact status.
        let who = RemoveAccountPolicy.shortEmail(email)
        if let from = PlanCapsulePresentation.text(for: change.fromPlan), from != to {
            return (ts, "\(who) \(from) → \(to) · re-banked")
        }
        return (ts, "\(who) is now \(to) · re-banked")
    }

    /// True when NOTHING on this pipe has anything to show — the popover renders no health
    /// chrome at all. (v102-r2) The plan-change notice counts. It is not an anomaly, but it IS a
    /// row, and a "healthy" verdict that ignored it would be a second opinion disagreeing with
    /// the one the view acts on (AppModel.hasHealthAnomaly) — exactly the drift that let the
    /// notice be emitted with nowhere to land in the first place.
    static func isHealthy(
        _ health: Health?, epoch: EpochState, seedAuditAckTs: Int, healNoticeAckTs: Int = 0
    ) -> Bool {
        archiverWarning(health, epoch: epoch) == nil
            && forkDriftLine(health, epoch: epoch) == nil
            && seedAuditReview(health, epoch: epoch, ackedTs: seedAuditAckTs) == nil
            && healedPlanChange(health, ackedTs: healNoticeAckTs) == nil
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

// MARK: - (v102) update-available hint

/// A `major.minor.patch` version, for comparing this build against the newest published release.
/// Deliberately strict: an optional leading `v` and exactly three numeric components, nothing else.
/// A tag that doesn't match — a pre-release, a date stamp, anything hand-typed — parses to nil and
/// the hint stays hidden, because offering an upgrade we can't reason about is worse than silence.
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String { "\(major).\(minor).\(patch)" }

    static func parse(_ raw: String?) -> SemanticVersion? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        return SemanticVersion(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// When the once-a-day update check is allowed to fire. The timestamp is persisted, so quitting and
/// relaunching all afternoon does not turn "once a day" into "once a launch" — the cadence belongs
/// to the machine, not the process. A failed check counts as an attempt for exactly the same
/// reason: an endpoint that is down should be retried tomorrow, not on every relaunch in between.
enum UpdateCheckSchedule {
    static let interval: TimeInterval = 86_400

    static func shouldCheck(enabled: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        // A timestamp in the future means the clock moved backwards; treat it as due rather than
        // waiting for wall time to catch up to a reading that was never real.
        if elapsed < 0 { return true }
        return elapsed >= interval
    }
}

/// The footer hint's copy and the decision to show it at all. Everything here is a pure function of
/// three strings, so the version comparison, the per-version dismissal and the exact line are
/// contract tests rather than something you have to publish a release to see.
enum UpdateHint {
    /// The newest version worth telling the owner about, or nil to stay silent. Nil covers every
    /// ordinary case: no check has run, the tag is unparseable, we are current (or ahead of a
    /// re-tagged release), or the owner already dismissed exactly this version.
    static func availableVersion(
        current: String?,
        latestTag: String?,
        dismissedVersion: String?
    ) -> SemanticVersion? {
        guard let current = SemanticVersion.parse(current),
              let latest = SemanticVersion.parse(latestTag),
              latest > current
        else { return nil }
        // Dismissal is per-version, compared as versions rather than strings, so dismissing
        // "v1.0.3" also silences "1.0.3" — and neither silences 1.0.4 when it lands.
        if let dismissed = SemanticVersion.parse(dismissedVersion), dismissed == latest {
            return nil
        }
        return latest
    }

    /// One line, in the footer caption idiom: what is available, and the one command that gets it.
    static func line(version: SemanticVersion) -> String {
        "\(version) available · brew upgrade --cask quotabar"
    }

    /// The User-Agent the check identifies itself with. Honest and inert: the product, the version
    /// it is, and nothing that identifies the machine or the person running it.
    static func userAgent(version: String?) -> String {
        let version = (version?.isEmpty == false) ? version! : "unknown"
        return "QuotaBar/\(version)"
    }

    /// `tag_name` out of the releases payload. Anything else in the response is ignored — the tag
    /// is the only field this feature has any use for.
    static func tagName(fromJSON data: Data) -> String? {
        struct Release: Decodable { let tagName: String?
            enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              let tag = release.tagName, !tag.isEmpty
        else { return nil }
        return tag
    }
}

/// (v102) The inner shell command a Terminal window is opened on. Both Terminal launches the app
/// performs — the guided add-account flow and a pinned session — go through here, so the quoting
/// rule lives in one place and is a contract test rather than a string built at two call sites.
enum TerminalLaunch {
    static func addAccountCommand(bash: String, claudeAcct: String, email: String) -> String {
        "\(bash) \(quote(claudeAcct)) --add \(quote(email))"
    }

    static func pinnedSessionCommand(bash: String, claudeAcct: String, email: String) -> String {
        "\(bash) \(quote(claudeAcct)) \(quote(email))"
    }

    /// Single-quote for `sh`: everything inside is literal, and an embedded quote is closed,
    /// escaped and reopened. An address is not trusted input just because it looks like one.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
