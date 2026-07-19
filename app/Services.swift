import AppKit
import Combine
import Darwin
import Dispatch
import Foundation
import ServiceManagement

struct ScriptResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

enum ScriptFailure: Error, LocalizedError, Sendable {
    case launchFailed(String)
    case timedOut
    case cancelled
    case nonZeroExit(code: Int32, stderr: String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message): message
        case .timedOut: "Script timed out"
        case .cancelled: "Script cancelled"
        case .nonZeroExit(_, let stderr): stderr.isEmpty ? "Script failed" : stderr
        case .emptyOutput: "Script returned no data"
        }
    }

    var firstStderrLine: String? {
        guard case .nonZeroExit(_, let stderr) = self else { return nil }
        return stderr.split(whereSeparator: \Character.isNewline).first.map(String.init)
    }
}

enum ScriptRunner {
    private static let outputLimit = 512 * 1_024

    static func run(
        executable: String,
        arguments: [String],
        policy: ScriptExecutionPolicy = .utility,
        environment: [String: String] = [:],
        timeoutOverride: TimeInterval? = nil
    ) async throws -> ScriptResult {
        let control = ProcessControl(policy: policy)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try runSynchronously(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    timeout: timeoutOverride ?? policy.timeout,
                    policy: policy,
                    control: control
                )
            }.value
        } onCancel: {
            control.requestStop(.cancelled)
        }
    }

    private static func runSynchronously(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        policy: ScriptExecutionPolicy,
        control: ProcessControl
    ) throws -> ScriptResult {
        if control.isCancelled { throw ScriptFailure.cancelled }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = BoundedDataBuffer(limit: outputLimit)
        let stderrBuffer = BoundedDataBuffer(limit: outputLimit)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) {
                _, override in override
            }
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .utility
        control.attach(process)

        do {
            try process.run()
        } catch {
            control.markFinished()
            throw ScriptFailure.launchFailed(error.localizedDescription)
        }
        if control.isCancelled {
            control.requestStop(.cancelled)
        }

        let drains = DispatchGroup()
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(stdoutPipe.fileHandleForReading, into: stdoutBuffer)
            drains.leave()
        }
        drains.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(stderrPipe.fileHandleForReading, into: stderrBuffer)
            drains.leave()
        }

        let timeoutAt = Date().addingTimeInterval(timeout)
        while process.isRunning, control.stopReason == nil, Date() < timeoutAt {
            usleep(50_000)
        }
        if process.isRunning, control.stopReason == nil {
            control.requestStop(.timedOut)
        }

        if control.stopReason != nil {
            let graceEnds = Date().addingTimeInterval(policy.terminationGrace)
            while process.isRunning, Date() < graceEnds {
                usleep(50_000)
            }
            if process.isRunning, policy.sendsTreeSIGKILL {
                control.forceKillProcessTree()
                let reapEnds = Date().addingTimeInterval(2)
                while process.isRunning, Date() < reapEnds {
                    usleep(50_000)
                }
            }
        }

        let stillRunning = process.isRunning
        if !stillRunning {
            process.waitUntilExit()
        }
        control.markFinished()

        if !stillRunning, control.stopReason == nil || policy.sendsTreeSIGKILL {
            // A missed descendant can retain a pipe after the parent exits. Bound the drain
            // only once the launched process is gone. For TERM-only work that outlives the
            // grace, leave its pipes alone so it can finish its transaction independently.
            if drains.wait(timeout: .now() + 2) == .timedOut {
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
                _ = drains.wait(timeout: .now() + 1)
            }
        }

        let stdout = stdoutBuffer.data
        let stderr = stderrBuffer.data
        switch control.stopReason {
        case .cancelled: throw ScriptFailure.cancelled
        case .timedOut: throw ScriptFailure.timedOut
        case nil: break
        }

        let stderrText = String(data: stderr, encoding: .utf8) ?? ""
        guard !stillRunning else { throw ScriptFailure.timedOut }
        guard process.terminationStatus == 0 else {
            throw ScriptFailure.nonZeroExit(code: process.terminationStatus, stderr: stderrText)
        }
        return ScriptResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func drain(_ handle: FileHandle, into buffer: BoundedDataBuffer) {
        // Read the raw descriptor rather than FileHandle.availableData: when the bounded
        // drain closes the read end from another thread, read() returns EBADF and this
        // loop unwinds cleanly, whereas availableData would raise an uncatchable ObjC
        // exception on a closed handle.
        let fd = handle.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                buffer.append(Data(chunk[0..<count]))
            } else if count == 0 {
                break
            } else {
                if errno == EINTR { continue }
                break
            }
        }
        try? handle.close()
    }

    /// Full descendant PID set of `pid`, breadth-first via `pgrep -P`. Gathered before the
    /// kill so children aren't reparented to launchd (and lost) when the group leader dies.
    static func descendantPIDs(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var frontier = [pid]
        var guardCount = 0
        while let current = frontier.popLast(), guardCount < 4_096 {
            guardCount += 1
            for child in childPIDs(of: current) where !result.contains(child) {
                result.append(child)
                frontier.append(child)
            }
        }
        return result
    }

    private static func childPIDs(of pid: Int32) -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \Character.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}

