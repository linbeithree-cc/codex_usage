import AppKit
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var codex: CodexUsageSnapshot?
    @Published private(set) var codexAccount: CodexAccountSnapshot?
    @Published private(set) var codexError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoggingIntoCodex = false
    @Published private(set) var codexLoginMessage: String?
    private let codexClient = CodexAppServerClient()
    private var notchHoverMonitor: NotchHoverMonitor?

    init() {
        notchHoverMonitor = NotchHoverMonitor(
            onEnter: { [weak self] _ in
                Task { @MainActor in await self?.refreshAll() }
            },
            onHover: { [weak self] screen in
                guard let self else { return }
                NotchUsagePanelController.shared.show(store: self, on: screen)
            },
            onExit: {
                NotchUsagePanelController.shared.hide()
            }
        )
        Task { await refreshAll() }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshCodex()
    }

    func refreshCodex() async {
        do {
            let account = try await codexClient.fetchAccount()
            codexAccount = account
            guard account.isLoggedIn else {
                codex = nil
                codexError = "尚未登录"
                return
            }
            codex = try await codexClient.fetchSnapshot()
            codexError = nil
        } catch {
            codexError = error.localizedDescription
        }
    }

    func loginCodex(using method: CodexLoginMethod) async {
        guard !isLoggingIntoCodex else { return }
        isLoggingIntoCodex = true
        codexLoginMessage = method == .deviceCode ? "正在申请设备码…" : "正在打开登录页面…"
        defer { isLoggingIntoCodex = false }

        do {
            let session = try await codexClient.startLogin(using: method)
            if let code = session.userCode {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                codexLoginMessage = "设备码 \(code) 已复制，请在浏览器中粘贴"
            } else {
                codexLoginMessage = "请在浏览器中完成登录…"
            }
            guard NSWorkspace.shared.open(session.url) else {
                throw UsageMonitorError.cannotOpenLoginPage
            }
            let completion = try await codexClient.waitForLoginCompletion(loginID: session.id)
            guard completion.success else {
                throw UsageMonitorError.loginFailed(completion.error ?? "未知错误")
            }
            codexLoginMessage = "Codex 登录成功"
            await refreshCodex()
        } catch {
            codexLoginMessage = error.localizedDescription
        }
    }

}

enum UsageMonitorError: LocalizedError {
    case codexUnavailable(String)
    case invalidResponse
    case server(String)
    case timeout
    case loginTimeout
    case cannotOpenLoginPage
    case loginFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexUnavailable(let message), .server(let message): message
        case .invalidResponse: "服务返回了无法识别的数据"
        case .timeout: "读取用量超时，请稍后重试"
        case .loginTimeout: "等待 Codex 登录超时，请重新尝试"
        case .cannotOpenLoginPage: "无法打开 Codex 登录页面"
        case .loginFailed(let message): "Codex 登录失败：\(message)"
        }
    }
}
