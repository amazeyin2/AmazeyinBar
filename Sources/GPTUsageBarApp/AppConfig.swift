import Foundation

struct AppConfig: Codable {
    var refreshIntervalSeconds: Int
    var titleMode: TitleMode
    var accounts: [AccountConfig]
    var importOptions: ImportOptions?
    var webhook: WebhookConfig?

    static let sample = AppConfig(
        refreshIntervalSeconds: 300,
        titleMode: .fiveHour,
        accounts: [
            AccountConfig(
                id: 3,
                name: "主账号",
                baseURL: "https://sub.amazeyin.com",
                timezone: "Asia/Shanghai",
                source: "active",
                authorization: nil,
                cookie: nil,
                accessToken: "REPLACE_WITH_OPENAI_ACCESS_TOKEN",
                chatGPTAccountID: "REPLACE_WITH_CHATGPT_ACCOUNT_ID",
                fedRAMP: false,
                enabled: true
            )
        ],
        importOptions: ImportOptions(
            chromeAccountsURL: "https://sub.amazeyin.com/admin/accounts",
            includePlatforms: ["openai"],
            includeDisabledAccounts: false
        ),
        webhook: WebhookConfig(
            enabled: true,
            bindAddress: "0.0.0.0",
            port: 8787,
            path: "/notify",
            token: "REPLACE_WITH_WEBHOOK_TOKEN"
        )
    )
}

struct ImportOptions: Codable {
    var chromeAccountsURL: String
    var includePlatforms: [String]
    var includeDisabledAccounts: Bool
}

struct WebhookConfig: Codable {
    var enabled: Bool
    var bindAddress: String
    var port: Int
    var path: String
    var token: String?

    var normalizedPath: String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/notify" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    var trimmedToken: String? {
        token?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

enum TitleMode: String, Codable, CaseIterable {
    case fiveHour
    case sevenDay
    case compact

    var label: String {
        switch self {
        case .fiveHour: "5H"
        case .sevenDay: "7D"
        case .compact: "CMP"
        }
    }
}

struct AccountConfig: Codable, Identifiable {
    var id: Int
    var name: String
    var baseURL: String
    var timezone: String
    var source: String
    var authorization: String?
    var cookie: String?
    var accessToken: String?
    var chatGPTAccountID: String?
    var fedRAMP: Bool?
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case timezone
        case source
        case authorization
        case cookie
        case accessToken
        case chatGPTAccountID = "chatgptAccountId"
        case legacyChatGPTAccountID = "chatGPTAccountID"
        case fedRAMP
        case enabled
    }

    init(
        id: Int,
        name: String,
        baseURL: String,
        timezone: String,
        source: String,
        authorization: String?,
        cookie: String?,
        accessToken: String?,
        chatGPTAccountID: String?,
        fedRAMP: Bool?,
        enabled: Bool
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.timezone = timezone
        self.source = source
        self.authorization = authorization
        self.cookie = cookie
        self.accessToken = accessToken
        self.chatGPTAccountID = chatGPTAccountID
        self.fedRAMP = fedRAMP
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://sub.amazeyin.com"
        timezone = try container.decodeIfPresent(String.self, forKey: .timezone) ?? "Asia/Shanghai"
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "active"
        authorization = try container.decodeIfPresent(String.self, forKey: .authorization)
        cookie = try container.decodeIfPresent(String.self, forKey: .cookie)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        chatGPTAccountID =
            try container.decodeIfPresent(String.self, forKey: .chatGPTAccountID)
            ?? (try container.decodeIfPresent(String.self, forKey: .legacyChatGPTAccountID))
        fedRAMP = try container.decodeIfPresent(Bool.self, forKey: .fedRAMP)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(timezone, forKey: .timezone)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(authorization, forKey: .authorization)
        try container.encodeIfPresent(cookie, forKey: .cookie)
        try container.encodeIfPresent(accessToken, forKey: .accessToken)
        try container.encodeIfPresent(chatGPTAccountID, forKey: .chatGPTAccountID)
        try container.encodeIfPresent(fedRAMP, forKey: .fedRAMP)
        try container.encode(enabled, forKey: .enabled)
    }

    var trimmedCookie: String? {
        cookie?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var trimmedAccessToken: String? {
        accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var trimmedChatGPTAccountID: String? {
        chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
