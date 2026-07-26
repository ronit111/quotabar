import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            if model.isStale {
                CachedDataBadge(headline: model.cachedDataHeadline, ageText: model.cachedAgeText)
            }

            // Anomaly-only health chrome (archiver stalled/blind · fork drift · seed-audit review).
            // Renders nothing in the healthy state, so the popover looks exactly as before.
            if model.hasHealthAnomaly {
                HealthSection(model: model)
                    .padding(.horizontal, 12)
                    .padding(.top, model.isStale ? 0 : 12)
            }

            // Ideal-height collapse: with few accounts the region is a plain VStack (no
            // ScrollView), so the popover hugs its content exactly as before. Only when the
            // estimate would exceed the cap do we wrap it in a bounded ScrollView, leaving the
            // footer pinned outside so lower cards and the footer stay reachable (#13).
            if PopoverLayout.needsScroll(
                claudeAccounts: model.claudeAccounts.count,
                reloginAccounts: reloginCount,
                hasCodex: model.codexAccount != nil,
                isStale: model.isStale,
                hasHealthBanner: model.hasHealthAnomaly
            ) {
                ScrollView {
                    accountRegion
                }
                .frame(height: PopoverLayout.regionHeight(
                    claudeAccounts: model.claudeAccounts.count,
                    reloginAccounts: reloginCount,
                    hasCodex: model.codexAccount != nil,
                    isStale: model.isStale,
                    hasHealthBanner: model.hasHealthAnomaly
                ))
            } else {
                accountRegion
            }

            // After a shadow|v2 Switch repoints: offer to move idle sessions, then show outcomes.
            if model.hasRestartUI {
                RestartAffordance(model: model)
                    .padding(.horizontal, 12)
            }

            Divider()
                .padding(.horizontal, 12)

            FooterView(model: model)
                .padding(.horizontal, 12)
                .padding(.bottom, 11)
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .onAppear {
            model.popoverOpened()
        }
        .onDisappear {
            model.popoverClosed()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quotabar.popover")
    }

    private var reloginCount: Int {
        model.claudeAccounts.filter(\.needsRelogin).count
    }

    private var accountRegion: some View {
        VStack(spacing: 10) {
            ForEach(model.claudeAccounts) { account in
                ClaudeAccountCard(account: account, model: model)
            }

            if let codex = model.codexAccount {
                CodexAccountCard(account: codex, model: model)
            }

            if model.claudeAccounts.isEmpty && model.codexAccount == nil {
                EmptyStateView(model: model)
            }
        }
        .padding(.horizontal, 12)
        // Zero once anything sits above the cards, so a health banner is one card-gap away from
        // the first card instead of an inset plus a stack gap. PopoverLayout owns the rule because
        // the ScrollView's frame estimate has to add the same number.
        .padding(.top, PopoverLayout.topInset(
            isStale: model.isStale, hasHealthBanner: model.hasHealthAnomaly
        ))
        .padding(.bottom, 2)
    }
}


private struct EmptyStateView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
            Text(model.lastErrorDescription == nil ? "Waiting for usage data…" : "Could not load usage data")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if let error = model.lastErrorDescription {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
            Button("Retry") { model.refresh() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

private struct CachedDataBadge: View {
    let headline: String
    let ageText: String

    var body: some View {
        HStack(spacing: 5) {
            Text(headline)
                .fontWeight(.semibold)
            Text("· \(ageText)")
                .monospacedDigit()
        }
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.14), in: Capsule())
            .overlay {
                // Hairline edge so the capsule holds its shape over the light-mode material,
                // where a 0.14 orange wash alone reads as a smudge.
                Capsule().stroke(Color.orange.opacity(0.28), lineWidth: 0.5)
            }
            .padding(.top, 12)
            .accessibilityIdentifier("quotabar.cachedData")
    }
}

