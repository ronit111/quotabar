import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

@main
struct QuotaBarTests {
    static func main() async throws {
        try testDecodingOptionalFields()
        try testLiveFixtureShape()
        try testMicrosecondTimestamp()
        try testCachedEntryDetection()
        try testSeverityBoundaries()
        try testCooldownBoundaries()
        try testResetFormatting()
        try testCachedAgeFormatting()
        try testStableAccountOrder()
        try testFreshnessDecisions()
        try testFreshnessCaptionMatrix()
        try testPopoverFreshnessDecision()
        try testPlanCapsuleFallback()
        try testUsagePollEnvironment()
        try testStarredRefreshDebounce()
        try testPendingRefreshMerge()
        try testSwitchTimingDiagnostics()
        try testActiveAccountDriftDebounce()
        try testPerAccountConfirmationReconciliation()
        try testExecutionPolicies()
        try testActionSchedulerOrder()
        try testUserActionPriorityOrdering()
        try testRemoveAccountPolicy()
        try testInlineRemovalConfirmation()
        try testRemoveActionQueueRouting()
        try testOptimisticSwitchFlip()
        try testPopoverLayoutBranches()
        try testCodexPingLogic()
        try await testLargeStderrDrain()
        try await testScriptRunnerEnvironmentPropagation()
        try await testNonzeroStderr()
        try await testTimeout()
        try await testExitTimeoutRace()
        try await testCancellation()
        try await testStubbornProcessTreeTimeout()
        print("QuotaBar tests passed")
    }

