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

    /// The script's exit status, when it ran and failed. Callers map specific codes to readable
    /// card copy (see SwapFailureText) instead of surfacing raw stderr.
    var exitCode: Int32? {
        guard case .nonZeroExit(let code, _) = self else { return nil }
        return code
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
        case restartSession = "restart"
    }

    /// A single mutating action queued through the global FIFO. `key` names the card whose
    /// spinner/queued/status state it drives (email for Claude cards, "codex" for the Codex card,
    /// "restart:<sid>" for an assisted restart). `environment` carries the ACCOUNT_BANK_* dirs to
    /// v2 scripts; `offersRestart` marks a repoint-Switch whose success queries idle sessions.
    private struct PendingAction {
        let kind: ActionKind
        let key: String
        let executable: String
        let arguments: [String]
        let successMessage: String?
        var environment: [String: String] = [:]
        var offersRestart: Bool = false
        // Whether a successful switch flips the ACTIVE account in the display. v1 swap and a v2
        // repoint both do (keychain resp. pointer drive "active"); a SHADOW repoint does NOT —
        // the keychain still names the active account, the repoint only sets future launches.
        var flipsActive: Bool = true
    }

    private enum PendingWork {
        case usagePoll(UsagePollMode)
        case action(PendingAction)
    }

    private enum Paths {
        static let python = "/usr/bin/python3"
        static let bash = "/bin/bash"
        static let env = "/usr/bin/env"

        // (r10 #1) resolved at launch instead of a hard-coded dev path: $QUOTABAR_SCRIPTS_DIR
        // -> the supported XDG install -> the copy bundled in Resources -> (r15 #7) the legacy
        // ~/.claude path, last, so an upgrade cannot keep running pre-upgrade scripts.
        static let scripts: String = ScriptsLocation.resolve()
        // The accounts (bank) control-plane dir that claude-acct / sessions.py / restart.py act
        // on. (r15 #4) Resolved by the ONE documented rule the scripts use:
        // BANK_DIR -> ACCOUNT_BANK_DIR -> ~/.claude/accounts.
        static let accountsDir: String = ScriptsLocation.resolveAccountsDir()

        static let usage = "\(scripts)/usage.py"
        static let ping = "\(scripts)/ping-account.sh"
        static let swap = "\(scripts)/swap-account.sh"
        static let bank = "\(scripts)/bank-account.sh"
        static let toggleAutoPing = "\(scripts)/toggle-autoping.sh"
        static let removeAccount = "\(scripts)/remove-account.sh"
        static let claudeAcct = "\(scripts)/claude-acct"
        static let sessions = "\(scripts)/sessions.py"
        static let restart = "\(scripts)/restart.py"
        static let registry = "\(scripts)/registry.py"

        /// Runtime marker attest-cutover.sh reads to prove the RUNNING app is epoch-aware.
        static let runtimeMarker = "\(accountsDir)/quotabar.runtime.json"
    }

    /// Environment the app hands v2 scripts so claude-acct / sessions.py / restart.py resolve
    /// the SAME accounts + scripts dirs the app resolved (matters on a non-default XDG install).
    /// (r15 #4) BANK_DIR carries the RESOLVED value, not just ACCOUNT_BANK_DIR: it is the
    /// highest-precedence key in the shared rule, so pinning it makes every child agree with
    /// the app by construction instead of re-resolving and possibly landing on another bank.
    private var scriptEnvironment: [String: String] {
        ["BANK_DIR": Paths.accountsDir,
         "ACCOUNT_BANK_DIR": Paths.accountsDir,
         "ACCOUNT_BANK_SCRIPTS_DIR": Paths.scripts]
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
    /// After a shadow|v2 Switch repoints, the set of IDLE sessions that can be moved onto the new
    /// account; nil / empty => no restart affordance shown. Cleared on Move or Dismiss.
    @Published private(set) var restartOffer: RestartOffer?
    /// Per-session restart outcome (sid -> "moved" / a refusal line), shown compactly then cleared.
    @Published private(set) var restartOutcomes: [String: String] = [:]
    /// Newest seed-audit ts the owner has acknowledged (persisted). A seeding event newer than
    /// this surfaces the review line; dismissing sets this to the latest ts.
    @Published private(set) var seedAuditAckTs: Int = 0

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

    private static let seedAuditAckKey = "seedAuditAckTs"

    init() {
        refreshLoginItemStatus()
        codexLastPing = Self.loadCodexLastPing()
        seedAuditAckTs = UserDefaults.standard.integer(forKey: Self.seedAuditAckKey)

        // (v2 wiring) mark THIS running pid epoch-aware so attest-cutover.sh can distinguish the
        // new build from an old one still in memory; removed on a clean quit.
        RuntimeMarker.write(path: Paths.runtimeMarker, pid: getpid())
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in RuntimeMarker.remove(path: Paths.runtimeMarker) }

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
                // keep the runtime marker fresh (and re-create it if something removed it).
                RuntimeMarker.write(path: Paths.runtimeMarker, pid: getpid())
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

    /// Lead-in for the cached-data badge. Only claims "rate-limited" when a 429 marker actually
    /// survives in this snapshot (the active account's error, or the snapshot stale_reason);
    /// otherwise honest generic wording. See `CachedDataBadgeText`.
    var cachedDataHeadline: String {
        CachedDataBadgeText.headline(
            activeError: claudeAccounts.first(where: \.active)?.error,
            staleReason: snapshot?.staleReason
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
        // An unresolved login has no banked identity: pinging would bill an account we
        // cannot name and pass the sentinel to the scripts. Model-layer guard, not view-only.
        guard !account.isUnresolved, !account.needsRelogin,
              !isPingCoolingDown(for: account) else { return }
        enqueueAction(.ping, key: account.email, executable: Paths.bash,
                      arguments: [Paths.ping, account.email], successMessage: "Pinged")
    }

    /// Epoch-aware Switch (§0, rollback-day). v1/shadow/unknown: the v1 SEAMLESS swap-account.sh
    /// — the target becomes active immediately and every running session picks it up on its next
    /// request (turn-level), with `--expect-active` guarding a stale click (SwapInvocation). v2:
    /// claude-acct --switch repoints future launches (NEVER the fenced v1 swap) and, on success,
    /// offers to restart idle sessions onto the new account (the pointer drives "active").
    func switchHere(_ account: UsageAccount) {
        guard !account.isUnresolved, !account.active, !account.needsRelogin,
              !isSwitchInFlight else { return }
        switch SwitchRoute.route(for: currentEpoch) {
        case .swap:
            // Snapshot the active email from the SAME payload the UI rendered from, so a click
            // queued against a stale view can't overwrite a swap that already landed. (rollback-day)
            enqueueAction(
                .switchAccount, key: account.email, executable: Paths.bash,
                arguments: SwapInvocation.arguments(
                    swapScript: Paths.swap, target: account.email,
                    activeEmail: snapshot?.activeClaudeEmail
                ),
                successMessage: "Swapped"
            )
        case .repoint:
            // v2 only: the pointer drives "active", so the card flips immediately (flipsActive).
            enqueueAction(
                .switchAccount, key: account.email, executable: Paths.bash,
                arguments: [Paths.claudeAcct, "--switch", account.email],
                successMessage: "Switched",
                environment: scriptEnvironment, offersRestart: true, flipsActive: true
            )
        }
    }

    /// The epoch the payload reports; drives Switch routing, restart offers, and health chrome.
    var currentEpoch: EpochState { snapshot?.epochState ?? .v1 }

    /// The card action-button label for the CURRENT epoch: "Swap here" under v1/shadow (the v1
    /// seamless swap), "Switch here" under v2 (repoint of future launches). (rollback-day)
    var switchActionTitle: String { SwitchRoute.route(for: currentEpoch).actionTitle }

    var health: Health? { snapshot?.health }

    func rebank(_ account: UsageAccount) {
        enqueueAction(.rebank, key: account.email, executable: Paths.bash,
                      arguments: [Paths.bank], successMessage: "Re-banked")
    }

    func toggleAutoPing(_ account: UsageAccount) {
        guard account.isClaude, !account.isUnresolved else { return }
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

    /// True while ANY card's swap/switch is queued or running — every Swap/Switch button is
    /// disabled for the duration (SwitchGate).
    var isSwitchInFlight: Bool {
        SwitchGate.isBlocked(busyKinds: busyActions.values.map(\.rawValue))
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

    /// A parked card whose banked credential was superseded by a fresh login (the
    /// unlinked card's metadata names THIS account): explain the blankness instead
    /// of rendering an empty card. Nil for every other account.
    func supersededCaption(for account: UsageAccount) -> String? {
        guard account.isClaude, !account.isUnresolved, !account.active,
              let accounts = snapshot?.accounts,
              accounts.contains(where: {
                  $0.isUnresolved && ($0.metadataEmail ?? "") == account.email
              })
        else { return nil }
        return "A newer login for this account is unlinked above — Link account merges them."
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
        RuntimeMarker.remove(path: Paths.runtimeMarker)
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Assisted restart (§0) — shadow|v2 Switch follow-up

    /// After a repoint Switch succeeds, ask the session registry which sessions are IDLE and can
    /// be moved onto the new account. Read-only (`sessions.py list`); a repoint with no idle
    /// sessions shows no affordance. Runs inline (not through the mutating FIFO) — it's a query.
    private func presentRestartOffer(targetEmail: String) async {
        restartOutcomes = [:]
        let targetHome = await resolveReadyHome(email: targetEmail)
        do {
            let result = try await ScriptRunner.run(
                executable: Paths.python,
                arguments: [Paths.sessions, "list", Paths.accountsDir],
                policy: .utility,
                environment: scriptEnvironment
            )
            // (review #2) exclude sessions already pinned to the target home — moving them is a no-op.
            let ids = IdleSessions.movableSessionIDs(fromListJSON: result.stdout, targetHome: targetHome)
            restartOffer = ids.isEmpty ? nil : RestartOffer(targetEmail: targetEmail, sessionIDs: ids)
        } catch {
            restartOffer = nil   // no registry / query failed: silently offer nothing (safe)
            Self.debugLog("restart-offer session list failed: \(error)")
        }
    }

    /// The target's READY home path (for the review #2 pinned-to-target filter), or nil if it
    /// can't be resolved — in which case we fall back to the IDLE-only filter.
    private func resolveReadyHome(email: String) async -> String? {
        do {
            let r = try await ScriptRunner.run(
                executable: Paths.python,
                arguments: [Paths.registry, "ready-home", Paths.accountsDir, email],
                policy: .utility,
                environment: scriptEnvironment
            )
            let path = String(data: r.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty ?? true) ? nil : path
        } catch {
            return nil
        }
    }

    /// Move the offered IDLE sessions onto the target account: one assisted-restart transaction
    /// per session, routed through the same global FIFO (each is a long, mutating action). Each
    /// session's per-outcome result is surfaced as it completes; the offer is cleared immediately.
    func moveIdleSessions() {
        guard let offer = restartOffer else { return }
        restartOffer = nil
        for sid in offer.sessionIDs {
            let key = "restart:\(sid)"
            restartOutcomes[sid] = "moving…"
            enqueueAction(
                .restartSession, key: key, executable: Paths.python,
                arguments: [Paths.restart, Paths.accountsDir, "restart", sid, offer.targetEmail],
                successMessage: nil, environment: scriptEnvironment
            )
        }
    }

    func dismissRestartOffer() {
        restartOffer = nil
    }

    func clearRestartOutcomes() {
        restartOutcomes = [:]
    }

    private func scheduleClearRestartOutcomes() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            guard let self, !self.restartOutcomes.values.contains("moving…") else { return }
            self.restartOutcomes = [:]
        }
    }

    // MARK: - Add account (owner-interactive seeding)

    /// A subtle footer "+" launches the owner-interactive seeding flow. The app only OPENS a
    /// Terminal running claude-acct --add <email>; the /login + browser steps are the owner's.
    /// The app never touches credentials or the keychain — it just launches the flow.
    func addAccount(email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("@") else { return }
        let inner = "\(Paths.bash) \(shellQuote(Paths.claudeAcct)) --add \(shellQuote(trimmed))"
        let script = "tell application \"Terminal\" to do script \(appleScriptString(inner))"
        Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }

    // MARK: - Seed-audit review acknowledgement

    func acknowledgeSeedAudit(ts: Int) {
        seedAuditAckTs = max(seedAuditAckTs, ts)
        UserDefaults.standard.set(seedAuditAckTs, forKey: Self.seedAuditAckKey)
    }

    /// The seed-audit review line, or nil when nothing newer than the ack was shared.
    var seedAuditReview: (ts: Int, count: Int)? {
        HealthPresentation.seedAuditReview(health, epoch: currentEpoch, ackedTs: seedAuditAckTs)
    }

    var archiverWarning: String? { HealthPresentation.archiverWarning(health, epoch: currentEpoch) }
    var forkDriftLine: String? { HealthPresentation.forkDriftLine(health, epoch: currentEpoch) }

    /// True when ANY health anomaly is worth showing — otherwise the popover renders no health
    /// chrome at all (zero noise in the healthy state).
    var hasHealthAnomaly: Bool {
        archiverWarning != nil || forkDriftLine != nil || seedAuditReview != nil
    }

    /// True while a restart offer is pending or per-session restart outcomes are still showing.
    var hasRestartUI: Bool {
        restartOffer != nil || !restartOutcomes.isEmpty
    }

    /// The footer add-account "+" launches claude-acct --add (the v2 home-seeding flow), which
    /// only exists under shadow|v2. Under v1 accounts are added the v1 way (/login + bank), so
    /// the affordance is hidden — never a button that launches a flow the epoch can't complete.
    var supportsSeeding: Bool { currentEpoch == .shadow || currentEpoch == .v2 }

    /// Ping cooldown remaining for a card (v2 home cooldown_until, else v1 last_ping).
    func pingRemaining(for account: UsageAccount) -> TimeInterval {
        PingCooldown.remaining(for: account, v1LastPing: lastPingByEmail[account.email], now: currentDate)
    }

    func isPingCoolingDown(for account: UsageAccount) -> Bool {
        pingRemaining(for: account) > 0
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
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
        successMessage: String?,
        environment: [String: String] = [:],
        offersRestart: Bool = false,
        flipsActive: Bool = true
    ) {
        guard busyActions[key] == nil else { return }
        busyActions[key] = kind
        cardErrors[key] = nil
        cardStatuses[key] = nil

        let action = PendingAction(kind: kind, key: key, executable: executable,
                                   arguments: arguments, successMessage: successMessage,
                                   environment: environment, offersRestart: offersRestart,
                                   flipsActive: flipsActive)
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
                policy: .mutatingAction,
                environment: action.environment
            )
        } catch ScriptFailure.timedOut {
            timedOut = true
        } catch let failure as ScriptFailure {
            failureMessage = SwapFailureText.message(
                isSwitch: isSwitch,
                exitCode: failure.exitCode,
                stderrLine: failure.firstStderrLine ?? failure.errorDescription ?? "Script failed"
            )
        } catch {
            failureMessage = "Script failed"
        }
        scriptMilliseconds = SwitchTimingDiagnostics.milliseconds(
            startUptime: scriptStartedAt,
            endUptime: DispatchTime.now().uptimeNanoseconds
        )

        busyActions[action.key] = nil

        // Assisted restart (key "restart:<sid>") reports its own per-session outcome, not a card
        // status/error, and never runs the switch confirm machinery.
        if action.kind == .restartSession {
            let sid = restartSID(from: action.key)
            if timedOut {
                restartOutcomes[sid] = "still moving…"
            } else if let failureMessage {
                // (review #3) a stranded lease (rc 75, "not registered / lease held") reads as a
                // recovery hint, never a bare "Script failed".
                restartOutcomes[sid] = RestartOutcomeText.outcome(forFailureLine: firstLine(of: failureMessage))
            } else {
                restartOutcomes[sid] = "moved"
            }
            // Once no session is still in flight, fade the outcomes after a beat.
            if !restartOutcomes.values.contains("moving…") {
                scheduleClearRestartOutcomes()
            }
            refresh()
            return
        }

        if timedOut {
            let status = "still finishing — refresh shortly"
            cardStatuses[action.key] = status
            clearCardStatusLater(key: action.key, matching: status, after: 12)
            scheduleRefresh(after: 5)
        } else if let failureMessage {
            cardErrors[action.key] = firstLine(of: failureMessage)
            clearCardErrorLater(key: action.key, matching: firstLine(of: failureMessage))
            refresh()
        } else {
            if action.kind == .codexPing {
                recordCodexPing()
            }
            // Optimistic ACTIVE flip only when this switch actually changes the displayed active
            // account (v1 swap / v2 repoint). A shadow repoint sets future launches only.
            if action.kind == .switchAccount, action.flipsActive {
                snapshot = snapshot?.optimisticallyActivatingClaudeAccount(email: action.key)
                updatingAccountID = "claude:\(action.key)"
            }
            if let status = action.successMessage {
                cardStatuses[action.key] = status
                clearCardStatusLater(key: action.key, matching: status)
            }
            if action.kind == .switchAccount {
                if action.flipsActive {
                    let confirmStartedAt = DispatchTime.now().uptimeNanoseconds
                    await confirmSwitchedAccount(email: action.key)
                    confirmMilliseconds = SwitchTimingDiagnostics.milliseconds(
                        startUptime: confirmStartedAt,
                        endUptime: DispatchTime.now().uptimeNanoseconds
                    )
                } else {
                    refresh()   // shadow repoint: no active flip to confirm
                }
                if action.offersRestart {
                    await presentRestartOffer(targetEmail: action.key)
                }
            } else {
                refresh()
            }
        }
    }

    private func firstLine(of message: String) -> String {
        message.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? "Script failed"
    }

    private func restartSID(from key: String) -> String {
        String(key.dropFirst("restart:".count))
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

    /// Same resolution as every other accounts-dir read: BANK_DIR when set, else ~/.claude/accounts.
    private static var accountsDirectory: URL {
        URL(fileURLWithPath: ScriptsLocation.resolveAccountsDir(), isDirectory: true)
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

// MARK: - v2 wiring: scripts-dir resolution, runtime marker, restart offer

/// Resolves where the account-bank scripts and accounts dir live (r10 #1), replacing the
/// hard-coded dev path. The ordering is a pure function (`choose`) so the resolution table is a
/// contract test; `resolve()` binds it to the real filesystem + environment + app bundle.
enum ScriptsLocation {
    /// First candidate `exists` accepts, in order: an explicit non-empty env dir, then each
    /// default. nil when none exist (caller supplies a last-resort default).
    static func choose(env: String?, candidates: [String], exists: (String) -> Bool) -> String? {
        if let env, !env.isEmpty, exists(env) { return env }
        return candidates.first(where: exists)
    }

    /// (v101-confirm) Precedence: the explicit `QUOTABAR_SCRIPTS_DIR` override, then the copy
    /// BUNDLED inside QuotaBar.app, then the XDG install (`$XDG_DATA_HOME/quotabar/account-bank`,
    /// the only path install.sh writes), and the legacy `~/.claude/scripts/account-bank` LAST.
    ///
    /// The bundled copy moved AHEAD of the install because the app and its runtime ship as one
    /// versioned artifact and nothing else reconciles them. r15 #7 had already demoted the
    /// legacy path for exactly this reason, but left the XDG install first — so a user who ran
    /// install.sh under v1.0.0 and then upgraded the Cask kept executing the v1.0.0
    /// credential-mutating `usage.py`/`swap-account.sh`/`bank-account.sh` forever: the new app
    /// binary shipped the fixes, resolved to the stale directory, and never ran them. There is
    /// no version manifest to compare against, so "the runtime that shipped with this binary"
    /// is the only defensible default. A deliberately-managed install stays reachable through
    /// the env override, which is why the override still outranks everything.
    /// The ordering is a pure function so the table is a contract test. `bundled` is nil when
    /// the app has no bundled copy; the XDG install remains the fallback when nothing exists.
    static func pickScriptsDir(env: String?, installed: String, bundled: String?,
                               legacy: String, exists: (String) -> Bool) -> String {
        if let env, !env.isEmpty, exists(env) { return env }
        if let bundled, exists(bundled) { return bundled }
        if exists(installed) { return installed }
        if exists(legacy) { return legacy }   // last resort only
        return installed
    }

    static func resolve() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let hasScripts: (String) -> Bool = { fm.fileExists(atPath: "\($0)/usage.py") }
        let xdgBase = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap {
            $0.isEmpty ? nil : $0
        } ?? "\(home)/.local/share"
        return pickScriptsDir(
            env: ProcessInfo.processInfo.environment["QUOTABAR_SCRIPTS_DIR"],
            installed: "\(xdgBase)/quotabar/account-bank",
            bundled: Bundle.main.resourceURL?.appendingPathComponent("account-bank").path,
            legacy: "\(home)/.claude/scripts/account-bank",
            exists: hasScripts
        )
    }

    /// (r15 #4) THE bank-directory rule, identical to lib.sh:22 and bank_common.resolve_bank_dir:
    /// BANK_DIR -> ACCOUNT_BANK_DIR -> ~/.claude/accounts. The app previously stopped after
    /// BANK_DIR, so a user who set only the DOCUMENTED `ACCOUNT_BANK_DIR` had the shell
    /// mutators acting on their custom bank while the app, poller and reconciler read the
    /// default one. `pick` is pure so the precedence is a contract test.
    static func pickBankDir(bankDir: String?, accountBankDir: String?, home: String) -> String {
        if let b = bankDir, !b.isEmpty { return b }
        if let a = accountBankDir, !a.isEmpty { return a }
        return "\(home)/.claude/accounts"
    }

    static func resolveAccountsDir() -> String {
        let env = ProcessInfo.processInfo.environment
        return pickBankDir(bankDir: env["BANK_DIR"], accountBankDir: env["ACCOUNT_BANK_DIR"],
                           home: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}

/// Writes accounts/quotabar.runtime.json {pid, epoch_aware:true} so attest-cutover.sh can prove
/// the RUNNING app (this exact pid) is the epoch-aware build. Atomic + 0600 on launch, refreshed
/// on the poll cadence, removed on a clean quit. This is the ONE file the app writes under
/// accounts/ — SPEC "Allowed I/O" was widened for exactly this marker (see the Makefile audit).
enum RuntimeMarker {
    /// Pure serialization so the marker's exact bytes/shape are a contract test.
    static func payload(pid: Int32) -> String {
        "{\"pid\": \(pid), \"epoch_aware\": true}\n"
    }

    static func write(path: String, pid: Int32) {
        guard let data = payload(pid: pid).data(using: .utf8) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    static func remove(path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// An offer, surfaced after a shadow|v2 Switch repoints, to move currently-IDLE registered
/// sessions onto the new account via the assisted-restart transaction. Empty session list =>
/// no offer shown (a repoint with no idle sessions is silent).
struct RestartOffer: Equatable, Sendable {
    let targetEmail: String
    let sessionIDs: [String]

    var isEmpty: Bool { sessionIDs.isEmpty }
    var count: Int { sessionIDs.count }
}

/// Parses `sessions.py list <acc>` JSON ({sid: record}) into the IDLE session-ids that are
/// genuinely MOVABLE onto the switch target: IDLE, and NOT already pinned to the target's home
/// (review #2 — restarting a session already on the target is a pointless no-op). Pure so the
/// filter is a contract test.
enum IdleSessions {
    private struct Record: Decodable {
        let state: String?
        let home: String?
    }

    /// `targetHome` nil/empty => filter by IDLE only (home comparison skipped).
    static func movableSessionIDs(fromListJSON data: Data, targetHome: String?) -> [String] {
        guard let map = try? JSONDecoder().decode([String: Record].self, from: data) else { return [] }
        let target = (targetHome?.isEmpty == false) ? canonical(targetHome!) : nil
        return map.compactMap { sid, rec -> String? in
            guard rec.state?.uppercased() == "IDLE" else { return nil }
            if let target, let home = rec.home, !home.isEmpty, canonical(home) == target {
                return nil   // already pinned to the target home — nothing to move
            }
            return sid
        }.sorted()
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
