import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Text(labelText)
    }

    private var labelText: String {
        if store.isRefreshing { return "C ↻" }
        guard let window = store.codex?.windows.first else { return "C --" }
        return "C \(Int((100 - window.usedPercent).rounded()))%"
    }
}

struct MenuContentView: View {
    @ObservedObject var store: UsageStore

    private let backgroundColor = Color(red: 0.071, green: 0.102, blue: 0.153)
    private let primaryTextColor = Color.white
    private let accentColor = Color(red: 0.000, green: 1.000, blue: 0.250)
    private let secondaryTextColor = Color(red: 0.855, green: 0.894, blue: 0.953)
    private let refreshColor = Color(red: 1.000, green: 0.820, blue: 0.400)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            codexSection
            Divider()
            HStack {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Text(store.isRefreshing ? "刷新中…" : "立即刷新")
                        .fontWeight(.semibold)
                        .foregroundStyle(refreshColor)
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
                Spacer()
                Button("设置…") { SettingsWindowController.shared.show(store: store) }
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 0)
        .frame(width: 340)
        .foregroundStyle(primaryTextColor)
        .tint(accentColor)
        .background(backgroundColor.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var codexSection: some View {
        if let windows = store.codex?.windows, !windows.isEmpty {
            let exactWeekly = windows.first { $0.durationMinutes == 7 * 24 * 60 }
            let exactShortTerm = windows.first { $0.durationMinutes == 5 * 60 }
            let weekly = exactWeekly
                ?? (windows.count > 1 ? windows.max { $0.durationMinutes < $1.durationMinutes } : nil)
            let shortTerm = exactShortTerm
                ?? (windows.count > 1
                    ? windows.min { $0.durationMinutes < $1.durationMinutes }
                    : (exactWeekly == nil ? windows.first : nil))

            VStack(alignment: .leading, spacing: 4) {
                Text("Codex")
                    .fontWeight(.semibold)
                    .foregroundStyle(primaryTextColor)

                Text(codexUsageLabel(weekly: weekly, shortTerm: shortTerm))
                    .fontWeight(.semibold)
                    .foregroundStyle(accentColor)

                if let resetLabel = codexResetLabel(weekly: weekly, shortTerm: shortTerm) {
                    Text(resetLabel)
                        .foregroundStyle(secondaryTextColor)
                }
            }
        } else if let error = store.codexError {
            HStack {
                Text("Codex：\(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Spacer()
                Button("登录") { Task { await store.loginCodex(using: .browser) } }
                    .disabled(store.isLoggingIntoCodex)
            }
        } else {
            HStack { Text("Codex"); Spacer(); ProgressView().controlSize(.small) }
        }
    }

    private func remainingPercent(_ window: CodexRateLimitWindow) -> Int {
        Int(max(0, 100 - window.usedPercent).rounded())
    }

    private func codexUsageLabel(
        weekly: CodexRateLimitWindow?,
        shortTerm: CodexRateLimitWindow?
    ) -> String {
        var labels: [String] = []
        if let weekly {
            labels.append("周剩余 \(remainingPercent(weekly))%")
        }
        if let shortTerm, shortTerm.id != weekly?.id {
            labels.append("短期剩余 \(remainingPercent(shortTerm))%")
        }
        return labels.joined(separator: " · ")
    }

    private func codexResetLabel(
        weekly: CodexRateLimitWindow?,
        shortTerm: CodexRateLimitWindow?
    ) -> String? {
        var labels: [String] = []
        if let reset = weekly?.resetsAt {
            labels.append("周 \(formatResetDate(reset))")
        }
        if let shortTerm, shortTerm.id != weekly?.id, let reset = shortTerm.resetsAt {
            labels.append("短期 \(formatResetDate(reset))")
        }
        return labels.isEmpty ? nil : "重置：" + labels.joined(separator: " · ")
    }

    private func formatResetDate(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .month(.defaultDigits)
                .day(.defaultDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .locale(Locale(identifier: "zh_CN"))
        )
    }

}

struct SettingsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Form {
            Section("Codex") {
                HStack {
                    Text("状态")
                    Spacer()
                    if let account = store.codexAccount, account.isLoggedIn {
                        Text(account.planType.map { "已登录 · \($0)" } ?? "已登录")
                            .foregroundStyle(.green)
                    } else {
                        Text("未登录").foregroundStyle(.secondary)
                    }
                }
                Text("通过本机 Codex app-server 登录并读取真实额度；应用不会读取或保存你的 ChatGPT 登录凭据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(store.codexAccount?.isLoggedIn == true ? "重新登录 Codex" : "登录 Codex") {
                        Task { await store.loginCodex(using: .browser) }
                    }
                    Button("使用设备码登录") {
                        Task { await store.loginCodex(using: .deviceCode) }
                    }
                    Button("刷新用量") { Task { await store.refreshCodex() } }
                }
                .disabled(store.isLoggingIntoCodex)
                if let message = store.codexLoginMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 560)
    }
}