private struct ClaudeAccountCard: View {
    let account: UsageAccount
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if account.needsRelogin {
                reloginCard
            } else {
                usageCard
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quotabar.claude.\(safeIdentifier(account.email))")
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            AccountHeader(account: account, model: model)

            // (r10 #2) v2 monitor-only home: a subtle hairline caption, never a loud badge — its
            // credential is rotated by the home itself; usage.py only reads it.
            if account.isMonitorOnly {
                Text("monitored")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("quotabar.monitored.\(safeIdentifier(account.email))")
            }

            if model.isArmedForRemoval(account) {
                RemoveConfirmationStrip(account: account, model: model)
            }

            if model.isArmedForUnseed(account) {
                UnseedConfirmationStrip(account: account, model: model)
            }

            if let fiveHour = account.fiveHour, let util = fiveHour.utilization {
                UsageGaugeRow(
                    label: "5h", utilization: util, resetsAt: fiveHour.resetsAt,
                    now: model.currentDate, freshness: freshness
                )
            }
            if let sevenDay = account.sevenDay, let util = sevenDay.utilization {
                UsageGaugeRow(
                    label: "Week", utilization: util, resetsAt: sevenDay.resetsAt,
                    now: model.currentDate, freshness: freshness
                )
            }

            if let caption = model.freshnessCaption(for: account) {
                AccountFreshnessCaption(freshness: freshness, text: caption)
            }

            if let superseded = model.supersededCaption(for: account) {
                Label(superseded, systemImage: "link.badge.plus")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("quotabar.superseded.\(safeIdentifier(account.email))")
            }

            if let cap = account.modelCap {
                Text("model cap \(wholePercent(cap.percent))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("quotabar.modelCap.\(safeIdentifier(account.email))")
            }

            if account.isUnresolved {
                // The one meaningful action for an unlinked login is banking it; Ping
                // would bill an account we can't name, Switch would target the sentinel.
                // (v102) Under v2 there is no such action — the slot is a leftover the epoch
                // fences, so the card explains what it is instead of offering a refused button.
                Text(UnresolvedCardPresentation.caption(
                    epoch: model.currentEpoch, displayName: account.displayName
                ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("quotabar.unresolvedHint")
                if UnresolvedCardPresentation.showsLinkButton(epoch: model.currentEpoch) {
                    HStack(alignment: .center, spacing: 7) {
                        CardActionButton(
                            title: "Link account",
                            showSpinner: isRunning("rebank"),
                            queued: isQueued("rebank"),
                            disabled: model.isBusy(email: account.email),
                            identifier: "quotabar.link.\(safeIdentifier(account.email))",
                            action: { model.rebank(account) }
                        )
                        Spacer(minLength: 2)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 7) {
                    CardActionButton(
                        title: pingTitle,
                        showSpinner: isRunning("ping"),
                        queued: isQueued("ping"),
                        disabled: model.isBusy(email: account.email) || model.isPingCoolingDown(for: account),
                        identifier: "quotabar.ping.\(safeIdentifier(account.email))",
                        action: { model.ping(account) }
                    )

                    if !account.active {
                        // (rollback-day) Label is epoch-aware: "Swap here" (v1 seamless swap)
                        // under v1/shadow, "Switch here" (repoint) under v2. Same button slot,
                        // same .switchAccount action kind — only the label and target script differ.
                        CardActionButton(
                            title: model.switchActionTitle,
                            showSpinner: isRunning("switch"),
                            queued: isQueued("switch"),
                            // Global, not per-card: a swap queued behind another swap would carry
                            // a stale --expect-active and abort under the lock (SwitchGate).
                            disabled: model.isBusy(email: account.email) || model.isSwitchInFlight,
                            identifier: "quotabar.switch.\(safeIdentifier(account.email))",
                            action: { model.switchHere(account) }
                        )
                    }

                    Spacer(minLength: 2)

                    AutoPingToggle(account: account, model: model)
                }

                CardSecondaryActions(account: account, model: model)
            }

            if let error = model.cardError(email: account.email) {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityIdentifier("quotabar.error.\(safeIdentifier(account.email))")
            } else if let status = model.cardStatus(email: account.email) {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("quotabar.status.\(safeIdentifier(account.email))")
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
    }

    private var reloginCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(account.displayName)   // never the raw sentinel (r6 #11)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if RemoveAccountPolicy.canRemove(account) {
                    Spacer(minLength: 2)
                    RemoveAccountControl(account: account, model: model)
                }
            }

            if model.isArmedForRemoval(account) {
                RemoveConfirmationStrip(account: account, model: model)
            }

            Text("Re-login needed — run /login, pick this account, then re-bank")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            if let caption = model.freshnessCaption(for: account) {
                AccountFreshnessCaption(freshness: freshness, text: caption)
            }

            CardActionButton(
                title: "Re-bank",
                showSpinner: model.busyAction(email: account.email) == "rebank",
                disabled: model.isBusy(email: account.email),
                identifier: "quotabar.rebank.\(safeIdentifier(account.email))",
                action: { model.rebank(account) }
            )

            if let error = model.cardError(email: account.email) {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.red.opacity(0.22), lineWidth: 0.75)
        }
    }

    private var pingTitle: String {
        PingCountdown.title(remaining: model.pingRemaining(for: account))
    }

    private var freshness: CardFreshness {
        model.freshness(for: account)
    }

    private func isRunning(_ kind: String) -> Bool {
        model.busyAction(email: account.email) == kind && !model.isQueued(email: account.email)
    }

    private func isQueued(_ kind: String) -> Bool {
        model.busyAction(email: account.email) == kind && model.isQueued(email: account.email)
    }
}

private struct CardActionButton: View {
    let title: String
    let showSpinner: Bool
    var queued: Bool = false
    let disabled: Bool
    let identifier: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if queued {
                    Image(systemName: "clock")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                } else if showSpinner {
                    ProgressView()
                        .controlSize(.mini)
                }
                // (v102) The ping countdown ticks every second; monospaced digits keep the button
                // from breathing in and out as the seconds change width.
                Text(queued ? "Queued" : title)
                    .monospacedDigit()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled)
        .brightness(hovering && !disabled ? 0.08 : 0)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(queued ? "Queued" : title)
        .accessibilityIdentifier(identifier)
    }
}

