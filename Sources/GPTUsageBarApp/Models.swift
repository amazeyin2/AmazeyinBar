import Foundation

struct UsagePayload {
    let updatedAt: Date
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
}

struct UsageWindow {
    let utilization: Int
    let resetsAt: Date
    let remainingSeconds: Int
    let windowStats: WindowStats
}

struct WindowStats: Decodable {
    let requests: Int
    let tokens: Int
    let cost: Double
    let standardCost: Double
    let userCost: Double

    enum CodingKeys: String, CodingKey {
        case requests
        case tokens
        case cost
        case standardCost = "standard_cost"
        case userCost = "user_cost"
    }
}

struct AccountUsageState: Identifiable {
    let id: Int
    let account: AccountConfig
    var payload: UsagePayload?
    var lastRefresh: Date?
    var errorMessage: String?

    init(account: AccountConfig, payload: UsagePayload? = nil, lastRefresh: Date? = nil, errorMessage: String? = nil) {
        self.id = account.id
        self.account = account
        self.payload = payload
        self.lastRefresh = lastRefresh
        self.errorMessage = errorMessage
    }

    var hasError: Bool { errorMessage != nil }
}