private enum ProcessStopReason: Sendable {
    case timedOut
    case cancelled
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private let policy: ScriptExecutionPolicy
    private var process: Process?
    private var finished = false
    private var reason: ProcessStopReason?

    init(policy: ScriptExecutionPolicy) {
        self.policy = policy
    }

    var stopReason: ProcessStopReason? {
        lock.withLock { reason }
    }

    var isCancelled: Bool {
        lock.withLock { reason == .cancelled }
    }

    func attach(_ process: Process) {
        lock.withLock {
            self.process = process
        }
    }

    func markFinished() {
        lock.withLock {
            finished = true
        }
    }

    func requestStop(_ requestedReason: ProcessStopReason) {
        let target: (Process, Int32)? = lock.withLock {
            guard !finished else { return nil }
            if reason == nil { reason = requestedReason }
            guard let process, process.isRunning else { return nil }
            return (process, process.processIdentifier)
        }
        guard let (process, pid) = target else { return }

        // TERM the whole tree while the parent still owns its children. Mutating work
        // never escalates beyond this signal, even if it outlives the grace period.
        let descendants = ScriptRunner.descendantPIDs(of: pid)
        for child in descendants { Darwin.kill(child, SIGTERM) }
        process.terminate()
    }

    func forceKillProcessTree() {
        guard policy.sendsTreeSIGKILL else { return }
        let target: (Process, Int32)? = lock.withLock {
            guard !finished, let process, process.isRunning else { return nil }
            return (process, process.processIdentifier)
        }
        guard let (_, pid) = target else { return }
        let descendants = ScriptRunner.descendantPIDs(of: pid)
        Darwin.kill(pid, SIGKILL)
        for child in descendants { Darwin.kill(child, SIGKILL) }
    }
}