/// Auto-ping badge, now a real toggle (#14): tapping flips the account's membership in
/// `.config.json` via `toggle-autoping.sh`, routed through the same global action queue.
private struct AutoPingToggle: View {
    let account: UsageAccount
    @ObservedObject var model: AppModel

    private var isOn: Bool { model.isAutoPing(email: account.email) }
    private var running: Bool {
        model.busyAction(email: account.email) == "autoping" && !model.isQueued(email: account.email)
    }
    private var queued: Bool {
        model.busyAction(email: account.email) == "autoping" && model.isQueued(email: account.email)
    }

    var body: some View {
        Button {
            model.toggleAutoPing(account)
        } label: {
            HStack(spacing: 4) {
                if running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: queued ? "clock" : (isOn ? "bolt.badge.clock" : "bolt.slash"))
                        .imageScale(.small)
                }
                Text(queued ? "queued" : (isOn ? "auto-ping" : "auto-ping off"))
            }
            .font(.system(size: 10))
            .foregroundStyle(isOn && !queued ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy(email: account.email))
        .help(isOn ? "Turn off auto-ping" : "Turn on auto-ping")
        .accessibilityLabel(isOn ? "Auto-ping on" : "Auto-ping off")
        .accessibilityIdentifier("quotabar.autoPing.\(safeIdentifier(account.email))")
    }
}

private struct AccountHeader: View {
    let account: UsageAccount
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(account.severity?.color ?? Color.gray)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(account.displayName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 2)

            if let plan = PlanCapsulePresentation.text(for: account.plan) {
                Chip(text: plan, tint: .secondary)
            }

            // A keychain login the identity primitive refused to attribute (fail-closed).
            // Rendered as a designed state, never the backend's internal sentinel string.
            if account.isUnresolved {
                Chip(text: "UNLINKED", tint: .orange)
            }

            if account.active {
                Chip(text: "ACTIVE", tint: .accentColor)
            }

            // Parked Claude accounts only (never the active account, never Codex).
            if RemoveAccountPolicy.canRemove(account) {
                RemoveAccountControl(account: account, model: model)
            }
        }
    }
}

