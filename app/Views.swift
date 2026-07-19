import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            if model.isStale {
                CachedDataBadge(ageText: model.cachedAgeText)
            }

            // Ideal-height collapse: with few accounts the region is a plain VStack (no
            // ScrollView), so the popover hugs its content exactly as before. Only when the
            // estimate would exceed the cap do we wrap it in a bounded ScrollView, leaving the
            // footer pinned outside so lower cards and the footer stay reachable (#13).
            if PopoverLayout.needsScroll(
                claudeAccounts: model.claudeAccounts.count,
                reloginAccounts: reloginCount,
                hasCodex: model.codexAccount != nil,
                isStale: model.isStale
            ) {
                ScrollView {
                    accountRegion
                }
                .frame(height: PopoverLayout.regionHeight(
                    claudeAccounts: model.claudeAccounts.count,
                    reloginAccounts: reloginCount,
                    hasCodex: model.codexAccount != nil,
                    isStale: model.isStale
                ))
            } else {
                accountRegion
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
        .padding(.top, model.isStale ? 0 : 12)
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
    let ageText: String

    var body: some View {
        HStack(spacing: 5) {
            Text("cached data")
                .fontWeight(.semibold)
            Text("· \(ageText)")
        }
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.14), in: Capsule())
            .padding(.top, 11)
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

            if model.isArmedForRemoval(account) {
                RemoveConfirmationStrip(account: account, model: model)
            }

            if let fiveHour = account.fiveHour {
                UsageGaugeRow(
                    label: "5h", limit: fiveHour, now: model.currentDate,
                    freshness: freshness
                )
            }
            if let sevenDay = account.sevenDay {
                UsageGaugeRow(
                    label: "Week", limit: sevenDay, now: model.currentDate,
                    freshness: freshness
                )
            }

            if let caption = model.freshnessCaption(for: account) {
                AccountFreshnessCaption(freshness: freshness, text: caption)
            }

            if let cap = account.modelCap {
                Text("model cap \(wholePercent(cap.percent))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("quotabar.modelCap.\(safeIdentifier(account.email))")
            }

            HStack(alignment: .center, spacing: 7) {
                CardActionButton(
                    title: pingTitle,
                    showSpinner: isRunning("ping"),
                    queued: isQueued("ping"),
                    disabled: model.isBusy(email: account.email) || model.isPingCoolingDown(email: account.email),
                    identifier: "quotabar.ping.\(safeIdentifier(account.email))",
                    action: { model.ping(account) }
                )

                if !account.active {
                    CardActionButton(
                        title: "Switch here",
                        showSpinner: isRunning("switch"),
                        queued: isQueued("switch"),
                        disabled: model.isBusy(email: account.email),
                        identifier: "quotabar.switch.\(safeIdentifier(account.email))",
                        action: { model.switchHere(account) }
                    )
                }

                Spacer(minLength: 2)

                AutoPingToggle(account: account, model: model)
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
                Text(account.email)
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
        let remaining = model.pingRemaining(email: account.email)
        guard remaining > 0 else { return "Ping" }
        return "Ping · \(shortDuration(remaining))"
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
                Text(queued ? "Queued" : title)
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

            Text(account.email)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 2)

            if let plan = PlanCapsulePresentation.text(for: account.plan) {
                Chip(text: plan, tint: .secondary)
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
        .help("Remove \(account.email)")
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
        VStack(alignment: .leading, spacing: 6) {
            Text(RemoveAccountPolicy.inlinePrompt(email: account.email))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 7) {
                Button("Cancel") { model.cancelRemovalConfirmation() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("quotabar.remove.cancel.\(safeIdentifier(account.email))")

                Button(RemoveAccountPolicy.confirmButtonTitle) { model.confirmRemoval(account) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .disabled(model.isBusy(email: account.email))
                    .accessibilityIdentifier("quotabar.remove.confirm.\(safeIdentifier(account.email))")
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.22), lineWidth: 0.75)
        }
        .help(RemoveAccountPolicy.confirmationMessage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quotabar.removeConfirm.\(safeIdentifier(account.email))")
    }
}

private struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
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
            if freshness == .stale {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            } else if freshness == .updating {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 10))
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
    let limit: UsageLimit
    let now: Date
    let freshness: CardFreshness

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)

                Gauge(value: clamped(limit.utilization), in: 0...100) {
                    EmptyView()
                }
                .gaugeStyle(.linearCapacity)
                .tint(gaugeTint)

                Text("\(wholePercent(limit.utilization))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(numbersAreCached ? Color.secondary : Color.primary)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }

            if let reset = limit.resetsAt {
                Text(TimeFormatting.resetCaption(resetAt: reset, now: now))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 42)
                    .lineLimit(1)
            }
        }
        .opacity(contentOpacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var numbersAreCached: Bool {
        freshness == .stale || freshness == .updating
    }

    private var gaugeTint: Color {
        numbersAreCached ? Color.secondary : Severity.forPercent(limit.utilization).color
    }

    private var contentOpacity: Double {
        switch freshness {
        case .updating: 0.35
        case .stale: 0.62
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
        var summary = "\(spokenWindow) window, \(wholePercent(limit.utilization)) percent"
        if let reset = limit.resetsAt {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(account.severity?.color ?? Color.gray)
                    .frame(width: 7, height: 7)
                Text("Codex")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let plan = PlanCapsulePresentation.text(for: account.plan) {
                    Chip(text: plan, tint: .secondary)
                }
            }

            if let fiveHour = account.fiveHour {
                UsageGaugeRow(
                    label: "5h", limit: fiveHour, now: model.currentDate,
                    freshness: freshness
                )
            }
            if let sevenDay = account.sevenDay {
                UsageGaugeRow(
                    label: "Week", limit: sevenDay, now: model.currentDate,
                    freshness: freshness
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

private struct FooterView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(model.updatedText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("quotabar.updated")

                Text("·")
                    .foregroundStyle(.tertiary)

                Button {
                    model.refresh()
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .accessibilityLabel("Refresh")
                .accessibilityIdentifier("quotabar.refresh")

                Spacer()

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

                    Divider()

                    Button("Quit") {
                        model.quit()
                    }
                    .accessibilityIdentifier("quotabar.quit")
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
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
        }
    }
}

private func clamped(_ value: Double) -> Double {
    min(max(value, 0), 100)
}

private func wholePercent(_ value: Double) -> Int {
    Int(value.rounded())
}

private func shortDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval.rounded(.up)))
    let minutes = max(1, Int(ceil(Double(seconds) / 60)))
    return "\(minutes)m"
}

private func isScopedLimit(_ kind: String) -> Bool {
    let normalized = kind.lowercased().replacingOccurrences(of: "-", with: "_")
    return !["session", "five_hour", "5h", "weekly", "week", "seven_day"].contains(normalized)
}

private func safeIdentifier(_ value: String) -> String {
    value.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
}
