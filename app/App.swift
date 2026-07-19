import AppKit
import SwiftUI

@main
struct QuotaBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            MenuBarStatusIcon(
                symbolName: model.iconSymbolName,
                severity: model.iconSeverity,
                alertSeverity: model.parkedAlertSeverity
            )
            .accessibilityLabel("QuotaBar — active account \(model.activeAccountInitial)")
            .accessibilityIdentifier("quotabar.menuBarItem")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarStatusIcon: View {
    let symbolName: String
    let severity: Severity?
    let alertSeverity: Severity?

    var body: some View {
        Image(nsImage: Self.makeImage(
            symbolName: symbolName,
            severity: severity,
            alertSeverity: alertSeverity
        ))
        .renderingMode(.original)
    }

    private static func makeImage(
        symbolName: String,
        severity: Severity?,
        alertSeverity: Severity?
    ) -> NSImage {
        let fallback = NSImage(systemSymbolName: symbolName, accessibilityDescription: "QuotaBar")
            ?? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "QuotaBar")
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let pointSize = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let color = severity?.nsColor ?? .systemGray
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        let bolt = fallback.withSymbolConfiguration(pointSize.applying(palette)) ?? fallback

        // Plain bolt only (no monogram). A subtle corner dot signals a parked account
        // that needs attention; the popover's ACTIVE chip names the current account.
        guard let alertSeverity else {
            bolt.isTemplate = false
            bolt.accessibilityDescription = "QuotaBar"
            return bolt
        }

        let dotPad: CGFloat = 1.5 // headroom so the dot is never clipped
        let size = NSSize(width: bolt.size.width + dotPad,
                          height: max(bolt.size.height, 18))
        let image = NSImage(size: size)
        image.lockFocus()
        let boltY = (size.height - bolt.size.height) / 2
        bolt.draw(in: NSRect(x: 0, y: boltY, width: bolt.size.width, height: bolt.size.height))

        // Subtle dot at the bolt's top-right corner for a parked account needing attention.
        let diameter: CGFloat = 4.5
        let boltTop = boltY + bolt.size.height
        let dotRect = NSRect(
            x: bolt.size.width - diameter + 0.5,
            y: boltTop - diameter + 0.5,
            width: diameter,
            height: diameter
        )
        alertSeverity.nsColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = "QuotaBar"
        return image
    }
}