/// Trailing delete affordance on a PARKED Claude card. An explicit ✕ (not the old ellipsis
/// "more menu" glyph) that reads as remove: muted secondary tint, shifting to a filled red ✕ on
/// hover or while armed. A tap toggles the card's inline "Remove <email>?" strip (see
/// `RemoveConfirmationStrip`) rather than presenting a modal — the modal `.confirmationDialog`
/// went sticky inside `MenuBarExtra(.window)`. Never rendered for the active account or Codex
/// (see `RemoveAccountPolicy.canRemove`).
private struct RemoveAccountControl: View {
    let account: UsageAccount
    @ObservedObject var model: AppModel

    @State private var hovering = false

    private var armed: Bool { model.isArmedForRemoval(account) }
    private var highlighted: Bool { (hovering || armed) && !model.isBusy(email: account.email) }

    var body: some View {
        Button {
            model.toggleRemovalConfirmation(account)
        } label: {
            Image(systemName: highlighted ? "xmark.circle.fill" : "xmark.circle")
                .imageScale(.medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(highlighted ? Color.red : Color.secondary)
        .onHover { hovering = $0 }
        .disabled(model.isBusy(email: account.email))
        .help("Remove \(account.displayName)")
        .accessibilityLabel(armed ? "Cancel remove account" : "Remove account")
        .accessibilityIdentifier("quotabar.remove.\(safeIdentifier(account.email))")
    }
}

/// Inline confirmation revealed inside a parked Claude card once its ✕ is tapped. Replaces the
/// modal `.confirmationDialog`: no detached presentation binding to outlive the popover, so the
/// stickiness is structurally impossible. Cancel or re-tapping the ✕ reverts; Remove routes
/// through the existing `AppModel.confirmRemoval` -> `removeAccount` -> `ActionScheduler` path.
private struct RemoveConfirmationStrip: View {
    let account: UsageAccount
    @ObservedObject var model: AppModel

    var body: some View {
        InlineConfirmStrip(
            prompt: RemoveAccountPolicy.inlinePrompt(email: account.email),
            confirmTitle: RemoveAccountPolicy.confirmButtonTitle,
            help: RemoveAccountPolicy.confirmationMessage,
            disabled: model.isBusy(email: account.email),
            identifierPrefix: "quotabar.remove",
            email: account.email,
            onCancel: { model.cancelRemovalConfirmation() },
            onConfirm: { model.confirmRemoval(account) }
        )
        .accessibilityIdentifier("quotabar.removeConfirm.\(safeIdentifier(account.email))")
    }
}

/// (v102) The un-seed twin of the remove strip, on a v2 monitor-only card. Deliberately the SAME
/// two-step shape — a prompt naming the account, Cancel, then a red confirm — because it is the
/// same kind of decision, and a second, differently-shaped confirmation would make the popover feel
/// like two apps. Only the verb and the wording of what happens differ.
private struct UnseedConfirmationStrip: View {
    let account: UsageAccount
    @ObservedObject var model: AppModel

    var body: some View {
        InlineConfirmStrip(
            prompt: UnseedPolicy.inlinePrompt(email: account.email),
            confirmTitle: UnseedPolicy.confirmButtonTitle,
            help: UnseedPolicy.confirmationMessage,
            disabled: model.isBusy(email: account.email),
            identifierPrefix: "quotabar.unseed",
            email: account.email,
            onCancel: { model.cancelRemovalConfirmation() },
            onConfirm: { model.confirmUnseed(account) }
        )
        .accessibilityIdentifier("quotabar.unseedConfirm.\(safeIdentifier(account.email))")
    }
}

/// The shared body of both inline confirmations: a red-tinted panel inside the card, no modal, no
/// presentation binding that can outlive the popover.
private struct InlineConfirmStrip: View {
    let prompt: String
    let confirmTitle: String
    let help: String
    let disabled: Bool
    let identifierPrefix: String
    let email: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 7) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("\(identifierPrefix).cancel.\(safeIdentifier(email))")

                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .disabled(disabled)
                    .accessibilityIdentifier("\(identifierPrefix).confirm.\(safeIdentifier(email))")
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.22), lineWidth: 0.75)
        }
        .help(help)
        .accessibilityElement(children: .contain)
    }
}

