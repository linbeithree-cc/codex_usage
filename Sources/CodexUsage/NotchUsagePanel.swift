import AppKit
import SwiftUI

@MainActor
final class NotchUsagePanelController {
    static let shared = NotchUsagePanelController()

    private let panelSize = NSSize(width: 310, height: 112)
    private var panel: NSPanel?

    func show(store: UsageStore, on screen: NSScreen) {
        let hostingView = NSHostingView(rootView: NotchUsagePopupView(store: store))

        let panel: NSPanel
        if let existingPanel = self.panel {
            panel = existingPanel
            panel.contentView = hostingView
        } else {
            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.contentView = hostingView
            self.panel = panel
        }

        let origin = NSPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.maxY - screen.safeAreaInsets.top - panelSize.height - 8
        )
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

struct NotchUsagePopupView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.codexError == nil ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(store.isRefreshing ? "Codex · 正在刷新…" : "Codex 用量")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let refreshedAt = store.codex?.refreshedAt {
                    Text(refreshedAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let windows = store.codex?.windows, !windows.isEmpty {
                HStack(spacing: 8) {
                    if let weekly = weeklyWindow(from: windows) {
                        usageCard(title: "周剩余", window: weekly)
                    }
                    if let shortTerm = shortTermWindow(from: windows) {
                        usageCard(title: "短期剩余", window: shortTerm)
                    }
                }
            } else if let error = store.codexError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(12)
        .frame(width: 310, height: 112)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.14))
        }
        .environment(\.colorScheme, .dark)
    }

    private func usageCard(title: String, window: CodexRateLimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("\(remainingPercent(window))%")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0, green: 1, blue: 0.25))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func remainingPercent(_ window: CodexRateLimitWindow) -> Int {
        Int(max(0, 100 - window.usedPercent).rounded())
    }

    private func weeklyWindow(from windows: [CodexRateLimitWindow]) -> CodexRateLimitWindow? {
        windows.first { $0.durationMinutes == 7 * 24 * 60 }
            ?? (windows.count > 1 ? windows.max { $0.durationMinutes < $1.durationMinutes } : nil)
    }

    private func shortTermWindow(from windows: [CodexRateLimitWindow]) -> CodexRateLimitWindow? {
        if let exact = windows.first(where: { $0.durationMinutes == 5 * 60 }) {
            return exact
        }
        let weekly = weeklyWindow(from: windows)
        return windows
            .filter { $0.id != weekly?.id }
            .min { $0.durationMinutes < $1.durationMinutes }
    }
}
