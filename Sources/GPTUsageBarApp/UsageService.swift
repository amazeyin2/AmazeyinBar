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
