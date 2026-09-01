import Foundation

struct UsageService {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    init(session: URLSession = .shared) {
        self.session = session
        decoder = JSONDecoder()
    }

    func fetchUsage(for account: AccountConfig) async throws -> UsagePayload {
        if account.source == "active" || account.source == "sub2api-admin" {
            return try await fetchAdminUsage(for: account)
        }

        return try await fetchOpenAIUsage(for: account)
    }

    private func fetchOpenAIUsage(for account: AccountConfig) async throws -> UsagePayload {
        guard let accessToken = account.trimmedAccessToken else {
            throw UsageServiceError.missingCredential(account.name, "accessToken")
        }
        guard let chatGPTAccountID = account.trimmedChatGPTAccountID else {
            throw UsageServiceError.missingCredential(account.name, "chatgptAccountId")
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        request.setValue(chatGPTAccountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("zh-CN", forHTTPHeaderField: "oai-language")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("none", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("no-cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("u=4, i", forHTTPHeaderField: "priority")
        if account.fedRAMP == true {
            request.setValue("true", forHTTPHeaderField: "x-openai-fedramp")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageServiceError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UsageServiceError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        let quota = try decoder.decode(OpenAIQuotaUsage.self, from: data)
        return try buildPayload(from: quota)
    }

    private func fetchAdminUsage(for account: AccountConfig) async throws -> UsagePayload {
        let credential: (header: String, value: String)
        do {
            credential = ("x-api-key", try Sub2APIAdminService.apiKey(for: account.baseURL))
        } catch Sub2APIAdminError.missingAPIKey {
            guard let authorization = account.trimmedAuthorization else {
                throw UsageServiceError.missingCredential(account.name, "Sub2API Admin API Key")
            }
            // Existing Chrome imports keep working until the Admin API Key is added.
            credential = ("authorization", authorization)
        }
        guard var components = URLComponents(string: account.baseURL) else {
            throw UsageServiceError.apiError("账号 \(account.name) 的后台地址无效")
        }

        components.path = "/api/v1/admin/accounts/\(account.id)/usage"
        components.queryItems = [
            URLQueryItem(name: "source", value: account.source == "sub2api-admin" ? "active" : account.source),
            URLQueryItem(name: "force", value: "true"),
            URLQueryItem(name: "timezone", value: account.timezone),
        ]
        guard let url = components.url else {
            throw UsageServiceError.apiError("无法生成账号 \(account.name) 的用量地址")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "accept")
        request.setValue(credential.value, forHTTPHeaderField: credential.header)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageServiceError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UsageServiceError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        let envelope = try decoder.decode(AdminUsageEnvelope.self, from: data)
        guard envelope.code == 0, let usage = envelope.data else {
            throw UsageServiceError.apiError(envelope.message ?? "后台未返回用量数据")
        }
        return try usage.payload()
    }

    private func buildPayload(from quota: OpenAIQuotaUsage) throws -> UsagePayload {
        guard let selectedLimit = selectedRateLimit(from: quota) else {
            throw UsageServiceError.apiError("未返回可识别的 rate_limit 窗口")
        }

        let now = Date()
        let normalized = normalize(rateLimit: selectedLimit, now: now)
        return UsagePayload(
            updatedAt: now,
            fiveHour: normalized.fiveHour,
            sevenDay: normalized.sevenDay
        )
    }

    private func selectedRateLimit(from quota: OpenAIQuotaUsage) -> OpenAIRateLimit? {
        let candidates = quota.additionalRateLimits
            .filter { $0.rateLimit != nil }
            .sorted { lhs, rhs in
                rankAdditionalRateLimit(lhs) < rankAdditionalRateLimit(rhs)
            }

        if let preferred = candidates.first(where: { $0.rateLimit?.hasAnyWindow == true })?.rateLimit {
            return preferred
        }

        if quota.rateLimit?.hasAnyWindow == true {
            return quota.rateLimit
        }

        return candidates.first?.rateLimit ?? quota.rateLimit
    }

    private func rankAdditionalRateLimit(_ item: OpenAIAdditionalRateLimit) -> Int {
        let label = "\(item.limitName) \(item.meteredFeature)".lowercased()
        if label.contains("codex") { return 0 }
        if label.contains("gpt") { return 1 }
        return 2
    }

    private func normalize(rateLimit: OpenAIRateLimit, now: Date) -> (fiveHour: UsageWindow, sevenDay: UsageWindow) {
        let windows = [rateLimit.primaryWindow, rateLimit.secondaryWindow].compactMap { $0 }
        var fiveHourWindow: OpenAIRateLimitWindow?
        var sevenDayWindow: OpenAIRateLimitWindow?

        if windows.count >= 2 {
            let sorted = windows.sorted { $0.limitWindowSeconds < $1.limitWindowSeconds }
            fiveHourWindow = sorted.first
            sevenDayWindow = sorted.last
        } else if let singleWindow = windows.first {
            if singleWindow.limitWindowSeconds <= 6 * 60 * 60 {
                fiveHourWindow = singleWindow
            } else {
                sevenDayWindow = singleWindow
            }
        }

        return (
            fiveHour: usageWindow(from: fiveHourWindow, fallbackDuration: 5 * 60 * 60, now: now),
            sevenDay: usageWindow(from: sevenDayWindow, fallbackDuration: 7 * 24 * 60 * 60, now: now)
        )
    }

    private func usageWindow(from window: OpenAIRateLimitWindow?, fallbackDuration: Int, now: Date) -> UsageWindow {
        guard let window else {
            return UsageWindow(
                utilization: 0,
                resetsAt: now.addingTimeInterval(TimeInterval(fallbackDuration)),
                remainingSeconds: fallbackDuration,
                windowStats: .zero
            )
        }

        let resetAt = window.resetAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(window.resetAt))
            : now.addingTimeInterval(TimeInterval(max(window.resetAfterSeconds, 0)))
        let remainingSeconds = max(Int(resetAt.timeIntervalSince(now)), 0)
        let utilization = remainingSeconds == 0 ? 0 : max(Int(window.usedPercent.rounded()), 0)

        return UsageWindow(
            utilization: utilization,
            resetsAt: resetAt,
            remainingSeconds: remainingSeconds,
            windowStats: .zero
        )
    }
}

private struct AdminUsageEnvelope: Decodable {
    let code: Int
    let message: String?
    let data: AdminUsageData?
}

private struct AdminUsageData: Decodable {
    let updatedAt: String
    let fiveHour: AdminUsageWindow
    let sevenDay: AdminUsageWindow

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    func payload() throws -> UsagePayload {
        UsagePayload(
            updatedAt: try Self.parseDate(updatedAt),
            fiveHour: try fiveHour.usageWindow(),
            sevenDay: try sevenDay.usageWindow()
        )
    }

    static func parseDate(_ value: String) throws -> Date {
        for options: ISO8601DateFormatter.Options in [.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value) {
                return date
            }
        }
        throw UsageServiceError.apiError("后台返回了无法识别的时间：\(value)")
    }
}

private struct AdminUsageWindow: Decodable {
    let utilization: Int
    let resetsAt: String
    let remainingSeconds: Int
    let windowStats: WindowStats

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
        case remainingSeconds = "remaining_seconds"
        case windowStats = "window_stats"
    }

    func usageWindow() throws -> UsageWindow {
        UsageWindow(
            utilization: utilization,
            resetsAt: try AdminUsageData.parseDate(resetsAt),
            remainingSeconds: remainingSeconds,
            windowStats: windowStats
        )
    }
}

enum UsageServiceError: LocalizedError {
    case missingCredential(String, String)
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let accountName, let field):
            "账号 \(accountName) 缺少 \(field)，请重新从 Chrome 导入。"
        case .invalidResponse:
            "服务返回了无法识别的响应"
        case .httpError(let statusCode, let body):
            body.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode): \(body)"
        case .apiError(let message):
            "接口错误: \(message)"
        }
    }
}

private struct OpenAIQuotaUsage: Decodable {
    let rateLimit: OpenAIRateLimit?
    let additionalRateLimits: [OpenAIAdditionalRateLimit]

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimit = try container.decodeIfPresent(OpenAIRateLimit.self, forKey: .rateLimit)
        additionalRateLimits = try container.decodeIfPresent([OpenAIAdditionalRateLimit].self, forKey: .additionalRateLimits) ?? []
    }
}

private struct OpenAIAdditionalRateLimit: Decodable {
    let limitName: String
    let meteredFeature: String
    let rateLimit: OpenAIRateLimit?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }
}

private struct OpenAIRateLimit: Decodable {
    let primaryWindow: OpenAIRateLimitWindow?
    let secondaryWindow: OpenAIRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    var hasAnyWindow: Bool {
        primaryWindow != nil || secondaryWindow != nil
    }
}

private struct OpenAIRateLimitWindow: Decodable {
    let usedPercent: Double
    let limitWindowSeconds: Int
    let resetAfterSeconds: Int
    let resetAt: Int64

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

private extension WindowStats {
    static let zero = WindowStats(requests: 0, tokens: 0, cost: 0, standardCost: 0, userCost: 0)
}