/// (v102) The card's secondary shelf: actions that are real but rare, kept out of the primary
/// button row so Ping and Swap stay the two things you see. Plain 10pt text that fills in on hover
/// — the same resting/hover pair as the footer glyphs and the per-card ✕ — rather than more
/// bordered buttons, which at this size would read as equal in weight to the actions above them.
/// Renders nothing at all when neither action applies, which is every card under v1.
private struct CardSecondaryActions: View {
    let account: UsageAccount
    @ObservedObject var model: AppModel

    private var showsPinned: Bool {
        PinnedSessionPolicy.canOpen(account, epoch: model.currentEpoch)
    }
    private var showsUnseed: Bool { UnseedPolicy.canUnseed(account) }

    var body: some View {
        if showsPinned || showsUnseed {
            HStack(spacing: 7) {
                if showsPinned {
                    QuietTextButton(
                        title: PinnedSessionPolicy.actionTitle,
                        help: model.isUnseedInFlight
                            ? PinnedSessionPolicy.blockedHelp : PinnedSessionPolicy.help,
                        identifier: "quotabar.pinnedSession.\(safeIdentifier(account.email))",
                        // (v102-r2) An un-seed in flight is tearing down a home under the seeding
                        // barrier; a launch started now would race it (and the scripts would
                        // refuse it). The control goes quiet for the few seconds that takes.
                        disabled: model.isUnseedInFlight,
                        action: { model.openPinnedSession(account) }
                    )
                }
                if showsPinned && showsUnseed {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if showsUnseed {
                    QuietTextButton(
                        title: UnseedPolicy.actionTitle,
                        help: UnseedPolicy.confirmationMessage,
                        identifier: "quotabar.unseed.\(safeIdentifier(account.email))",
                        disabled: model.isBusy(email: account.email),
                        action: { model.toggleUnseedConfirmation(account) }
                    )
                }
                Spacer(minLength: 2)
            }
        }
    }
}

/// A text-weight affordance for the secondary shelf: muted at rest, primary on hover.
private struct QuietTextButton: View {
    let title: String
    let help: String
    let identifier: String
    var disabled: Bool = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .foregroundStyle(hovering && !disabled ? Color.primary : Color.secondary)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

private struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            // All-caps micro-type sets too tightly at 9pt; a touch of tracking keeps
            // MAX / PRO / ACTIVE readable without making the chip larger.
            .kerning(0.3)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct AccountFreshnessCaption: View {
    let freshness: CardFreshness
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            // Fixed slot for the state marker (dot / mini spinner / nothing), so the caption
            // holds its position instead of shifting sideways as freshness changes.
            ZStack {
                if freshness == .stale {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                } else if freshness == .updating {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .frame(width: 11, height: 11)
            .accessibilityHidden(true)

            Text(text)
                // Stale is the one state worth catching mid-scan, so it carries a touch more
                // weight than the neutral "updating…" caption. Same size, no extra chrome.
                .font(.system(size: 10, weight: freshness == .stale ? .medium : .regular))
                .monospacedDigit()
        }
        .foregroundStyle(freshness == .stale ? Color.orange : Color.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel(
            freshness == .stale ? "Cached data, \(text)" : text
        )
    }
}

private struct UsageGaugeRow: View {
    let label: String
    /// Guaranteed present by the call site (a window with a null utilization renders no row —
    /// review #1), so the gauge never shows 0% masquerading as missing data.
    let utilization: Double
    let resetsAt: Date?
    let now: Date
    let freshness: CardFreshness

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)

                Gauge(value: clamped(utilization), in: 0...100) {
                    EmptyView()
                }
                .gaugeStyle(.linearCapacity)
                .tint(gaugeTint)

                Text("\(wholePercent(utilization))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(numbersAreCached ? Color.secondary : Color.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(width: 36, alignment: .trailing)
            }

            if let reset = resetsAt {
                Text(TimeFormatting.resetCaption(resetAt: reset, now: now))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    // Aligns under the gauge, not the window label: 34pt label + 8pt spacing.
                    .padding(.leading, 42)
                    .lineLimit(1)
                    .monospacedDigit()
            }
        }
        .opacity(contentOpacity)
        // A poll that moves the numbers should read as the bar growing, not as a redraw.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: utilization)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: freshness)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var numbersAreCached: Bool {
        freshness == .stale || freshness == .updating
    }

