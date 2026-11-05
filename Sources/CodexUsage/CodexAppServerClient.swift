import Foundation

actor CodexAppServerClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var loginWaiters: [String: CheckedContinuation<CodexLoginCompletion, Error>] = [:]
    private var completedLogins: [String: CodexLoginCompletion] = [:]
    private var nextRequestID = 1
    private var initialized = false

    func fetchAccount() async throws -> CodexAccountSnapshot {
        try await ensureInitialized()
        let data = try await request(method: "account/read", params: EmptyParams())
        let result = try JSONDecoder().decode(JSONRPCEnvelope<AccountResponse>.self, from: data).result
        return CodexAccountSnapshot(
            isLoggedIn: result.account != nil,
            method: result.account?.type,
            planType: result.account?.planType
        )
    }

    func startLogin(using method: CodexLoginMethod) async throws -> CodexLoginSession {
        try await ensureInitialized()
        let data: Data
        switch method {
        case .browser:
            data = try await request(method: "account/login/start", params: BrowserLoginParams())
        case .deviceCode:
            data = try await request(method: "account/login/start", params: DeviceCodeLoginParams())
        }
        let result = try JSONDecoder().decode(JSONRPCEnvelope<LoginResponse>.self, from: data).result
        let urlString = result.authURL ?? result.verificationURL
        guard let urlString, let url = URL(string: urlString) else {
            throw UsageMonitorError.invalidResponse
        }
        return CodexLoginSession(id: result.loginID, url: url, userCode: result.userCode)
    }

    func waitForLoginCompletion(loginID: String) async throws -> CodexLoginCompletion {
        if let completion = completedLogins.removeValue(forKey: loginID) {
            return completion
        }
        return try await withCheckedThrowingContinuation { continuation in
            loginWaiters[loginID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5 * 60))
                await self?.timeoutLogin(loginID: loginID)
            }
        }
    }

    func fetchSnapshot() async throws -> CodexUsageSnapshot {
        try await ensureInitialized()
        async let limitsData = request(method: "account/rateLimits/read", params: EmptyParams())
        async let usageData = request(method: "account/usage/read", params: EmptyParams())
        let (rateLimitsData, tokenUsageData) = try await (limitsData, usageData)

        let decoder = JSONDecoder()
        let rateLimits = try decoder.decode(JSONRPCEnvelope<RateLimitsResponse>.self, from: rateLimitsData).result
        let tokenUsage = try decoder.decode(JSONRPCEnvelope<TokenUsageResponse>.self, from: tokenUsageData).result
        let allLimits: [String: RateLimitSnapshot]
        if let rateLimitsByLimitID = rateLimits.rateLimitsByLimitID {
            allLimits = rateLimitsByLimitID
        } else if let rateLimit = rateLimits.rateLimits {
            allLimits = ["codex": rateLimit]
        } else {
            allLimits = [:]
        }
        var windows: [CodexRateLimitWindow] = []
        for limit in allLimits.values {
            for window in [limit.primary, limit.secondary].compactMap({ $0 }) {
                windows.append(CodexRateLimitWindow(
                    id: "\(limit.limitID)-\(window.durationMinutes)",
                    name: limit.limitName ?? limit.limitID,
                    usedPercent: window.usedPercent,
                    durationMinutes: window.durationMinutes,
                    resetsAt: window.resetDate
                ))
            }
        }
        windows.sort { $0.durationMinutes < $1.durationMinutes }

        return CodexUsageSnapshot(
            planType: rateLimits.rateLimits?.planType ?? allLimits.values.first?.planType,
            windows: windows,
            creditBalance: rateLimits.rateLimits?.credits?.balance,
            hasCredits: rateLimits.rateLimits?.credits?.hasCredits ?? false,
            latestDailyTokens: tokenUsage.dailyUsageBuckets?.last?.tokens,
            refreshedAt: .now
        )
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        try startIfNeeded()
        _ = try await request(method: "initialize", params: InitializeParams())
        initialized = true
    }

    private func startIfNeeded() throws {
        guard process == nil else { return }
        let newProcess = Process()
        if let codexURL = codexExecutableURL() {
            newProcess.executableURL = codexURL
            newProcess.arguments = ["app-server", "--stdio"]
        } else {
            newProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            newProcess.arguments = ["codex", "app-server", "--stdio"]
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        newProcess.standardInput = inputPipe
        newProcess.standardOutput = outputPipe
        newProcess.standardError = FileHandle.nullDevice

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receiveOutput(data) }
        }
        newProcess.terminationHandler = { [weak self] process in
            Task { await self?.serverStopped(status: process.terminationStatus) }
        }
        do {
            try newProcess.run()
        } catch {
            throw UsageMonitorError.codexUnavailable("找不到或无法启动 codex app-server：\(error.localizedDescription)")
        }
        process = newProcess
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
    }

    private func codexExecutableURL() -> URL? {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(homeDirectory)/.local/bin/codex"
        ]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func request<Parameters: Encodable>(method: String, params: Parameters) async throws -> Data {
        try startIfNeeded()
        let requestID = nextRequestID
        nextRequestID += 1
        let request = JSONRPCRequest(id: requestID, method: method, params: params)
        let data = try JSONEncoder().encode(request) + Data([0x0A])
        guard let input else { throw UsageMonitorError.codexUnavailable("Codex app-server 未启动") }

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            do {
                try input.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                await self?.timeout(requestID: requestID)
            }
        }
    }

    private func timeout(requestID: Int) {
        pending.removeValue(forKey: requestID)?.resume(throwing: UsageMonitorError.timeout)
    }

    private func timeoutLogin(loginID: String) {
        loginWaiters.removeValue(forKey: loginID)?.resume(throwing: UsageMonitorError.loginTimeout)
    }

    private func receiveOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let method = object["method"] as? String {
                receiveNotification(method: method, object: object)
                continue
            }
            guard let id = object["id"] as? Int else { continue }
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Codex app-server 返回错误"
                pending.removeValue(forKey: id)?.resume(throwing: UsageMonitorError.server(message))
            } else {
                pending.removeValue(forKey: id)?.resume(returning: Data(line))
            }
        }
    }

    private func receiveNotification(method: String, object: [String: Any]) {
        guard method == "account/login/completed",
              let params = object["params"] as? [String: Any],
              let success = params["success"] as? Bool else { return }
        let completion = CodexLoginCompletion(success: success, error: params["error"] as? String)
        if let loginID = params["loginId"] as? String {
            if let waiter = loginWaiters.removeValue(forKey: loginID) {
                waiter.resume(returning: completion)
            } else {
                completedLogins[loginID] = completion
            }
        } else if let loginID = loginWaiters.keys.first,
                  let waiter = loginWaiters.removeValue(forKey: loginID) {
            waiter.resume(returning: completion)
        }
    }

    private func serverStopped(status: Int32) {
        process = nil
        input = nil
        output = nil
        initialized = false
        let error = UsageMonitorError.codexUnavailable("Codex app-server 已退出（\(status)）")
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        let loginContinuations = loginWaiters.values
        loginWaiters.removeAll()
        completedLogins.removeAll()
        loginContinuations.forEach { $0.resume(throwing: error) }
    }
}