private final class BoundedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()

    init(limit: Int) {
        self.limit = limit
    }

    var data: Data {
        lock.withLock { storage }
    }

    func append(_ data: Data) {
        lock.withLock {
            let remaining = max(0, limit - storage.count)
            if remaining > 0 {
                storage.append(data.prefix(remaining))
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

enum LoginItemState: String, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor
final class AppModel: ObservableObject {
    private enum ActionKind: String {
        case ping
        case switchAccount = "switch"
        case rebank
        case toggleAutoPing = "autoping"
        case removeAccount = "remove"
        case codexPing = "codexping"
    }

    /// A single mutating action queued through the global FIFO. `key` names the card whose
    /// spinner/queued/status state it drives (email for Claude cards, "codex" for the Codex card).
    private struct PendingAction {
        let kind: ActionKind
        let key: String
        let executable: String
        let arguments: [String]
        let successMessage: String?
    }

    private enum PendingWork {
        case usagePoll(UsagePollMode)
        case action(PendingAction)
    }

    private enum Paths {
        static let python = "/usr/bin/python3"
        static let bash = "/bin/bash"
        static let env = "/usr/bin/env"

        /// Directory holding the account-bank scripts, resolved once at launch, in order:
        ///   1. $QUOTABAR_SCRIPTS_DIR                 (explicit override)
        ///   2. ~/.local/share/quotabar/account-bank  (where install.sh puts them)
        ///   3. Contents/Resources/account-bank       (the copy bundled in the app)
        /// The first location that actually contains usage.py wins. If none do, the
        /// install path is returned so any resulting error names a stable location.
        static let scripts = resolveScriptsDir()

        static let usage = "\(scripts)/usage.py"
        static let ping = "\(scripts)/ping-account.sh"
        static let swap = "\(scripts)/swap-account.sh"
        static let bank = "\(scripts)/bank-account.sh"
        static let toggleAutoPing = "\(scripts)/toggle-autoping.sh"
        static let removeAccount = "\(scripts)/remove-account.sh"

        private static func resolveScriptsDir() -> String {
            let fileManager = FileManager.default
            var candidates: [String] = []
            if let override = ProcessInfo.processInfo.environment["QUOTABAR_SCRIPTS_DIR"],
               !override.isEmpty {
                candidates.append(override)
            }
            let installPath = BankLocation.dataHome
                .appendingPathComponent("quotabar/account-bank", isDirectory: true).path
            candidates.append(installPath)
            if let bundled = Bundle.main.resourceURL?
                .appendingPathComponent("account-bank", isDirectory: true).path {
                candidates.append(bundled)
            }
            for dir in candidates where fileManager.fileExists(atPath: "\(dir)/usage.py") {
                return dir
            }
            return installPath
        }
    }

    static let codexCardKey = "codex"

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isStale = true
    @Published private(set) var lastErrorDescription: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var currentDate = Date()
    @Published private(set) var autoPingEmails: Set<String> = []
    @Published private(set) var lastPingByEmail: [String: Date] = [:]
    @Published private(set) var loginItemState: LoginItemState = .notRegistered
    @Published private(set) var loginItemError: String?
    @Published private(set) var codexBinaryPath: String?
    @Published private(set) var codexLastPing: Date?
    @Published private var busyActions: [String: ActionKind] = [:]
    @Published private var scheduler = ActionScheduler<PendingWork>()
    @Published private var cardErrors: [String: String] = [:]
    @Published private var cardStatuses: [String: String] = [:]
    @Published private var updatingAccountID: String?
    @Published private var forcedStaleAccountIDs: Set<String> = []
    @Published private(set) var removalConfirmation = InlineRemovalConfirmation()

    private var lastSuccessfulUpdate: Date?
    private var pendingRefreshRequest: PendingRefreshRequest?
    private var pollLoopTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var staleRetryTask: Task<Void, Never>?
    private var popoverIsOpen = false
    private var activeAccountDriftTracker = ActiveAccountDriftTracker()
    private var starredRefreshDebouncer = StarredRefreshDebouncer()

    private static let codexLastPingKey = "codexLastPing"
    private static let usagePollKey = "__usage_poll__"

    init() {
        refreshLoginItemStatus()
        codexLastPing = Self.loadCodexLastPing()

        Task { [weak self] in
            self?.refresh()
        }

        Task { [weak self] in
            await self?.resolveCodexBinary()
        }

        pollLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.refresh()
            }
        }

        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.currentDate = Date()
            }
        }
    }

    deinit {
        pollLoopTask?.cancel()
        tickerTask?.cancel()
        staleRetryTask?.cancel()
    }

    var claudeAccounts: [UsageAccount] {
        AccountOrdering.claudeAccountsInSnapshotOrder(snapshot?.accounts ?? [])
    }

    var codexAccount: UsageAccount? {
        snapshot?.accounts.first(where: \UsageAccount.isCodex)
    }

    var activeAccountInitial: String {
        claudeAccounts.first(where: \.active)?.email.first
            .map { String($0).uppercased() } ?? ""
    }

    var iconSymbolName: String {
        claudeAccounts.contains(where: \UsageAccount.needsRelogin)
            ? "bolt.trianglebadge.exclamationmark"
            : "bolt.fill"
    }

    /// Bolt tint reflects the ACTIVE Claude account's worst limit (the monogram names it).
    var iconSeverity: Severity? {
        guard !isStale, snapshot != nil else { return nil }
        return claudeAccounts.first(where: \.active)?.severity
    }

    /// Worst severity among PARKED Claude accounts that warrant attention (warning-or-worse,
    /// or needing relogin). Drives the secondary dot cue on the menu bar icon; nil = no cue.
    var parkedAlertSeverity: Severity? {
        guard !isStale, snapshot != nil else { return nil }
        var worst: Severity?
        for account in claudeAccounts where !account.active {
            let candidate: Severity?
            if account.needsRelogin {
                candidate = .critical
            } else if let severity = account.severity, severity >= .warning {
                candidate = severity
            } else {
                candidate = nil
            }
            if let candidate {
                worst = worst.map { Swift.max($0, candidate) } ?? candidate
            }
        }
        return worst
    }

    var updatedText: String {
        TimeFormatting.updatedAgo(from: lastSuccessfulUpdate, now: currentDate)
    }

    var cachedAgeText: String {
        let oldestCachedEntry = snapshot?.accounts
            .filter(\.isCachedEntry)
            .compactMap(\.fetchedAtDate)
            .min()
        return TimeFormatting.cachedAgo(
            from: oldestCachedEntry ?? lastSuccessfulUpdate,
            now: currentDate
        )
    }

    var loginItemEnabled: Bool {
        loginItemState == .enabled
    }

    func popoverOpened() {
        popoverIsOpen = true
        removalConfirmation.reset()
        if let accounts = snapshot?.accounts {
            let now = Date()
            if AccountFreshness.shouldPollOnOpen(accounts: accounts, now: now),
               starredRefreshDebouncer.accept(now: now) {
                requestRefresh(.starred)
            }
        } else {
            refresh()
        }
        updateStaleRetrySchedule()
    }

    func popoverClosed() {
        popoverIsOpen = false
        // The inline remove strip lives inside the popover; resetting here is the sole mechanism
        // that guarantees a half-armed card can never re-render pre-armed when the popover reopens
        // (this is what the old `.confirmationDialog` failed to do — its binding outlived the close).
        removalConfirmation.reset()
        updateStaleRetrySchedule()
    }

    // MARK: Inline remove-account confirmation

    /// Toggle the inline "Remove <email>?" strip for a parked Claude card (tap the ×). Arming one
    /// card disarms any other (single-Optional state), so only one strip is ever open.
    func toggleRemovalConfirmation(_ account: UsageAccount) {
        guard RemoveAccountPolicy.canRemove(account) else { return }
        removalConfirmation.toggle(email: account.email)
    }

    /// Cancel button in the inline strip (or the × tapped a second time).
    func cancelRemovalConfirmation() {
        removalConfirmation.disarm()
    }

    func isArmedForRemoval(_ account: UsageAccount) -> Bool {
        removalConfirmation.isArmed(email: account.email)
    }

    /// Remove button in the inline strip: routes through the existing `removeAccount` FIFO path
    /// unchanged, then hides the strip immediately (the card itself vanishes on the next poll).
    func confirmRemoval(_ account: UsageAccount) {
        removalConfirmation.disarm()
        removeAccount(account)
    }

    func refresh() {
        requestRefresh(.regular)
    }

    private func requestRefresh(_ request: PendingRefreshRequest) {
        if isRefreshing {
            pendingRefreshRequest = PendingRefreshRequest.merged(
                pendingRefreshRequest,
                with: request
            )
            return
        }

        isRefreshing = true
        scheduler.enqueue(
            key: Self.usagePollKey,
            payload: .usagePoll(request.pollMode),
            priority: .background
        )
        startWorkPumpIfNeeded()
    }

    func ping(_ account: UsageAccount) {
        guard !account.needsRelogin, !isPingCoolingDown(email: account.email) else { return }
        enqueueAction(.ping, key: account.email, executable: Paths.bash,
                      arguments: [Paths.ping, account.email], successMessage: "Pinged")
    }

    func switchHere(_ account: UsageAccount) {
        guard !account.active, !account.needsRelogin else { return }
        enqueueAction(.switchAccount, key: account.email, executable: Paths.bash,
                      arguments: [Paths.swap, account.email], successMessage: "Switched")
    }

    func rebank(_ account: UsageAccount) {
        enqueueAction(.rebank, key: account.email, executable: Paths.bash,
                      arguments: [Paths.bank], successMessage: "Re-banked")
    }

    func toggleAutoPing(_ account: UsageAccount) {
        guard account.isClaude else { return }
        // No success caption: the badge itself reflects the new state after the re-poll.
        enqueueAction(.toggleAutoPing, key: account.email, executable: Paths.bash,
                      arguments: [Paths.toggleAutoPing, account.email], successMessage: nil)
    }

    /// Forget a PARKED Claude account: deletes its bank record and drops it from auto-ping via
    /// remove-account.sh, routed through the same global FIFO as ping/switch/toggle so it can
    /// never race a swap. Guarded by RemoveAccountPolicy (never the active account, never Codex).
    func removeAccount(_ account: UsageAccount) {
        guard RemoveAccountPolicy.canRemove(account) else { return }
        enqueueAction(.removeAccount, key: account.email, executable: Paths.bash,
                      arguments: [Paths.removeAccount, account.email], successMessage: nil)
    }

    func codexPing() {
        guard let codex = codexBinaryPath, !codex.isEmpty, !isCodexPingCoolingDown else { return }
        enqueueAction(.codexPing, key: Self.codexCardKey, executable: codex,
                      arguments: ["exec", "reply with just: ok", "--skip-git-repo-check"],
                      successMessage: "Pinged")
    }

    func isBusy(email: String) -> Bool {
        busyActions[email] != nil
    }

    func busyAction(email: String) -> String? {
        busyActions[email]?.rawValue
    }

    func isQueued(email: String) -> Bool {
        scheduler.isQueued(email)
    }

    // MARK: Codex ping state

    var codexPingAvailable: Bool {
        CodexPing.isAvailable(binaryPath: codexBinaryPath)
    }

    var codexPingRemaining: TimeInterval {
        CodexPing.remaining(lastPing: codexLastPing, now: currentDate)
    }

    var isCodexPingCoolingDown: Bool {
        codexPingRemaining > 0
    }

    var isCodexBusy: Bool {
        busyActions[Self.codexCardKey] != nil
    }

    var isCodexPingRunning: Bool {
        busyActions[Self.codexCardKey] == .codexPing && !scheduler.isQueued(Self.codexCardKey)
    }

    var isCodexQueued: Bool {
        scheduler.isQueued(Self.codexCardKey)
    }

    var codexCardError: String? {
        cardErrors[Self.codexCardKey]
    }

    var codexCardStatus: String? {
        cardStatuses[Self.codexCardKey]
    }

    var codexPingTitle: String {
        CodexPing.buttonTitle(remaining: codexPingRemaining)
    }

    func pingRemaining(email: String) -> TimeInterval {
        TimeFormatting.cooldownRemaining(lastPing: lastPingByEmail[email], now: currentDate)
    }

    func isPingCoolingDown(email: String) -> Bool {
        pingRemaining(email: email) > 0
    }

    func cardError(email: String) -> String? {
        cardErrors[email]
    }

    func cardStatus(email: String) -> String? {
        cardStatuses[email]
    }

    func freshness(for account: UsageAccount) -> CardFreshness {
        AccountFreshness.state(
            for: account,
            now: currentDate,
            isUpdating: updatingAccountID == account.id,
            isForcedStale: forcedStaleAccountIDs.contains(account.id)
        )
    }

    func freshnessCaption(for account: UsageAccount) -> String? {
        AccountFreshness.caption(
            for: account,
            now: currentDate,
            freshness: freshness(for: account)
        )
    }

    /// One-line usage summary for the clipboard, e.g.
    /// "Z 33% 5h · R 100% (resets 07:50) · Codex 34%".
    func usageSummaryLine() -> String {
        var parts: [String] = []
        for account in claudeAccounts {
            let initial = account.email.first.map { String($0).uppercased() } ?? "?"
            if account.needsRelogin {
                parts.append("\(initial) relogin")
                continue
            }
            guard let worst = account.worstLimit else {
                parts.append("\(initial) —")
                continue
            }
            let percent = Int(worst.percent.rounded())
            if percent >= 85, let reset = worst.resetsAt {
                parts.append("\(initial) \(percent)% (resets \(TimeFormatting.clockString(reset)))")
            } else {
                parts.append("\(initial) \(percent)% \(Self.shortWindow(worst.kind))")
            }
        }
        if let codex = codexAccount, let worst = codex.worstLimit {
            parts.append("Codex \(Int(worst.percent.rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    func copyUsageSummary() {
        let line = usageSummaryLine()
        guard !line.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(line, forType: .string)
    }

    private static func shortWindow(_ kind: String) -> String {
        switch kind.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "session", "five_hour", "5h": return "5h"
        case "weekly", "week", "seven_day": return "wk"
        default: return kind
        }
    }

    func isAutoPing(email: String) -> Bool {
        autoPingEmails.contains(email)
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItemStatus()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func fetchUsageSnapshot(mode: UsagePollMode = .regular) async throws -> UsageSnapshot {
        let result = try await ScriptRunner.run(
            executable: Paths.python,
            arguments: [Paths.usage],
            policy: .usagePoll,
            environment: UsagePollEnvironment.values(for: mode)
        )
        guard !result.stdout.isEmpty else { throw ScriptFailure.emptyOutput }
        return try UsageSnapshot.decode(from: result.stdout)
    }

    private func applyUsageSnapshot(_ decoded: UsageSnapshot) {
        snapshot = decoded
        lastSuccessfulUpdate = decoded.generatedAt
        forcedStaleAccountIDs = AccountFreshness.reconciledForcedStaleAccountIDs(
            forcedStaleAccountIDs,
            with: decoded.accounts
        )
        isStale = decoded.representsCachedData || !forcedStaleAccountIDs.isEmpty
        lastErrorDescription = nil
        loadAccountIndicators(for: decoded.accounts.filter(\.isClaude).map(\.email))
    }

    private func pollOnce(mode: UsagePollMode) async {
        do {
            let decoded = try await fetchUsageSnapshot(mode: mode)
            let followUpEmail = activeAccountDriftTracker.followUpEmail(
                afterSuccessfulPoll: decoded,
                now: Date()
            )
            applyUsageSnapshot(decoded)

            if let followUpEmail {
                do {
                    let followUp = try await fetchUsageSnapshot(mode: .forceFresh(followUpEmail))
                    activeAccountDriftTracker.recordSuccessfulPoll(followUp)
                    applyUsageSnapshot(followUp)
                } catch {
                    Self.debugLog("active-account force-fresh follow-up failed: \(error)")
                }
            }
        } catch {
            isStale = true
            lastErrorDescription = String(describing: error)
            Self.debugLog("pollOnce failed: \(error)")
        }
        updateStaleRetrySchedule()
    }

    /// Keep the switch action successful while separately proving that its target has fresh data.
    /// This is awaited inside the active work-pump item so no queued action can overtake it.
    private func confirmSwitchedAccount(email: String) async {
        do {
            let decoded = try await fetchUsageSnapshot(mode: .only(email))
            activeAccountDriftTracker.recordSuccessfulPoll(decoded)
            let target = decoded.accounts.first { $0.isClaude && $0.email == email }
            if let target, AccountFreshness.isValidConfirmationEntry(target) {
                applyUsageSnapshot(decoded)
            } else {
                forcedStaleAccountIDs = AccountFreshness.reconciledForcedStaleAccountIDs(
                    forcedStaleAccountIDs,
                    with: decoded.accounts
                )
                if target != nil {
                    applyUsageSnapshot(decoded.optimisticallyActivatingClaudeAccount(email: email))
                }
                forcedStaleAccountIDs.insert("claude:\(email)")
                isStale = true
                lastErrorDescription = "Fresh usage confirmation unavailable"
            }
        } catch {
            forcedStaleAccountIDs.insert("claude:\(email)")
            isStale = true
            lastErrorDescription = String(describing: error)
        }
        updatingAccountID = nil
        updateStaleRetrySchedule()
    }

    static func debugLog(_ message: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/QuotaBar.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Enqueue a mutating action. Usage polls use this same FIFO, so the app never starts
    /// a poll and an action concurrently against the account-bank lock.
    private func enqueueAction(
        _ kind: ActionKind,
        key: String,
        executable: String,
        arguments: [String],
        successMessage: String?
    ) {
        guard busyActions[key] == nil else { return }
        busyActions[key] = kind
        cardErrors[key] = nil
        cardStatuses[key] = nil

        let action = PendingAction(kind: kind, key: key, executable: executable,
                                   arguments: arguments, successMessage: successMessage)
        scheduler.enqueue(
            key: key,
            payload: .action(action),
            priority: .userInitiated
        )
        startWorkPumpIfNeeded()
    }

    private func startWorkPumpIfNeeded() {
        if scheduler.beginIfIdle() {
            Task { [weak self] in
                await self?.runWorkPump()
            }
        }
    }

    private func runWorkPump() async {
        while let item = scheduler.dequeue() {
            switch item.payload {
            case .usagePoll(let mode):
                await pollOnce(mode: mode)
                isRefreshing = false
                if let pending = pendingRefreshRequest {
                    pendingRefreshRequest = nil
                    requestRefresh(pending)
                }

            case .action(let action):
                await run(action)
            }
        }
        // dequeue() clears `running` once the queue drains.
    }

    private func run(_ action: PendingAction) async {
        let isSwitch = action.kind == .switchAccount
        let scriptStartedAt = DispatchTime.now().uptimeNanoseconds
        var scriptMilliseconds = 0
        var confirmMilliseconds = 0
        defer {
            if isSwitch {
                Self.debugLog(SwitchTimingDiagnostics.line(
                    scriptMilliseconds: scriptMilliseconds,
                    confirmMilliseconds: confirmMilliseconds
                ))
            }
        }

        var failureMessage: String?
        var timedOut = false
        do {
            _ = try await ScriptRunner.run(
                executable: action.executable,
                arguments: action.arguments,
                policy: .mutatingAction
            )
        } catch ScriptFailure.timedOut {
            timedOut = true
        } catch let failure as ScriptFailure {
            failureMessage = failure.firstStderrLine
                ?? failure.errorDescription
                ?? "Script failed"
        } catch {
            failureMessage = "Script failed"
        }
        scriptMilliseconds = SwitchTimingDiagnostics.milliseconds(
            startUptime: scriptStartedAt,
            endUptime: DispatchTime.now().uptimeNanoseconds
        )

        busyActions[action.key] = nil
        if timedOut {
            let status = "still finishing — refresh shortly"
            cardStatuses[action.key] = status
            clearCardStatusLater(key: action.key, matching: status, after: 12)
            scheduleRefresh(after: 5)
        } else if let failureMessage {
            let firstLine = failureMessage
                .split(whereSeparator: \Character.isNewline)
                .first
                .map(String.init) ?? "Script failed"
            cardErrors[action.key] = firstLine
            clearCardErrorLater(key: action.key, matching: firstLine)
            refresh()
        } else {
            if action.kind == .codexPing {
                recordCodexPing()
            }
            if action.kind == .switchAccount {
                snapshot = snapshot?.optimisticallyActivatingClaudeAccount(email: action.key)
                updatingAccountID = "claude:\(action.key)"
            }
            if let status = action.successMessage {
                cardStatuses[action.key] = status
                clearCardStatusLater(key: action.key, matching: status)
            }
            if action.kind == .switchAccount {
                let confirmStartedAt = DispatchTime.now().uptimeNanoseconds
                await confirmSwitchedAccount(email: action.key)
                confirmMilliseconds = SwitchTimingDiagnostics.milliseconds(
                    startUptime: confirmStartedAt,
                    endUptime: DispatchTime.now().uptimeNanoseconds
                )
            } else {
                refresh()
            }
        }
    }

    private func clearCardErrorLater(key: String, matching message: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6 * 1_000_000_000)
            guard let self, cardErrors[key] == message else { return }
            cardErrors[key] = nil
        }
    }

    private func clearCardStatusLater(
        key: String,
        matching message: String,
        after seconds: TimeInterval = 4
    ) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, cardStatuses[key] == message else { return }
            cardStatuses[key] = nil
        }
    }

    private func scheduleRefresh(after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func updateStaleRetrySchedule() {
        guard popoverIsOpen, isStale else {
            staleRetryTask?.cancel()
            staleRetryTask = nil
            return
        }
        guard staleRetryTask == nil else { return }
        staleRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard !Task.isCancelled, let self, self.popoverIsOpen, self.isStale else { break }
                self.refresh()
            }
        }
    }

    private func resolveCodexBinary() async {
        // Resolve once through a login shell so PATH matches the user's interactive env.
        let path: String?
        do {
            let result = try await ScriptRunner.run(
                executable: Paths.env,
                arguments: ["sh", "-lc", "command -v codex"],
                policy: .utility
            )
            let resolved = String(data: result.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            path = resolved.isEmpty ? nil : resolved
        } catch {
            path = nil
        }
        codexBinaryPath = path
    }

    private func recordCodexPing() {
        let now = Date()
        codexLastPing = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.codexLastPingKey)
    }

    private static func loadCodexLastPing() -> Date? {
        let epoch = UserDefaults.standard.double(forKey: codexLastPingKey)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    private func loadAccountIndicators(for emails: [String]) {
        autoPingEmails = AccountFileReader.autoPingEmails()
        var lastPings: [String: Date] = [:]
        for email in emails {
            if let date = AccountFileReader.lastPing(email: email) {
                lastPings[email] = date
            }
        }
        lastPingByEmail = lastPings
    }

    private func refreshLoginItemStatus() {
        switch SMAppService.mainApp.status {
        case .notRegistered: loginItemState = .notRegistered
        case .enabled: loginItemState = .enabled
        case .requiresApproval: loginItemState = .requiresApproval
        case .notFound: loginItemState = .notFound
        @unknown default: loginItemState = .notFound
        }
    }
}