    /// Cached numbers go grey (they aren't the live reading); live ones take the continuous ramp,
    /// so the bar's colour moves with the quantity instead of stepping once at 60% and once at 85%.
    /// The card's status dot and the menu bar icon keep Severity's three steps — see `GaugeRamp`.
    private var gaugeTint: Color {
        numbersAreCached ? Color.secondary : GaugeRamp.color(forPercent: utilization)
    }

    private var contentOpacity: Double {
        switch freshness {
        // Dimmed enough to read as "not the live number", but still readable — at 0.35 the
        // in-flight state looked like the card had gone blank.
        case .updating: 0.45
        case .stale: 0.65
        case .fresh, .aging: 1
        }
    }

    private var spokenWindow: String {
        switch label {
        case "5h": return "5 hour"
        case "Week": return "weekly"
        default: return label
        }
    }

    private var accessibilitySummary: String {
        if freshness == .updating {
            return "\(spokenWindow) usage updating"
        }
        var summary = "\(spokenWindow) window, \(wholePercent(utilization)) percent"
        if let reset = resetsAt {
            let remaining = max(0, Int(reset.timeIntervalSince(now)))
            summary += ", resets in \(TimeFormatting.spokenRelative(seconds: remaining))"
        }
        if freshness == .stale {
            summary = "Cached data, \(summary)"
        }
        return summary
    }
}

private struct CodexAccountCard: View {
    let account: UsageAccount
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle()
                    .fill(account.severity?.color ?? Color.gray)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("Codex")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let plan = PlanCapsulePresentation.text(for: account.plan) {
                    Chip(text: plan, tint: .secondary)
                }
            }

            if let fiveHour = account.fiveHour, let util = fiveHour.utilization {
                UsageGaugeRow(
                    label: "5h", utilization: util, resetsAt: fiveHour.resetsAt,
                    now: model.currentDate, freshness: freshness
                )
            }
            if let sevenDay = account.sevenDay, let util = sevenDay.utilization {
                UsageGaugeRow(
                    label: "Week", utilization: util, resetsAt: sevenDay.resetsAt,
                    now: model.currentDate, freshness: freshness
                )
            }

            if let caption = model.freshnessCaption(for: account) {
                AccountFreshnessCaption(freshness: freshness, text: caption)
            }

            if model.codexPingAvailable {
                HStack(alignment: .center, spacing: 7) {
                    CardActionButton(
                        title: model.codexPingTitle,
                        showSpinner: model.isCodexPingRunning,
                        queued: model.isCodexQueued,
                        disabled: model.isCodexBusy || model.isCodexPingCoolingDown,
                        identifier: "quotabar.codex.ping",
                        action: { model.codexPing() }
                    )
                    Spacer(minLength: 2)
                }

                if let error = model.codexCardError {
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .accessibilityIdentifier("quotabar.codex.error")
                } else if let status = model.codexCardStatus {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                        .accessibilityIdentifier("quotabar.codex.status")
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex account, \(account.email)")
        .help(account.email)
        .accessibilityIdentifier("quotabar.codex")
    }

    private var freshness: CardFreshness {
        model.freshness(for: account)
    }
}

/// Space-reserving in-flight indicator for the footer. Holds a fixed 14×14 slot so the row keeps
/// its layout whether or not a poll is running; the mini spinner matches the refresh button's style
/// (`ProgressView().controlSize(.mini)`) rather than adding a second, differently-styled cue.
private struct RefreshActivityIndicator: View {
    let active: Bool

    var body: some View {
        ZStack {
            if active {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(!active)
        .accessibilityLabel("Refreshing")
    }
}

/// Footer glyph in the house style: muted at rest, filling in on hover — the same resting/hover
/// pair the per-card ✕ and the add-account + already use, so the three footer affordances read as
/// one family instead of three differently-weighted icons.
private struct FooterIconButton: View {
    let symbol: String
    let help: String
    let identifier: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: FooterMetrics.glyphSize))
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Color.primary : Color.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }
}

/// One optical size for every footer glyph (refresh · add · settings), sitting with the 11pt
/// "Updated …" text rather than each icon inheriting a different default.
private enum FooterMetrics {
    static let glyphSize: CGFloat = 12
}

