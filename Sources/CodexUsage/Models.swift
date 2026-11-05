import Foundation

struct CodexUsageSnapshot: Equatable {
    let planType: String?
    let windows: [CodexRateLimitWindow]
    let creditBalance: String?
    let hasCredits: Bool
    let latestDailyTokens: Int?
    let refreshedAt: Date
}

struct CodexAccountSnapshot: Equatable {
    let isLoggedIn: Bool
    let method: String?
    let planType: String?
}

enum CodexLoginMethod {
    case browser
    case deviceCode
}

struct CodexLoginSession {
    let id: String
    let url: URL
    let userCode: String?
}

struct CodexLoginCompletion {
    let success: Bool
    let error: String?
}

struct CodexRateLimitWindow: Equatable, Identifiable {
    let id: String
    let name: String
    let usedPercent: Double
    let durationMinutes: Int
    let resetsAt: Date?
}