    private static func testDecodingOptionalFields() throws {
        let json = #"""
        {
          "generated_at": "2026-07-19T03:25:40Z",
          "stale": false,
          "accounts": [
            {
              "provider": "claude",
              "email": "claude@example.com",
              "active": true,
              "five_hour": {"utilization": 60, "resets_at": "2026-07-19T07:49:59.764202+00:00"},
              "seven_day": {"utilization": 2, "resets_at": "2026-07-24T04:59:59+00:00"},
              "worst_limit": {"kind": "session", "percent": 60, "resets_at": "2026-07-19T07:49:59Z"}
            },
            {
              "provider": "codex",
              "email": "codex@example.com",
              "active": false,
              "plan": "plus",
              "five_hour": null,
              "seven_day": {"utilization": 30, "resets_at": "2026-07-25T08:18:44Z"},
              "worst_limit": {"kind": "weekly", "percent": 30, "resets_at": "2026-07-25T08:18:44Z"}
            }
          ]
        }
        """#
        let snapshot = try UsageSnapshot.decode(from: Data(json.utf8))
        try expect(snapshot.accounts.count == 2, "decoder lost accounts")
        try expect(snapshot.accounts[0].plan == nil, "missing plan must remain nil")
        try expect(snapshot.accounts[1].fiveHour == nil, "null five_hour must remain nil")
    }

    // Captured verbatim from `usage.py` on 2026-07-19 (percentages/timestamps only, no credentials).
    private static let liveFixture = #"""
    {
      "generated_at": "2026-07-19T07:20:30Z",
      "active_email": "primary@example.com",
      "accounts": [
        {
          "provider": "claude",
          "email": "secondary@example.com",
          "active": false,
          "five_hour": {"utilization": 100.0, "resets_at": "2026-07-19T07:50:00.159118+00:00"},
          "seven_day": {"utilization": 12.0, "resets_at": "2026-07-24T05:00:00.159136+00:00"},
          "worst_limit": {"kind": "session", "percent": 100.0, "resets_at": "2026-07-19T07:50:00.159118+00:00"},
          "status": "ok",
          "fetched_at": 1784444886.544259,
          "plan": "pro"
        },
        {
          "provider": "claude",
          "email": "primary@example.com",
          "active": true,
          "five_hour": {"utilization": 33.0, "resets_at": "2026-07-19T11:40:00.298153+00:00"},
          "seven_day": {"utilization": 21.0, "resets_at": "2026-07-25T08:00:00.298172+00:00"},
          "worst_limit": {"kind": "session", "percent": 33.0, "resets_at": "2026-07-19T11:40:00.298153+00:00"},
          "status": "ok",
          "fetched_at": 1784445628.831713,
          "plan": "max"
        },
        {
          "provider": "codex",
          "email": "secondary@example.com",
          "active": false,
          "five_hour": null,
          "seven_day": {"utilization": 34.0, "resets_at": "2026-07-25T08:18:44+00:00"},
          "worst_limit": {"kind": "weekly", "percent": 34.0, "resets_at": "2026-07-25T08:18:44+00:00"},
          "status": "ok",
          "fetched_at": 1784445629.4484081,
          "plan": "plus"
        }
      ],
      "stale": false,
      "fail_streak": 0,
      "backoff_until": 0,
      "autoping_fired": []
    }
    """#

    private static func testLiveFixtureShape() throws {
        let snapshot = try UsageSnapshot.decode(from: Data(liveFixture.utf8))
        try expect(snapshot.accounts.count == 3, "fixture must decode 3 accounts")
        let claude = snapshot.accounts.filter(\.isClaude)
        try expect(claude.count == 2, "fixture must have 2 claude accounts")
        try expect(claude.filter(\.active).count == 1, "exactly one claude account must be active")
        try expect(snapshot.accounts.contains(where: \.isCodex), "fixture must include a codex account")
        try expect(snapshot.stale == false, "fixture must decode stale=false")
    }

    private static func testMicrosecondTimestamp() throws {
        let json = #"""
        {
          "generated_at": "2026-07-19T07:50:00.317164+00:00",
          "accounts": [
            {
              "provider": "claude",
              "email": "a@example.com",
              "active": true,
              "five_hour": {"utilization": 100, "resets_at": "2026-07-19T07:50:00.317164+00:00"}
            }
          ]
        }
        """#
        let snapshot = try UsageSnapshot.decode(from: Data(json.utf8))
        guard let reset = snapshot.accounts[0].fiveHour?.resetsAt else {
            throw TestFailure.failed("6-digit microsecond resets_at failed to decode")
        }
        // Python emits 6 fractional digits; ISO8601DateFormatter accepts exactly 3, so
        // .317164 must be truncated to .317 rather than dropped or rejected.
        let reference = ISO8601DateFormatter()
        reference.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expected = reference.date(from: "2026-07-19T07:50:00.317Z") else {
            throw TestFailure.failed("reference date construction failed")
        }
        try expect(abs(reset.timeIntervalSince(expected)) < 0.0005, "microsecond resets_at mis-parsed")
        try expect(abs(snapshot.generatedAt.timeIntervalSince(expected)) < 0.0005, "microsecond generated_at mis-parsed")
    }

    private static func testCachedEntryDetection() throws {
        let json = #"""
        {
          "generated_at": "2026-07-19T08:10:00Z",
          "stale": false,
          "accounts": [
            {
              "provider": "claude",
              "email": "cached@example.com",
              "active": true,
              "stale_entry": true,
              "fetched_at": 1784448000
            }
          ]
        }
        """#
        let snapshot = try UsageSnapshot.decode(from: Data(json.utf8))
        try expect(snapshot.representsCachedData, "a per-account stale entry must mark the snapshot cached")
        try expect(
            snapshot.accounts[0].fetchedAtDate == Date(timeIntervalSince1970: 1_784_448_000),
            "cached age must use the entry's fetched_at timestamp"
        )
    }

    private static func testSeverityBoundaries() throws {
        try expect(Severity.forPercent(59.999) == .healthy, "59.999 must be green")
        try expect(Severity.forPercent(60) == .warning, "60 must be orange")
        try expect(Severity.forPercent(85) == .warning, "85 must be orange")
        try expect(Severity.forPercent(85.001) == .critical, ">85 must be red")
    }

    private static func testCooldownBoundaries() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        try expect(TimeFormatting.cooldownRemaining(lastPing: now.addingTimeInterval(-1_799), now: now) == 1, "1799 seconds must still cool down")
        try expect(TimeFormatting.cooldownRemaining(lastPing: now.addingTimeInterval(-1_800), now: now) == 0, "1800 seconds must be eligible")
        try expect(TimeFormatting.cooldownRemaining(lastPing: now.addingTimeInterval(-1_801), now: now) == 0, "1801 seconds must be eligible")
    }

    private static func testResetFormatting() throws {
        let zone = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = Date(timeIntervalSince1970: 0)
        let reset = now.addingTimeInterval(3 * 3_600 + 8 * 60)
        let caption = TimeFormatting.resetCaption(
            resetAt: reset,
            now: now,
            calendar: calendar,
            timeZone: zone,
            locale: Locale(identifier: "en_US_POSIX")
        )
        try expect(caption == "resets 03:08 (in 3h 08m)", "unexpected reset caption: \(caption)")
    }

    private static func testLargeStderrDrain() async throws {
        let result = try await ScriptRunner.run(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import sys; sys.stderr.write('x' * 1048576); print('ok')"],
            timeoutOverride: 3
        )
        try expect(String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok", "large stderr blocked stdout")
        try expect(result.stderr.count == 512 * 1_024, "stderr buffer was not bounded")
    }

    private static func testNonzeroStderr() async throws {
        do {
            _ = try await ScriptRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'first line\\nsecond line\\n' >&2; exit 7"],
                timeoutOverride: 2
            )
            throw TestFailure.failed("nonzero process unexpectedly succeeded")
        } catch let failure as ScriptFailure {
            try expect(failure.firstStderrLine == "first line", "stderr first line was not preserved")
        }
    }

    private static func testTimeout() async throws {
        do {
            _ = try await ScriptRunner.run(
                executable: "/bin/sleep",
                arguments: ["2"],
                timeoutOverride: 0.15
            )
            throw TestFailure.failed("timed process unexpectedly succeeded")
        } catch ScriptFailure.timedOut {
            return
        }
    }

    private static func testExitTimeoutRace() async throws {
        for _ in 0..<12 {
            _ = try await ScriptRunner.run(
                executable: "/usr/bin/true",
                arguments: [],
                timeoutOverride: 0.05
            )
        }
    }

    // #12 — global FIFO: exactly-one-at-a-time ordering and per-card "queued" marking.
    private static func testActionSchedulerOrder() throws {
        var scheduler = ActionScheduler<String>()
        scheduler.enqueue(key: "a", payload: "a", priority: .userInitiated)
        try expect(!scheduler.isQueued("a"), "first action must not be queued")
        try expect(scheduler.beginIfIdle(), "idle scheduler must start")
        try expect(!scheduler.beginIfIdle(), "running scheduler must not restart")

        // While "a" runs, later requests wait and are marked queued.
        scheduler.enqueue(key: "b", payload: "b", priority: .userInitiated)
        scheduler.enqueue(key: "c", payload: "c", priority: .userInitiated)
        try expect(scheduler.isQueued("b") && scheduler.isQueued("c"), "waiting cards must show queued")

        let first = scheduler.dequeue()
        try expect(first?.key == "a", "FIFO must run 'a' first")
        let second = scheduler.dequeue()
        try expect(second?.key == "b", "FIFO must run 'b' second")
        try expect(!scheduler.isQueued("b"), "running card must clear its queued mark")
        try expect(scheduler.isQueued("c"), "'c' stays queued until dequeued")
        let third = scheduler.dequeue()
        try expect(third?.key == "c", "FIFO must run 'c' third")

        try expect(scheduler.isEmpty && scheduler.running, "drained but still running until next poll")
        _ = scheduler.dequeue()
        try expect(!scheduler.running, "scheduler stops once the queue empties")
    }

    private static func testUserActionPriorityOrdering() throws {
        enum Work: Equatable {
            case poll
            case action(String)
        }

        var scheduler = ActionScheduler<Work>()
        scheduler.enqueue(key: "in-flight-poll", payload: .poll, priority: .background)
        try expect(scheduler.beginIfIdle(), "usage poll must start the shared queue")
        try expect(
            scheduler.dequeue()?.key == "in-flight-poll",
            "the work already dequeued for execution must start first"
        )

        scheduler.enqueue(key: "queued-poll", payload: .poll, priority: .background)
        scheduler.enqueue(
            key: "first@example.com",
            payload: .action("first-switch"),
            priority: .userInitiated
        )
        scheduler.enqueue(
            key: "second@example.com",
            payload: .action("second-switch"),
            priority: .userInitiated
        )

        try expect(
            scheduler.dequeue()?.payload == .action("first-switch"),
            "the first user action must jump ahead of a queued poll"
        )
        try expect(
            scheduler.dequeue()?.payload == .action("second-switch"),
            "user actions must retain FIFO order while bypassing queued polls"
        )
        try expect(
            scheduler.dequeue()?.key == "queued-poll",
            "the queued poll must run after the user actions"
        )
        _ = scheduler.dequeue()
    }

    // Remove affordance visibility guard: parked Claude only. The active account (owns the live
    // keychain) and Codex (token owned by the Codex CLI) must never expose Remove.
    private static func testRemoveAccountPolicy() throws {
        let parked = makeAccount(email: "parked@example.com", active: false, fetchedAt: 1_000)
        let active = makeAccount(email: "active@example.com", active: true, fetchedAt: 1_000)
        let codexParked = makeAccount(
            provider: "codex", email: "codex@example.com", active: false, fetchedAt: 1_000
        )
        let codexActive = makeAccount(
            provider: "codex", email: "codex@example.com", active: true, fetchedAt: 1_000
        )
        let parkedRelogin = UsageAccount(
            provider: "claude", email: "dead@example.com", active: false, plan: nil,
            status: "needs-relogin", error: nil, fiveHour: nil, sevenDay: nil,
            worstLimit: nil, modelCap: nil, staleEntry: nil, fetchedAt: nil
        )

        try expect(RemoveAccountPolicy.canRemove(parked), "a parked Claude account must show Remove")
        try expect(!RemoveAccountPolicy.canRemove(active), "the active account must NEVER show Remove")
        try expect(!RemoveAccountPolicy.canRemove(codexParked), "Codex must NEVER show Remove")
        try expect(!RemoveAccountPolicy.canRemove(codexActive), "active Codex must NEVER show Remove")
        try expect(
            RemoveAccountPolicy.canRemove(parkedRelogin),
            "a parked needs-relogin Claude account is still removable"
        )

        // Confirmation wiring copy must remain exact (drives the inline remove strip).
        try expect(
            RemoveAccountPolicy.confirmationTitle(email: "z@example.com") == "Remove z@example.com?",
            "confirmation title must name the account"
        )
        try expect(
            RemoveAccountPolicy.confirmationMessage
                == "Its usage will stop being tracked. You can re-add it by logging in again.",
            "confirmation message copy must remain exact"
        )
        try expect(RemoveAccountPolicy.confirmButtonTitle == "Remove", "confirm button must read 'Remove'")

        // Inline strip prompt uses the short (local-part) form to fit the 320-wide popover row.
        try expect(
            RemoveAccountPolicy.shortEmail("first.user@example.com") == "first.user",
            "shortEmail must drop the domain"
        )
        try expect(
            RemoveAccountPolicy.shortEmail("noatsign") == "noatsign",
            "shortEmail must pass through an address with no @"
        )
        try expect(
            RemoveAccountPolicy.inlinePrompt(email: "first.user@example.com") == "Remove first.user?",
            "inline prompt must read 'Remove <local>?'"
        )
    }

    // The inline confirm strip's state machine (replaces the sticky modal `.confirmationDialog`).
    // Proves, without a view: arm -> cancel reverts; arm -> remove disarms (routing to the
    // scheduler is `confirmRemoval`'s job, tested via the FIFO in testRemoveActionQueueRouting);
    // a popover close/open reset clears a half-armed card; and only one card is ever armed.
    private static func testInlineRemovalConfirmation() throws {
        var confirm = InlineRemovalConfirmation()
        try expect(!confirm.isArmed, "a fresh confirmation must be disarmed")
        try expect(confirm.armedEmail == nil, "nothing is armed initially")

        // arm -> cancel reverts.
        confirm.toggle(email: "a@example.com")
        try expect(confirm.isArmed(email: "a@example.com"), "tapping the × arms that card")
        try expect(confirm.isArmed, "the machine reports armed")
        confirm.disarm()
        try expect(!confirm.isArmed, "Cancel disarms the card")
        try expect(!confirm.isArmed(email: "a@example.com"), "the previously-armed card is no longer armed")

        // Re-tapping the same card's × toggles it back off (arm then toggle same email).
        confirm.toggle(email: "a@example.com")
        confirm.toggle(email: "a@example.com")
        try expect(!confirm.isArmed, "a second × tap on the same card disarms it")

        // Only one card armed at a time: arming a second card moves the strip.
        confirm.toggle(email: "a@example.com")
        confirm.toggle(email: "b@example.com")
        try expect(confirm.isArmed(email: "b@example.com"), "arming a second card moves the strip to it")
        try expect(!confirm.isArmed(email: "a@example.com"), "the first card must no longer be armed")
        try expect(confirm.armedEmail == "b@example.com", "exactly one card (b) is armed")

        // Popover close/open reset: a half-armed card must never survive to re-render pre-armed.
        confirm.reset()
        try expect(!confirm.isArmed, "reset (popover open/close) clears any armed card")
        try expect(confirm.armedEmail == nil, "reset leaves no armed email")

        // arm -> remove: confirmRemoval disarms first; simulate that ordering here.
        confirm.toggle(email: "c@example.com")
        confirm.disarm()
        try expect(!confirm.isArmed, "confirming Remove disarms the strip immediately")
    }

    // Remove routes through the SAME global FIFO as ping/switch/toggle: enqueued user-initiated,
    // it jumps a queued background poll but keeps FIFO order with other user actions, and its
    // per-card queued mark clears when it is dequeued to run.
    private static func testRemoveActionQueueRouting() throws {
        enum Work: Equatable {
            case poll
            case action(String)
        }

        var scheduler = ActionScheduler<Work>()
        scheduler.enqueue(key: "in-flight-poll", payload: .poll, priority: .background)
        try expect(scheduler.beginIfIdle(), "usage poll must start the shared queue")
        try expect(scheduler.dequeue()?.key == "in-flight-poll", "in-flight poll runs first")

        scheduler.enqueue(key: "queued-poll", payload: .poll, priority: .background)
        scheduler.enqueue(
            key: "switch@example.com", payload: .action("switch"), priority: .userInitiated
        )
        scheduler.enqueue(
            key: "remove@example.com", payload: .action("remove"), priority: .userInitiated
        )

        try expect(
            scheduler.isQueued("remove@example.com"),
            "a remove enqueued while work runs must mark its card queued"
        )
        try expect(
            scheduler.dequeue()?.payload == .action("switch"),
            "user actions must jump the queued poll in FIFO order"
        )
        let removed = scheduler.dequeue()
        try expect(removed?.payload == .action("remove"), "remove must follow the earlier user action, still ahead of the poll")
        try expect(
            !scheduler.isQueued("remove@example.com"),
            "dequeuing remove must clear its queued mark"
        )
        try expect(scheduler.dequeue()?.key == "queued-poll", "the background poll runs last")
        _ = scheduler.dequeue()
    }

    private static func testOptimisticSwitchFlip() throws {
        let original = try UsageSnapshot.decode(from: Data(liveFixture.utf8))
        let targetEmail = "secondary@example.com"
        let switched = original.optimisticallyActivatingClaudeAccount(email: targetEmail)
        let claude = switched.accounts.filter(\.isClaude)

        try expect(claude.filter(\.active).count == 1, "optimistic switch must leave one active Claude account")
        try expect(
            claude.first(where: { $0.email == targetEmail })?.active == true,
            "optimistic switch must activate the successful target"
        )
        try expect(
            claude.first(where: { $0.email == "primary@example.com" })?.active == false,
            "optimistic switch must clear the previous active flag"
        )
        try expect(
            switched.accounts.first(where: { $0.email == targetEmail })?.fiveHour?.utilization == 100,
            "optimistic switch must preserve usage values"
        )
        try expect(
            switched.accounts.first(where: \.isCodex)?.active
                == original.accounts.first(where: \.isCodex)?.active,
            "optimistic switch must not alter Codex state"
        )

        let unknown = original.optimisticallyActivatingClaudeAccount(email: "missing@example.com")
        try expect(
            unknown.accounts.filter { $0.isClaude && $0.active }.first?.email == "primary@example.com",
            "an unknown target must preserve the original active account"
        )
    }

    private static func testStableAccountOrder() throws {
        let first = makeAccount(email: "primary@example.com", active: false, fetchedAt: 1_000)
        let codex = makeAccount(
            provider: "codex", email: "secondary@example.com",
            active: false, fetchedAt: 1_000
        )
        let second = makeAccount(email: "secondary@example.com", active: true, fetchedAt: 1_000)

        let original = AccountOrdering.claudeAccountsInSnapshotOrder([first, codex, second])
        let switched = AccountOrdering.claudeAccountsInSnapshotOrder([
            first.withActive(true), codex, second.withActive(false)
        ])

        let expected = ["primary@example.com", "secondary@example.com"]
        try expect(original.map(\.email) == expected, "Claude cards must follow backend bank order")
        try expect(
            switched.map(\.email) == expected,
            "active flag changes must never reorder Claude cards"
        )
    }

    private static func testFreshnessDecisions() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        func state(
            age: TimeInterval?, staleEntry: Bool? = nil, error: String? = nil,
            updating: Bool = false, forcedStale: Bool = false
        ) -> CardFreshness {
            let fetchedAt = age.map { now.timeIntervalSince1970 - $0 }
            let account = makeAccount(
                email: "freshness@example.com", fetchedAt: fetchedAt,
                staleEntry: staleEntry, error: error
            )
            return AccountFreshness.state(
                for: account, now: now,
                isUpdating: updating, isForcedStale: forcedStale
            )
        }

        try expect(state(age: 60) == .fresh, "60 seconds must remain fresh")
        try expect(state(age: 60.1) == .aging, "more than 60 seconds must be aging")
        try expect(state(age: 119.999) == .aging, "less than 120 seconds must remain aging")
        try expect(state(age: 120) == .stale, "120 seconds must be stale")
        try expect(state(age: nil) == .stale, "missing fetched_at must be stale")
        try expect(state(age: -5) == .fresh, "future fetched_at must clamp to zero")
        try expect(state(age: 1, staleEntry: true) == .stale, "stale_entry must override age")
        try expect(state(age: 1, error: "backend error") == .stale, "entry error must override age")
        try expect(state(age: 1, forcedStale: true) == .stale, "confirmation failure must force stale")
        try expect(
            state(age: 500, staleEntry: true, updating: true) == .updating,
            "updating must override every cached state"
        )

    }

    private static func testFreshnessCaptionMatrix() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        func caption(
            age: TimeInterval?, staleEntry: Bool? = nil, error: String? = nil,
            updating: Bool = false, forcedStale: Bool = false
        ) -> String? {
            let account = makeAccount(
                email: "caption@example.com",
                fetchedAt: age.map { now.timeIntervalSince1970 - $0 },
                staleEntry: staleEntry,
                error: error
            )
            let freshness = AccountFreshness.state(
                for: account,
                now: now,
                isUpdating: updating,
                isForcedStale: forcedStale
            )
            return AccountFreshness.caption(for: account, now: now, freshness: freshness)
        }

        try expect(caption(age: 30) == nil, "fresh healthy data must be silent")
        try expect(caption(age: 90) == nil, "aging healthy data under 120s must be silent")
        try expect(caption(age: 120) == "cached 2m ago", "120s must show an amber cached age")
        try expect(caption(age: 121) == "cached 2m ago", "stale data must show its cached age")
        try expect(caption(age: 10, staleEntry: true) == "cached 10s ago", "stale_entry must show")
        try expect(caption(age: 10, error: "backend error") == "cached 10s ago", "error must show")
        try expect(caption(age: 10, forcedStale: true) == "cached 10s ago", "forced stale must show")
        try expect(caption(age: nil) == "cached —", "unknown timestamps must show cached state")
        try expect(
            caption(age: 500, staleEntry: true, updating: true) == "updating…",
            "updating must replace stale caption text"
        )
    }

    private static func testPopoverFreshnessDecision() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let atBoundary = makeAccount(email: "a@example.com", fetchedAt: 940)
        let overBoundary = makeAccount(email: "b@example.com", fetchedAt: 939)
        let unknown = makeAccount(email: "c@example.com", fetchedAt: nil)
        let young = makeAccount(email: "d@example.com", fetchedAt: 990)

        try expect(
            !AccountFreshness.shouldPollOnOpen(accounts: [atBoundary], now: now),
            "popover must not poll at exactly 60 seconds"
        )
        try expect(
            AccountFreshness.shouldPollOnOpen(accounts: [atBoundary, overBoundary], now: now),
            "popover must poll when any card is older than 60 seconds"
        )
        try expect(
            AccountFreshness.shouldPollOnOpen(accounts: [unknown], now: now),
            "unknown freshness must trigger a popover poll"
        )
        try expect(
            AccountFreshness.shouldPollOnOpen(accounts: [young, overBoundary], now: now),
            "one old card in a mixed snapshot must trigger a popover poll"
        )
        try expect(
            !AccountFreshness.shouldPollOnOpen(accounts: [young, atBoundary], now: now),
            "all known cards at or under 60s must not trigger a popover poll"
        )
    }

    private static func testUsagePollEnvironment() throws {
        let regular = UsagePollEnvironment.values()
        try expect(
            regular == ["ACCOUNT_BANK_PARKED_MAX_AGE": "600"],
            "every poll must cap parked cache age at 600 seconds"
        )

        let forced = UsagePollEnvironment.values(for: .forceFresh("target@example.com"))
        try expect(
            forced["ACCOUNT_BANK_PARKED_MAX_AGE"] == "600",
            "force-fresh poll must retain parked cache cap"
        )
        try expect(
            forced["ACCOUNT_BANK_FORCE_FRESH"] == "target@example.com",
            "force-fresh poll must propagate its exact target"
        )
        try expect(forced["ACCOUNT_BANK_ONLY"] == nil, "force-fresh must not set ONLY")

        let only = UsagePollEnvironment.values(for: .only("target@example.com"))
        try expect(
            only["ACCOUNT_BANK_ONLY"] == "target@example.com",
            "switch confirmation must propagate ACCOUNT_BANK_ONLY"
        )
        try expect(only["ACCOUNT_BANK_FORCE_FRESH"] == nil, "ONLY must replace FORCE_FRESH")
        try expect(only["ACCOUNT_BANK_PARKED_MAX_AGE"] == "600", "ONLY must retain cache cap")

        let starred = UsagePollEnvironment.values(for: .forceFresh("*"))
        try expect(starred["ACCOUNT_BANK_FORCE_FRESH"] == "*", "popover poll must propagate star")
        try expect(starred["ACCOUNT_BANK_ONLY"] == nil, "starred refresh must not set ONLY")
    }

    private static func testStarredRefreshDebounce() throws {
        let start = Date(timeIntervalSince1970: 10_000)
        var debouncer = StarredRefreshDebouncer()
        try expect(debouncer.accept(now: start), "first starred refresh must be accepted")
        try expect(
            !debouncer.accept(now: start.addingTimeInterval(59.999)),
            "starred refresh under 60s must be suppressed"
        )
        try expect(
            debouncer.accept(now: start.addingTimeInterval(60)),
            "starred refresh at exactly 60s must be accepted"
        )
        try expect(
            !debouncer.accept(now: start.addingTimeInterval(60.001)),
            "acceptance must reserve the next 60s window immediately"
        )
    }

    private static func testPendingRefreshMerge() throws {
        try expect(
            PendingRefreshRequest.merged(nil, with: .regular) == .regular,
            "first regular refresh must remain regular"
        )
        try expect(
            PendingRefreshRequest.merged(.regular, with: .starred) == .starred,
            "star must replace a pending regular refresh"
        )
        try expect(
            PendingRefreshRequest.merged(.starred, with: .regular) == .starred,
            "regular refresh must not downgrade a pending star"
        )
        try expect(
            PendingRefreshRequest.merged(.starred, with: .starred) == .starred,
            "duplicate starred requests must coalesce"
        )
        try expect(
            PendingRefreshRequest.starred.pollMode == .forceFresh("*"),
            "preserved starred work must execute with ACCOUNT_BANK_FORCE_FRESH=*"
        )
    }

    private static func testSwitchTimingDiagnostics() throws {
        try expect(
            SwitchTimingDiagnostics.milliseconds(startUptime: 5_000_000, endUptime: 10_999_999) == 5,
            "uptime durations must floor to whole milliseconds"
        )
        try expect(
            SwitchTimingDiagnostics.milliseconds(startUptime: 10, endUptime: 9) == 0,
            "invalid uptime ordering must clamp to zero"
        )
        try expect(
            SwitchTimingDiagnostics.line(scriptMilliseconds: 812, confirmMilliseconds: 947)
                == "switch: script 812ms, confirm 947ms",
            "switch timing log format must remain exact"
        )
        try expect(
            SwitchTimingDiagnostics.line(scriptMilliseconds: 12, confirmMilliseconds: -1)
                == "switch: script 12ms, confirm 0ms",
            "skipped confirmation must log zero milliseconds"
        )
    }

    private static func testPlanCapsuleFallback() throws {
        try expect(
            PlanCapsulePresentation.text(for: "plus") == "PLUS",
            "plan capsule must uppercase the decoded plan"
        )
        try expect(
            PlanCapsulePresentation.text(for: nil) == nil,
            "missing plan must hide the capsule"
        )
        try expect(
            PlanCapsulePresentation.text(for: "") == nil,
            "empty plan must hide the capsule"
        )
    }

    private static func testActiveAccountDriftDebounce() throws {
        func snapshot(activeEmail: String?) -> UsageSnapshot {
            let accounts = ["a@example.com", "b@example.com", "c@example.com"].map {
                makeAccount(email: $0, active: $0 == activeEmail, fetchedAt: nil)
            }
            return UsageSnapshot(
                generatedAt: Date(timeIntervalSince1970: 10_000),
                stale: false,
                staleReason: nil,
                accounts: accounts
            )
        }

        let start = Date(timeIntervalSince1970: 10_000)
        var tracker = ActiveAccountDriftTracker()
        try expect(
            tracker.followUpEmail(afterSuccessfulPoll: snapshot(activeEmail: "a@example.com"), now: start) == nil,
            "the first successful poll must only establish the active-account baseline"
        )
        try expect(
            tracker.followUpEmail(afterSuccessfulPoll: snapshot(activeEmail: "a@example.com"), now: start.addingTimeInterval(10)) == nil,
            "an unchanged active account must not trigger a follow-up"
        )
        try expect(
            tracker.followUpEmail(afterSuccessfulPoll: snapshot(activeEmail: "b@example.com"), now: start.addingTimeInterval(20)) == "b@example.com",
            "an external active-account drift must force-refresh the new account"
        )
        try expect(
            tracker.followUpEmail(afterSuccessfulPoll: snapshot(activeEmail: "a@example.com"), now: start.addingTimeInterval(139)) == nil,
            "a second drift inside two minutes must be debounced"
        )
        try expect(
            tracker.followUpEmail(afterSuccessfulPoll: snapshot(activeEmail: "a@example.com"), now: start.addingTimeInterval(140)) == nil,
            "a suppressed drift must still become the comparison baseline"
        )
        try expect(
            tracker.followUpEmail(afterSuccessfulPoll: snapshot(activeEmail: "c@example.com"), now: start.addingTimeInterval(140)) == "c@example.com",
            "a new drift at the two-minute boundary must be allowed"
        )
        try expect(
            tracker.followUpEmail(afterSuccessfulPoll: snapshot(activeEmail: nil), now: start.addingTimeInterval(300)) == nil,
            "a snapshot without an active account must not produce a force-fresh target"
        )
    }

    private static func testPerAccountConfirmationReconciliation() throws {
        let invalidA = makeAccount(
            email: "a@example.com", fetchedAt: 1_000, staleEntry: true
        )
        let validA = makeAccount(email: "a@example.com", fetchedAt: 1_000)
        let validB = makeAccount(email: "b@example.com", fetchedAt: 1_000)
        let missingTimestamp = makeAccount(email: "missing@example.com", fetchedAt: nil)
        let errored = makeAccount(email: "error@example.com", fetchedAt: 1_000, error: "failed")

        try expect(
            !AccountFreshness.isValidConfirmationEntry(invalidA),
            "stale_entry target must fail freshness confirmation"
        )
        try expect(
            !AccountFreshness.isValidConfirmationEntry(missingTimestamp),
            "missing fetched_at target must fail freshness confirmation"
        )
        try expect(
            !AccountFreshness.isValidConfirmationEntry(errored),
            "errored target must fail freshness confirmation"
        )

        let afterBConfirms = AccountFreshness.reconciledForcedStaleAccountIDs(
            [invalidA.id, validB.id],
            with: [invalidA, validB]
        )
        try expect(
            afterBConfirms == [invalidA.id],
            "B confirmation must not clear A's failed-confirmation marker"
        )

        let afterAConfirms = AccountFreshness.reconciledForcedStaleAccountIDs(
            afterBConfirms,
            with: [validA]
        )
        try expect(afterAConfirms.isEmpty, "A marker must clear only when A validates")
    }

    private static func testExecutionPolicies() throws {
        try expect(ScriptExecutionPolicy.usagePoll.timeout == 15, "usage poll timeout must remain 15s")
        try expect(
            ScriptExecutionPolicy.usagePoll.sendsTreeSIGKILL,
            "read-only poll must retain process-tree SIGKILL escalation"
        )
        try expect(
            ScriptExecutionPolicy.mutatingAction.timeout == 90,
            "mutating actions must receive a 90s timeout"
        )
        try expect(
            ScriptExecutionPolicy.mutatingAction.terminationGrace == 10,
            "mutating actions must receive a 10s TERM grace"
        )
        try expect(
            !ScriptExecutionPolicy.mutatingAction.sendsTreeSIGKILL,
            "mutating actions must never use SIGKILL"
        )
        try expect(
            !ScriptExecutionPolicy.utility.sendsTreeSIGKILL,
            "non-poll utility work must not use SIGKILL"
        )
    }

    private static func testCachedAgeFormatting() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        try expect(
            TimeFormatting.cachedAgo(from: now.addingTimeInterval(-9 * 60), now: now) == "cached 9m ago",
            "cached badge age must be explicit"
        )
    }

    private static func testScriptRunnerEnvironmentPropagation() async throws {
        let result = try await ScriptRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf %s \"$QUOTABAR_TEST_ENV\""],
            environment: ["QUOTABAR_TEST_ENV": "propagated"],
            timeoutOverride: 2
        )
        try expect(
            String(data: result.stdout, encoding: .utf8) == "propagated",
            "ScriptRunner must pass explicit environment overrides"
        )
    }

    // #13 — bounded ScrollView only kicks in past the cap; small account sets hug content.
    private static func testPopoverLayoutBranches() throws {
        // 3 Claude accounts (no codex) stays under the cap → no scroll (ideal-height collapse).
        try expect(
            !PopoverLayout.needsScroll(claudeAccounts: 3, reloginAccounts: 0, hasCodex: false, isStale: false),
            "3 accounts must render without a ScrollView"
        )
        // The live shape (2 Claude + Codex) must also collapse identically.
        try expect(
            !PopoverLayout.needsScroll(claudeAccounts: 2, reloginAccounts: 0, hasCodex: true, isStale: false),
            "2 Claude + Codex must render without a ScrollView"
        )
        // 5 accounts overflow → bounded ScrollView clamped to the cap.
        try expect(
            PopoverLayout.needsScroll(claudeAccounts: 5, reloginAccounts: 0, hasCodex: false, isStale: false),
            "5 accounts must scroll"
        )
        let height = PopoverLayout.regionHeight(
            claudeAccounts: 5, reloginAccounts: 0, hasCodex: false, isStale: false
        )
        try expect(height == PopoverLayout.maxAccountRegionHeight, "scrolling region must clamp to the cap")
    }

    // Codex ping availability/cooldown/title — pure logic, no ping is ever fired.
    private static func testCodexPingLogic() throws {
        try expect(!CodexPing.isAvailable(binaryPath: nil), "nil codex path must hide the button")
        try expect(!CodexPing.isAvailable(binaryPath: ""), "empty codex path must hide the button")
        try expect(CodexPing.isAvailable(binaryPath: "/opt/homebrew/bin/codex"), "resolved codex path must show the button")

        let now = Date(timeIntervalSince1970: 100_000)
        try expect(CodexPing.remaining(lastPing: nil, now: now) == 0, "never-pinged Codex must be ready")
        try expect(CodexPing.remaining(lastPing: now.addingTimeInterval(-1_799), now: now) == 1, "1799s in → 1s left")
        try expect(CodexPing.remaining(lastPing: now.addingTimeInterval(-1_800), now: now) == 0, "1800s in → ready")
        try expect(CodexPing.buttonTitle(remaining: 0) == "Ping", "ready title must be 'Ping'")
        try expect(CodexPing.buttonTitle(remaining: 720) == "Ping · 12m", "cooldown title must show minutes")
    }

    private static func testCancellation() async throws {
        let task = Task {
            try await ScriptRunner.run(
                executable: "/bin/sleep",
                arguments: ["2"],
                timeoutOverride: 3
            )
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            throw TestFailure.failed("cancelled process unexpectedly succeeded")
        } catch ScriptFailure.cancelled {
            return
        }
    }

    private static func makeAccount(
        provider: String = "claude",
        email: String,
        active: Bool = false,
        fetchedAt: Double?,
        staleEntry: Bool? = nil,
        error: String? = nil
    ) -> UsageAccount {
        UsageAccount(
            provider: provider,
            email: email,
            active: active,
            plan: nil,
            status: nil,
            error: error,
            fiveHour: nil,
            sevenDay: nil,
            worstLimit: nil,
            modelCap: nil,
            staleEntry: staleEntry,
            fetchedAt: fetchedAt
        )
    }

    // #2 — a stubborn child that traps SIGTERM must not hang run() past its timeout, and no
    // orphaned grandchild may survive. Uses a sentinel sleep duration to find any orphan.
    private static func testStubbornProcessTreeTimeout() async throws {
        let sentinel = "63.517"
        try expect(pidsMatching("sleep \(sentinel)").isEmpty, "sentinel must be unused before the test")

        let start = Date()
        do {
            _ = try await ScriptRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; sleep \(sentinel) & wait"],
                policy: .usagePoll,
                timeoutOverride: 1
            )
            throw TestFailure.failed("stubborn tree unexpectedly succeeded")
        } catch ScriptFailure.timedOut {
            let elapsed = Date().timeIntervalSince(start)
            try expect(elapsed < 4, "run() must return within timeout+3s (took \(elapsed)s)")
        }

        // Allow a brief moment for the SIGKILL'd descendant to be reaped, then assert no orphan.
        var survivors = pidsMatching("sleep \(sentinel)")
        for _ in 0..<20 where !survivors.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
            survivors = pidsMatching("sleep \(sentinel)")
        }
        try expect(survivors.isEmpty, "orphaned child survived tree kill: \(survivors)")
    }

    private static func pidsMatching(_ pattern: String) -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", pattern]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure.failed(message) }
    }
}