private struct FooterView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                HStack(spacing: 5) {
                    Text(model.updatedText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("quotabar.updated")

                    // In-flight cue: a mini spinner in the refresh button's own style, sitting
                    // right beside the "Updated" text. Its footprint is reserved whether or not a
                    // poll is running, so the row never reflows — opening the popover and seeing the
                    // numbers hold now reads as a deliberate in-progress refresh, not a stuck app.
                    RefreshActivityIndicator(active: model.isRefreshing)
                }

                Text("·")
                    // Was inheriting body size next to 11pt text, so the separator read as a bullet.
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                FooterIconButton(
                    symbol: "arrow.clockwise",
                    help: "Refresh",
                    identifier: "quotabar.refresh",
                    action: { model.refresh() }
                )

                Spacer()

                // Add-account seeds a v2 home (claude-acct --add) — shown only where that flow
                // exists (shadow|v2); under v1 accounts are added the v1 way (/login + bank).
                if model.supportsSeeding {
                    AddAccountControl(model: model)
                }

                Menu {
                    Button("Copy usage summary") {
                        model.copyUsageSummary()
                    }
                    .disabled(model.usageSummaryLine().isEmpty)
                    .accessibilityIdentifier("quotabar.copySummary")

                    Divider()

                    Toggle(
                        "Launch at Login",
                        isOn: Binding(
                            get: { model.loginItemEnabled },
                            set: { model.toggleLaunchAtLogin($0) }
                        )
                    )
                    .accessibilityIdentifier("quotabar.launchAtLogin")

                    Toggle(
                        "Check for Updates",
                        isOn: Binding(
                            get: { model.updateCheckEnabled },
                            set: { model.setUpdateCheckEnabled($0) }
                        )
                    )
                    .accessibilityIdentifier("quotabar.updateCheckToggle")

                    Divider()

                    Button("Quit") {
                        model.quit()
                    }
                    .accessibilityIdentifier("quotabar.quit")
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: FooterMetrics.glyphSize))
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("Settings")
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("quotabar.settings")
            }

            if let error = model.loginItemError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityIdentifier("quotabar.loginItemError")
            }

            if let hint = model.updateHintLine {
                UpdateHintLine(text: hint, onDismiss: { model.dismissUpdateHint() })
            }
        }
    }
}

/// (v102) "1.0.3 available · brew upgrade --cask quotabar", under the footer row. A caption, not a
/// banner: no colour, no icon, no button — the same tertiary hairline weight as the rest of the
/// footer, because a new version is news, not a problem. Dismissing hides this version for good;
/// the next release says its piece once and then goes quiet again too.
private struct UpdateHintLine: View {
    let text: String
    let onDismiss: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 2)

            Button(action: onDismiss) {
                Image(systemName: hovering ? "xmark.circle.fill" : "xmark.circle")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? Color.secondary : Color.secondary.opacity(0.55))
            .onHover { hovering = $0 }
            .help("Hide this version")
            .accessibilityLabel("Hide this update notice")
            .accessibilityIdentifier("quotabar.update.dismiss")
        }
        .accessibilityIdentifier("quotabar.update")
    }
}