private struct EmptyParams: Encodable {}

private struct BrowserLoginParams: Encodable {
    let type = "chatgpt"
    let appBrand = "codex"
    let useHostedLoginSuccessPage = true
}

private struct DeviceCodeLoginParams: Encodable {
    let type = "chatgptDeviceCode"
}

private struct InitializeParams: Encodable {
    let clientInfo = ClientInfo(name: "codex-usage", version: "0.3.0")
    let capabilities: [String: String] = [:]
}

private struct ClientInfo: Encodable {
    let name: String
    let version: String
}

private struct JSONRPCRequest<Parameters: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Parameters
}

private struct JSONRPCEnvelope<Result: Decodable>: Decodable {
    let result: Result
}

private struct AccountResponse: Decodable {
    let account: AccountSnapshot?
}

private struct AccountSnapshot: Decodable {
    let type: String
    let planType: String?
}

private struct LoginResponse: Decodable {
    let loginID: String
    let authURL: String?
    let verificationURL: String?
    let userCode: String?

    enum CodingKeys: String, CodingKey {
        case loginID = "loginId"
        case authURL = "authUrl"
        case verificationURL = "verificationUrl"
        case userCode
    }
}

private struct RateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshot?
    let rateLimitsByLimitID: [String: RateLimitSnapshot]?

    enum CodingKeys: String, CodingKey { case rateLimits, rateLimitsByLimitID = "rateLimitsByLimitId" }
}

private struct RateLimitSnapshot: Decodable {
    let limitID: String
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case limitID = "limitId", limitName, primary, secondary, credits, planType
    }
}

private struct CreditsSnapshot: Decodable {
    let hasCredits: Bool
    let balance: String?
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let durationMinutes: Int
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent, durationMinutes = "windowDurationMins", resetsAt
    }

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        return Date(timeIntervalSince1970: resetsAt > 10_000_000_000 ? resetsAt / 1_000 : resetsAt)
    }
}

private struct TokenUsageResponse: Decodable {
    let dailyUsageBuckets: [DailyUsageBucket]?
}

private struct DailyUsageBucket: Decodable {
    let startDate: String
    let tokens: Int
}