/// Resolves QuotaBar's data locations the same way the shell/python scripts do,
/// so the app and the scripts always agree on where the bank lives.
///   $BANK_DIR                                  (explicit override), else
///   ${XDG_DATA_HOME:-~/.local/share}/quotabar  (the default install location)
private enum BankLocation {
    static var dataHome: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share", isDirectory: true)
    }

    static var bankDir: URL {
        if let bank = ProcessInfo.processInfo.environment["BANK_DIR"], !bank.isEmpty {
            return URL(fileURLWithPath: bank, isDirectory: true)
        }
        return dataHome.appendingPathComponent("quotabar", isDirectory: true)
    }
}

private enum AccountFileReader {
    private struct LastPingRecord: Decodable {
        let lastPing: Double?

        enum CodingKeys: String, CodingKey {
            case lastPing = "last_ping"
        }
    }

    private struct AutoPingConfig: Decodable {
        let autoPing: [String]?

        enum CodingKeys: String, CodingKey {
            case autoPing = "auto_ping"
        }
    }

    /// The bank directory the scripts write to. Matches the scripts' BANK_DIR default
    /// so the app reads the same `.config.json` / `<email>.json` records they write.
    private static var accountsDirectory: URL {
        BankLocation.bankDir
    }

    static func lastPing(email: String) -> Date? {
        guard isSafeFilename(email) else { return nil }
        let url = accountsDirectory.appendingPathComponent("\(email).json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(LastPingRecord.self, from: data),
              let epoch = record.lastPing
        else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    static func autoPingEmails() -> Set<String> {
        let url = accountsDirectory.appendingPathComponent(".config.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AutoPingConfig.self, from: data)
        else { return [] }
        return Set(config.autoPing ?? [])
    }

    private static func isSafeFilename(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && !value.contains("..")
    }
}
