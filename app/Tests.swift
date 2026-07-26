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
        try testUnresolvedLoginPresentation()
        try testSampleFixtureShape()
        try testMicrosecondTimestamp()
        try testCachedEntryDetection()
        try testCachedDataBadgeText()
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
        try testEpochAndSwitchRouting()
        try testSwapInvocationArguments()
        try testQueuedSwapRaceGuards()
        try testMonitorOnlyDecodeAndRemoveGuard()
        try testEpochHealthCooldownDecode()
        try testHealthAnomalies()
        try testPingCooldownV2()
        try testIdleSessionsParsing()
        try testRuntimeMarkerPayload()
        try testScriptsLocationResolution()
        try testNullUtilizationDecodesTolerantly()
        try testRestartOutcomeMapping()
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

    // The fail-closed identity state must reach the UI as a DESIGNED presentation:
    // structured fields decode, the internal sentinel string never renders, and a
    // stale cache written before the backend emitted the flag still maps over.
    private static func testUnresolvedLoginPresentation() throws {
        let json = #"""
        {
          "generated_at": "2026-07-22T05:00:00Z",
          "accounts": [
            {
              "provider": "claude",
              "email": "(active/unresolved)",
              "active": true,
              "unresolved": true,
              "metadata_email": "person@example.com",
              "plan": "pro"
            },
            {
              "provider": "claude",
              "email": "(active/unresolved)",
              "active": true
            },
            {
              "provider": "claude",
              "email": "person@example.com",
              "active": false
            }
          ]
        }
        """#
        let snapshot = try UsageSnapshot.decode(from: Data(json.utf8))
        let structured = snapshot.accounts[0]
        try expect(structured.isUnresolved, "structured unresolved flag must decode")
        try expect(
            structured.displayName == "person@example.com",
            "unresolved card shows the metadata identity, never the sentinel"
        )
        let staleCache = snapshot.accounts[1]
        try expect(
            staleCache.isUnresolved && staleCache.displayName == "New login",
            "sentinel email from a pre-flag cache still maps to the designed name"
        )
        let named = snapshot.accounts[2]
        try expect(
            !named.isUnresolved && named.displayName == "person@example.com",
            "ordinary accounts keep their email as the display name"
        )
        // Action-surface contract: an unresolved entry (even a stale inactive one)
        // must never expose Remove — its confirmation strip would leak the sentinel.
        let staleInactiveUnresolved = UsageAccount(
            provider: "claude", email: "(active/unresolved)", active: false, plan: nil,
            status: nil, error: nil, fiveHour: nil, sevenDay: nil,
            worstLimit: nil, modelCap: nil, staleEntry: true, fetchedAt: nil,
            unresolved: true, metadataEmail: nil, monitorOnly: nil, cooldownUntil: nil
        )
        try expect(
            !RemoveAccountPolicy.canRemove(staleInactiveUnresolved),
            "stale inactive unresolved entry must not show Remove"
        )
    }

    // A synthetic `usage.py` payload in the shape the app decodes: two Claude accounts (one
    // active, one session-exhausted) plus a Codex account, microsecond timestamps included.
    private static let sampleFixture = #"""
    {
      "generated_at": "2026-01-05T07:20:30Z",
      "active_email": "a@example.com",
      "accounts": [
        {
          "provider": "claude",
          "email": "b@example.com",
          "active": false,
          "five_hour": {"utilization": 100.0, "resets_at": "2026-01-05T07:50:00.100000+00:00"},
          "seven_day": {"utilization": 10.0, "resets_at": "2026-01-10T05:00:00.100000+00:00"},
          "worst_limit": {"kind": "session", "percent": 100.0, "resets_at": "2026-01-05T07:50:00.100000+00:00"},
          "status": "ok",
          "fetched_at": 1767598800.0,
          "plan": "pro"
        },
        {
          "provider": "claude",
          "email": "a@example.com",
          "active": true,
          "five_hour": {"utilization": 30.0, "resets_at": "2026-01-05T11:40:00.200000+00:00"},
          "seven_day": {"utilization": 20.0, "resets_at": "2026-01-11T08:00:00.200000+00:00"},
          "worst_limit": {"kind": "session", "percent": 30.0, "resets_at": "2026-01-05T11:40:00.200000+00:00"},
          "status": "ok",
          "fetched_at": 1767599400.0,
          "plan": "max"
        },
        {
          "provider": "codex",
          "email": "b@example.com",
          "active": false,
          "five_hour": null,
          "seven_day": {"utilization": 40.0, "resets_at": "2026-01-11T08:18:44+00:00"},
          "worst_limit": {"kind": "weekly", "percent": 40.0, "resets_at": "2026-01-11T08:18:44+00:00"},
          "status": "ok",
          "fetched_at": 1767599400.0,
          "plan": "plus"
        }
      ],
      "stale": false,
      "fail_streak": 0,
      "backoff_until": 0,
      "autoping_fired": []
    }
    """#

    private static func testSampleFixtureShape() throws {
        let snapshot = try UsageSnapshot.decode(from: Data(sampleFixture.utf8))
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

    private static func testCachedDataBadgeText() throws {
        // No 429 marker anywhere -> honest generic wording, never an unearned "rate-limited".
        try expect(
            CachedDataBadgeText.headline(activeError: nil, staleReason: nil) == "cached data",
            "absent any rate-limit marker the badge must stay generic"
        )
        // Backoff is generic (429/403/5xx/network all trip it) so it must NOT claim rate-limiting.
        try expect(
            CachedDataBadgeText.headline(
                activeError: nil,
                staleReason: "claude backoff; retry after 2026-07-21T09:00:00Z"
            ) == "cached data",
            "generic backoff must not be attributed to rate-limiting"
        )
        // A surviving HTTP 429 on the active account is a real, distinguishable rate-limit signal.
        try expect(
            CachedDataBadgeText.headline(activeError: "HTTP 429", staleReason: nil)
                == "rate-limited · cached",
            "a live 429 marker must surface plainly as rate-limited"
        )
        try expect(
            CachedDataBadgeText.headline(activeError: "HTTP 429 Too Many Requests", staleReason: nil)
                == "rate-limited · cached",
            "429 detection must not depend on an exact string"
        )
        // Detection is case-insensitive and also honors an explicit stale_reason phrasing.
        try expect(
            CachedDataBadgeText.headline(activeError: nil, staleReason: "Rate Limit exceeded")
                == "rate-limited · cached",
            "a rate-limit stale_reason must surface even without a per-account error"
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
            worstLimit: nil, modelCap: nil, staleEntry: nil, fetchedAt: nil,
            unresolved: nil, metadataEmail: nil, monitorOnly: nil, cooldownUntil: nil
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
            RemoveAccountPolicy.shortEmail("parked.person@example.com") == "parked.person",
            "shortEmail must drop the domain"
        )
        try expect(
            RemoveAccountPolicy.shortEmail("noatsign") == "noatsign",
            "shortEmail must pass through an address with no @"
        )
        try expect(
            RemoveAccountPolicy.inlinePrompt(email: "parked.person@example.com") == "Remove parked.person?",
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
        let original = try UsageSnapshot.decode(from: Data(sampleFixture.utf8))
        let targetEmail = "b@example.com"
        let switched = original.optimisticallyActivatingClaudeAccount(email: targetEmail)
        let claude = switched.accounts.filter(\.isClaude)

        try expect(claude.filter(\.active).count == 1, "optimistic switch must leave one active Claude account")
        try expect(
            claude.first(where: { $0.email == targetEmail })?.active == true,
            "optimistic switch must activate the successful target"
        )
        try expect(
            claude.first(where: { $0.email == "a@example.com" })?.active == false,
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
            unknown.accounts.filter { $0.isClaude && $0.active }.first?.email == "a@example.com",
            "an unknown target must preserve the original active account"
        )
    }

    private static func testStableAccountOrder() throws {
        let first = makeAccount(email: "a@example.com", active: false, fetchedAt: 1_000)
        let codex = makeAccount(
            provider: "codex", email: "b@example.com",
            active: false, fetchedAt: 1_000
        )
        let second = makeAccount(email: "b@example.com", active: true, fetchedAt: 1_000)

        let original = AccountOrdering.claudeAccountsInSnapshotOrder([first, codex, second])
        let switched = AccountOrdering.claudeAccountsInSnapshotOrder([
            first.withActive(true), codex, second.withActive(false)
        ])

        let expected = ["a@example.com", "b@example.com"]
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
                accounts: accounts,
                epoch: nil,
                health: nil
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

    // MARK: - v2 wiring contract tests

    // Epoch parsing + the Switch routing table: v1/unknown -> in-place swap (no restart offer);
    // shadow/v2 -> repoint (future launches) + restart offer.
    private static func testEpochAndSwitchRouting() throws {
        try expect(EpochState.from(nil) == .v1, "absent epoch is the pre-v2 world (v1)")
        try expect(EpochState.from("") == .v1, "empty epoch decodes v1")
        try expect(EpochState.from("v1") == .v1, "explicit v1 decodes v1")
        try expect(EpochState.from("shadow") == .shadow, "shadow decodes shadow")
        try expect(EpochState.from("V2") == .v2, "epoch parse is case-insensitive")
        try expect(EpochState.from("garbage") == .unknown, "a broken epoch decodes unknown")

        try expect(SwitchRoute.route(for: .v1) == .swap, "v1 Switch = in-place swap")
        try expect(SwitchRoute.route(for: .unknown) == .swap, "unknown epoch stays on the safe swap path")
        // (rollback-day) shadow now takes the v1 SEAMLESS swap, not a repoint — the owner rejected
        // pin-at-launch and wants mid-session turn-level pickup. Only v2 repoints.
        try expect(SwitchRoute.route(for: .shadow) == .swap, "shadow Switch = v1 seamless swap (rollback-day)")
        try expect(SwitchRoute.route(for: .v2) == .repoint, "v2 Switch = repoint")
        try expect(!SwitchRoute.swap.offersRestart, "an in-place swap offers no restart")
        try expect(SwitchRoute.repoint.offersRestart, "a repoint offers to restart idle sessions")
        try expect(SwitchRoute.swap.actionTitle == "Swap here", "v1/shadow button reads 'Swap here'")
        try expect(SwitchRoute.repoint.actionTitle == "Switch here", "v2 button reads 'Switch here'")
        // shadow still runs the archiver/registry, so health chrome stays visible under shadow.
        try expect(EpochState.v2.showsHealth && EpochState.shadow.showsHealth, "health shows under shadow|v2")
        try expect(!EpochState.v1.showsHealth && !EpochState.unknown.showsHealth, "health hidden under v1/unknown")
    }

    // (rollback-day) The v1 swap argv: --expect-active is appended ONLY when the active account
    // is known (non-empty and not the target itself), so a stale click can't clobber a newer swap.
    private static func testSwapInvocationArguments() throws {
        let swap = "/x/swap-account.sh"
        try expect(
            SwapInvocation.arguments(swapScript: swap, target: "b@x.com", activeEmail: "a@x.com")
                == [swap, "b@x.com", "--expect-active", "a@x.com"],
            "known active is passed as --expect-active"
        )
        try expect(
            SwapInvocation.arguments(swapScript: swap, target: "b@x.com", activeEmail: nil)
                == [swap, "b@x.com"],
            "unknown active omits the guard flag"
        )
        try expect(
            SwapInvocation.arguments(swapScript: swap, target: "b@x.com", activeEmail: "")
                == [swap, "b@x.com"],
            "empty active omits the guard flag"
        )
        try expect(
            SwapInvocation.arguments(swapScript: swap, target: "b@x.com", activeEmail: "b@x.com")
                == [swap, "b@x.com"],
            "active == target omits the (nonsensical) guard flag"
        )
    }

    // The two halves of the queued-swap race fix: no second swap may be enqueued behind the
    // first (its --expect-active would already be stale), and if one somehow loses the race
    // anyway, the card explains it instead of printing the script's lock diagnostic.
    private static func testQueuedSwapRaceGuards() throws {
        try expect(!SwitchGate.isBlocked(busyKinds: []), "an idle bank blocks nothing")
        try expect(
            !SwitchGate.isBlocked(busyKinds: ["ping", "autoping", "remove"]),
            "non-switch actions must never disable Swap"
        )
        try expect(
            SwitchGate.isBlocked(busyKinds: ["ping", SwitchGate.switchKind]),
            "a switch anywhere in the busy table disables Swap on EVERY card"
        )

        try expect(
            SwapFailureText.message(isSwitch: true, exitCode: 3, stderrLine: "aborted: active is b@example.com")
                == SwapFailureText.staleActive,
            "rc 3 from swap-account.sh reads as a retry instruction, not raw stderr"
        )
        try expect(
            SwapFailureText.message(isSwitch: true, exitCode: 1, stderrLine: "no such account")
                == "no such account",
            "other swap failures keep their own message"
        )
        try expect(
            SwapFailureText.message(isSwitch: false, exitCode: 3, stderrLine: "rc 3 from some other script")
                == "rc 3 from some other script",
            "the rc-3 mapping is scoped to swap/switch actions"
        )
        try expect(
            SwapFailureText.message(isSwitch: true, exitCode: nil, stderrLine: "Script failed")
                == "Script failed",
            "a failure with no exit status (launch/timeout) is untouched"
        )
    }

    // monitor_only decodes, and a v2 monitor-only home is NEVER offered the v1 Remove affordance
    // (it has no bank record; remove-account.sh would fence/fail on it).
    private static func testMonitorOnlyDecodeAndRemoveGuard() throws {
        let json = #"""
        {
          "generated_at": "2026-07-24T05:00:00Z",
          "epoch": "v2",
          "accounts": [
            {"provider": "claude", "email": "home@x.com", "active": false,
             "monitor_only": true, "cooldown_until": 1900000000}
          ]
        }
        """#
        let snapshot = try UsageSnapshot.decode(from: Data(json.utf8))
        try expect(snapshot.epochState == .v2, "epoch field decodes")
        let home = snapshot.accounts[0]
        try expect(home.isMonitorOnly, "monitor_only decodes")
        try expect(home.cooldownUntilDate == Date(timeIntervalSince1970: 1_900_000_000),
                   "cooldown_until decodes to an absolute date")
        try expect(!RemoveAccountPolicy.canRemove(home),
                   "a v2 monitor-only home must NOT show the v1 Remove affordance")
        // an ordinary parked v1 account still shows Remove
        let parked = makeAccount(email: "parked@x.com", active: false, fetchedAt: 1_000)
        try expect(RemoveAccountPolicy.canRemove(parked), "an ordinary parked account still shows Remove")
    }

    // A pre-v2 usage.py payload (no epoch/health) decodes cleanly to v1 + no health.
    private static func testEpochHealthCooldownDecode() throws {
        let legacy = try UsageSnapshot.decode(from: Data(sampleFixture.utf8))
        try expect(legacy.epochState == .v1, "a payload without an epoch field is treated as v1")
        try expect(legacy.health == nil, "a payload without health decodes health = nil")
    }

    private static func testHealthAnomalies() throws {
        func health(from json: String) throws -> Health {
            try JSONDecoder().decode(Health.self, from: Data(json.utf8))
        }
        // healthy: fresh heartbeat, no blind, no drift, no seed audit -> nothing shows.
        let healthy = try health(from: #"{"archiver":{"heartbeat_age":5,"epoch_parked":false,"blind_homes":[]}}"#)
        try expect(HealthPresentation.archiverWarning(healthy, epoch: .v2) == nil, "healthy archiver = no warning")
        try expect(HealthPresentation.isHealthy(healthy, epoch: .v2, seedAuditAckTs: 0), "healthy payload shows no chrome")
        // v1 hides all health even when the payload is anomalous.
        let blind = try health(from: #"{"archiver":{"heartbeat_age":5,"epoch_parked":false,"blind_homes":["/h/a"]}}"#)
        try expect(HealthPresentation.archiverWarning(blind, epoch: .v1) == nil, "v1 hides archiver health")
        try expect(HealthPresentation.archiverWarning(blind, epoch: .v2) != nil, "a blind home warns under v2")
        // stale heartbeat (>10m) warns; just under does not.
        let stale = try health(from: #"{"archiver":{"heartbeat_age":601,"blind_homes":[]}}"#)
        let fresh = try health(from: #"{"archiver":{"heartbeat_age":600,"blind_homes":[]}}"#)
        try expect(HealthPresentation.archiverWarning(stale, epoch: .v2) != nil, ">10m heartbeat warns")
        try expect(HealthPresentation.archiverWarning(fresh, epoch: .v2) == nil, "exactly 10m does not warn")
        // epoch_parked archiver never warns (deliberately idle after rollback).
        let parked = try health(from: #"{"archiver":{"heartbeat_age":9999,"epoch_parked":true,"blind_homes":["/h/a"]}}"#)
        try expect(HealthPresentation.archiverWarning(parked, epoch: .v2) == nil, "epoch_parked archiver is silent")
        // fork drift.
        let drift = try health(from: #"{"fork_drift":{"/h/a":["settings.json","x.json"]}}"#)
        try expect(HealthPresentation.forkDriftLine(drift, epoch: .v2) != nil, "fork drift surfaces a line")
        try expect(HealthPresentation.forkDriftLine(drift, epoch: .v1) == nil, "v1 hides fork drift")
        // seed-audit review: newer than the ack surfaces; ack silences it.
        let audit = try health(from: #"{"seed_audit":{"latest_ts":222,"latest_linked_count":3,"count":2}}"#)
        try expect(HealthPresentation.seedAuditReview(audit, epoch: .v2, ackedTs: 100)?.count == 3,
                   "an unacknowledged seeding event surfaces its shared-file count")
        try expect(HealthPresentation.seedAuditReview(audit, epoch: .v2, ackedTs: 222) == nil,
                   "acknowledging the latest ts silences the review line")
        let emptyAudit = try health(from: #"{"seed_audit":{"latest_ts":222,"latest_linked_count":0,"count":2}}"#)
        try expect(HealthPresentation.seedAuditReview(emptyAudit, epoch: .v2, ackedTs: 0) == nil,
                   "a seeding that shared nothing shows no review line")
    }

    private static func testPingCooldownV2() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        // v2 home cooldown_until wins over any v1 last_ping.
        let v2 = makeAccount(email: "home@x.com", fetchedAt: 1_000,
                             cooldownUntil: now.timeIntervalSince1970 + 300)
        try expect(PingCooldown.remaining(for: v2, v1LastPing: nil, now: now) == 300,
                   "a v2 home uses its absolute cooldown_until")
        let expired = makeAccount(email: "home@x.com", fetchedAt: 1_000,
                                  cooldownUntil: now.timeIntervalSince1970 - 5)
        try expect(PingCooldown.remaining(for: expired, v1LastPing: nil, now: now) == 0,
                   "a lapsed v2 cooldown clamps to zero")
        // a v1 account (no cooldown_until) falls back to the last_ping window.
        let v1 = makeAccount(email: "v1@x.com", fetchedAt: 1_000)
        try expect(PingCooldown.remaining(for: v1, v1LastPing: now.addingTimeInterval(-1_800), now: now) == 0,
                   "a v1 account 30m past its ping is eligible")
        try expect(PingCooldown.remaining(for: v1, v1LastPing: now.addingTimeInterval(-1_799), now: now) == 1,
                   "a v1 account 1799s in still has 1s of cooldown")
    }

    private static func testIdleSessionsParsing() throws {
        let json = #"""
        {
          "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa": {"state": "IDLE", "home": "/homes/other"},
          "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb": {"state": "BUSY", "home": "/homes/other"},
          "cccccccc-cccc-cccc-cccc-cccccccccccc": {"state": "idle", "home": "/homes/target"},
          "dddddddd-dddd-dddd-dddd-dddddddddddd": {"state": "RESTARTING", "home": "/homes/other"}
        }
        """#
        // No target home => IDLE-only filter.
        try expect(
            IdleSessions.movableSessionIDs(fromListJSON: Data(json.utf8), targetHome: nil) == [
                "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "cccccccc-cccc-cccc-cccc-cccccccccccc",
            ],
            "only IDLE sessions (case-insensitive) are restart candidates, sorted"
        )
        // (review #2) a session already pinned to the target home is excluded — moving it is a no-op.
        try expect(
            IdleSessions.movableSessionIDs(fromListJSON: Data(json.utf8), targetHome: "/homes/target") == [
                "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            ],
            "an IDLE session already on the target home is not offered for restart"
        )
        try expect(
            IdleSessions.movableSessionIDs(fromListJSON: Data("not json".utf8), targetHome: nil).isEmpty,
            "malformed session list yields no candidates"
        )
    }

    private static func testRuntimeMarkerPayload() throws {
        try expect(RuntimeMarker.payload(pid: 4321) == "{\"pid\": 4321, \"epoch_aware\": true}\n",
                   "runtime marker payload must match what attest-cutover.sh parses")
    }

    private static func testScriptsLocationResolution() throws {
        // env dir wins when it exists.
        try expect(
            ScriptsLocation.choose(env: "/env/dir", candidates: ["/a", "/b"]) { $0 == "/env/dir" || $0 == "/a" } == "/env/dir",
            "an existing QUOTABAR_SCRIPTS_DIR wins"
        )
        // env set but missing -> fall through to the first existing default.
        try expect(
            ScriptsLocation.choose(env: "/missing", candidates: ["/a", "/b"]) { $0 == "/b" } == "/b",
            "a missing env dir falls through to the first existing default"
        )
        // no env -> first existing candidate, in the order given.
        try expect(
            ScriptsLocation.choose(env: nil, candidates: ["/a", "/b"]) { $0 == "/a" || $0 == "/b" } == "/a",
            "with no env, the first existing candidate wins"
        )
        try expect(
            ScriptsLocation.choose(env: nil, candidates: ["/a", "/b"]) { _ in false } == nil,
            "nothing exists -> nil (caller supplies a last-resort default)"
        )

        // (v101-confirm) The full precedence: override, BUNDLED, XDG install, legacy LAST.
        // The bundled-before-installed rung is the upgrade guarantee: a stale install dir left
        // over from an older Cask must not keep serving old credential-mutating scripts to a
        // new app binary. This test previously enshrined the opposite order.
        let pick = ScriptsLocation.pickScriptsDir
        try expect(
            pick("/env", "/installed", "/bundled", "/legacy", { _ in true }) == "/env",
            "an existing QUOTABAR_SCRIPTS_DIR still outranks everything"
        )
        try expect(
            pick(nil, "/installed", "/bundled", "/legacy", { _ in true }) == "/bundled",
            "the BUNDLED runtime beats a pre-existing install (upgrades must not run old scripts)"
        )
        try expect(
            pick("", "/installed", "/bundled", "/legacy", { _ in true }) == "/bundled",
            "an EMPTY override does not count as an override"
        )
        try expect(
            pick("/missing", "/installed", "/bundled", "/legacy", { $0 != "/missing" }) == "/bundled",
            "an override pointing at nothing falls through to the bundled runtime"
        )
        try expect(
            pick(nil, "/installed", nil, "/legacy", { _ in true }) == "/installed",
            "with NO bundled copy, the XDG install is used before the legacy path"
        )
        try expect(
            pick(nil, "/installed", "/bundled", "/legacy", { $0 == "/legacy" }) == "/legacy",
            "the legacy ~/.claude path is used ONLY when nothing else exists"
        )
        try expect(
            pick(nil, "/installed", nil, "/legacy", { _ in false }) == "/installed",
            "nothing exists -> fall back to the supported install path, never legacy"
        )

        // (r15 #4) bank-dir precedence: BANK_DIR -> ACCOUNT_BANK_DIR -> default. The middle
        // rung is the one the app used to ignore, splitting the app off the shell mutators.
        let bank = ScriptsLocation.pickBankDir
        try expect(bank("/b", "/ab", "/home") == "/b", "BANK_DIR wins when set")
        try expect(bank(nil, "/ab", "/home") == "/ab",
                   "ACCOUNT_BANK_DIR is honoured when BANK_DIR is unset (r15 #4)")
        try expect(bank("", "/ab", "/home") == "/ab", "an EMPTY BANK_DIR falls through, not wins")
        try expect(bank(nil, "", "/home") == "/home/.claude/accounts",
                   "neither set -> the shared ~/.claude/accounts default")
        try expect(bank(nil, nil, "/home") == "/home/.claude/accounts",
                   "absent env vars -> the shared default")
    }

    // (review #3) A stranded-lease restart (rc 75, "not registered / lease held") maps to a
    // recovery hint, not a bare "Script failed"; refusals keep their reason; empty -> "failed".
    private static func testRestartOutcomeMapping() throws {
        try expect(
            RestartOutcomeText.outcome(forFailureLine:
                "successor not registered in time (phase SPAWNED); lease intentionally held — run: restart.py /acc recover sid-x")
                == "needs recovery",
            "a stranded lease maps to a recovery hint"
        )
        try expect(
            RestartOutcomeText.outcome(forFailureLine: nil) == "failed",
            "an empty/absent failure line reads 'failed', never blank"
        )
        try expect(
            RestartOutcomeText.outcome(forFailureLine: "Script failed") == "failed",
            "the generic 'Script failed' is normalized to 'failed'"
        )
        try expect(
            RestartOutcomeText.outcome(forFailureLine: "restart refused: no READY home for x@x.com")
                == "restart refused: no READY home for x@x.com",
            "a refusal keeps its reason"
        )
    }

    // (review #1) A window with utilization:null must NOT throw valueNotFound and blank the whole
    // snapshot — it decodes to a window with no data (nil), and other accounts stay intact.
    private static func testNullUtilizationDecodesTolerantly() throws {
        let json = #"""
        {
          "generated_at": "2026-07-24T05:00:00Z",
          "epoch": "v2",
          "accounts": [
            {"provider": "claude", "email": "home@x.com", "active": false, "monitor_only": true,
             "five_hour": {"utilization": null, "resets_at": "2026-07-24T07:00:00Z"},
             "seven_day": {"utilization": null, "resets_at": null}},
            {"provider": "claude", "email": "good@x.com", "active": true,
             "five_hour": {"utilization": 42, "resets_at": "2026-07-24T07:00:00Z"}}
          ]
        }
        """#
        let snapshot = try UsageSnapshot.decode(from: Data(json.utf8))
        try expect(snapshot.accounts.count == 2,
                   "a null-utilization window must not drop the whole snapshot")
        let home = snapshot.accounts[0]
        try expect(home.fiveHour != nil && home.fiveHour?.utilization == nil,
                   "a null utilization decodes to a window with no data (nil), never a throw")
        try expect(home.fiveHour?.hasData == false, "hasData is false for a null-utilization window")
        try expect(home.sevenDay?.utilization == nil, "the seven_day null variant also decodes tolerantly")
        try expect(snapshot.accounts[1].fiveHour?.utilization == 42,
                   "a real utilization still decodes intact")
    }

    private static func makeAccount(
        provider: String = "claude",
        email: String,
        active: Bool = false,
        fetchedAt: Double?,
        staleEntry: Bool? = nil,
        error: String? = nil,
        monitorOnly: Bool? = nil,
        cooldownUntil: Double? = nil
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
            fetchedAt: fetchedAt,
            unresolved: nil,
            metadataEmail: nil,
            monitorOnly: monitorOnly,
            cooldownUntil: cooldownUntil
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