/// Anomaly-only health surface: an archiver warning (stalled/blind), a fork-drift line, and a
/// dismissible seed-audit review line. Each row appears only when its signal is present; the
/// parent gates the whole section on `model.hasHealthAnomaly`, so it is invisible when healthy.
private struct HealthSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let warning = model.archiverWarning {
                HealthRow(symbol: "exclamationmark.triangle.fill", tint: .orange,
                          text: warning, emphasized: true, identifier: "quotabar.health.archiver")
            }
            if let drift = model.forkDriftLine {
                HealthRow(symbol: "arrow.triangle.branch", tint: .orange,
                          text: drift, emphasized: true, identifier: "quotabar.health.forkDrift")
            }
            // (v102) A plan change the poll already fixed. Informational styling, not the
            // orange warning treatment above it — nothing here needs the owner to act.
            if let healed = model.healedPlanChange {
                HealthRow(
                    symbol: "arrow.triangle.2.circlepath", tint: .secondary,
                    text: healed.text,
                    identifier: "quotabar.health.planChange",
                    onDismiss: { model.acknowledgeHealedPlanChange(ts: healed.ts) }
                )
            }
            if let review = model.seedAuditReview {
                HealthRow(
                    symbol: "doc.badge.ellipsis", tint: .secondary,
                    text: "Seeding shared \(review.count) file\(review.count == 1 ? "" : "s") into homes — review",
                    identifier: "quotabar.health.seedAudit",
                    onDismiss: { model.acknowledgeSeedAudit(ts: review.ts) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quotabar.health")
    }
}

/// One compact health row: symbol + text at the cached-badge weight, with an optional dismiss ✕
/// (parity with the per-card remove control). Warnings tint orange; informational rows stay neutral.
private struct HealthRow: View {
    let symbol: String
    let tint: Color
    let text: String
    /// A warning the owner is meant to act on reads at full contrast; informational rows
    /// (seed-audit review) stay secondary so the section still whispers overall.
    var emphasized: Bool = false
    let identifier: String
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(emphasized ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle").imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("\(identifier).dismiss")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 0.5)
        }
        .accessibilityIdentifier(identifier)
    }
}

/// The "N idle session(s) can move now — Restart" affordance shown after a repoint Switch, plus
/// per-session outcomes as they complete. Understated: a single compact card, parent-gated on
/// `model.hasRestartUI` so it is absent otherwise.
private struct RestartAffordance: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let offer = model.restartOffer {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Text("\(offer.count) idle session\(offer.count == 1 ? "" : "s") can move now")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 2)
                    Button("Restart") { model.moveIdleSessions() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("quotabar.restart.move")
                    Button { model.dismissRestartOffer() } label: {
                        Image(systemName: "xmark.circle").imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Not now")
                    .accessibilityLabel("Dismiss restart offer")
                    .accessibilityIdentifier("quotabar.restart.dismiss")
                }
            }
            ForEach(model.restartOutcomes.sorted(by: { $0.key < $1.key }), id: \.key) { sid, outcome in
                HStack(spacing: 6) {
                    Image(systemName: outcomeSymbol(outcome))
                        .imageScale(.small)
                        .foregroundStyle(outcome == "moved" ? Color.green : Color.secondary)
                    Text("\(String(sid.prefix(8))) · \(outcome)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quotabar.restart")
    }

    private func outcomeSymbol(_ outcome: String) -> String {
        if outcome == "moved" { return "checkmark.circle.fill" }
        if outcome.hasSuffix("…") { return "clock" }
        return "exclamationmark.circle"
    }
}

/// A subtle footer "+" for the rare add-account event — parity with the per-card remove ✕, NOT a
/// button/card (owner spec: "a subtle and clean +"). Quiet furniture: muted, fills on hover.
/// Tapping prompts for an email, then launches the owner-interactive seeding flow in Terminal
/// (claude-acct --add). The app only opens Terminal; the /login + browser steps are the owner's.
private struct AddAccountControl: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button { promptAndAdd() } label: {
            Image(systemName: hovering ? "plus.circle.fill" : "plus.circle")
                .font(.system(size: FooterMetrics.glyphSize))
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .help("Add an account")
        .accessibilityLabel("Add account")
        .accessibilityIdentifier("quotabar.addAccount")
    }

    private func promptAndAdd() {
        let alert = NSAlert()
        alert.messageText = "Add a Claude account"
        alert.informativeText = "Enter the account email. A Terminal window opens to run the guided sign-in (claude-acct --add): type /login in it, sign into that account, then /exit."
        alert.addButton(withTitle: "Open Terminal")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        field.placeholderString = "name@example.com"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.addAccount(email: field.stringValue)
        }
    }
}

private func clamped(_ value: Double) -> Double {
    min(max(value, 0), 100)
}

private func wholePercent(_ value: Double) -> Int {
    Int(value.rounded())
}

private func isScopedLimit(_ kind: String) -> Bool {
    let normalized = kind.lowercased().replacingOccurrences(of: "-", with: "_")
    return !["session", "five_hour", "5h", "weekly", "week", "seven_day"].contains(normalized)
}

private func safeIdentifier(_ value: String) -> String {
    value.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
}
