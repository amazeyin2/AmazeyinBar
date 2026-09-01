import Foundation
import Security

struct Sub2APIAdminService {
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func importAccounts(baseURL: String, apiKey: String, options: ImportOptions?) async throws -> [AccountConfig] {
        let normalizedBaseURL = try Self.normalizedBaseURL(baseURL)
        let accounts = try await fetchAccounts(baseURL: normalizedBaseURL, apiKey: apiKey)
        let platforms = Set((options?.includePlatforms ?? ["openai"]).map { $0.lowercased() })
        let includeDisabled = options?.includeDisabledAccounts ?? false

        let imported = accounts
            .filter { platforms.contains($0.platform.lowercased()) }
            .filter { includeDisabled || $0.status == "active" }
            .filter { $0.schedulable == true }
            .map {
                AccountConfig(
                    id: $0.id,
                    name: $0.name,
                    baseURL: normalizedBaseURL,
                    timezone: "Asia/Shanghai",
                    source: "sub2api-admin",
                    authorization: nil,
                    cookie: nil,
                    accessToken: nil,
                    chatGPTAccountID: nil,
                    fedRAMP: nil,
                    enabled: true
                )
            }

        guard !imported.isEmpty else {
            throw Sub2APIAdminError.noMatchingAccounts
        }
        return imported.sorted { $0.id < $1.id }
    }

    func saveAPIKey(_ apiKey: String, for baseURL: String) throws {
        try Sub2APIAdminKeychain.save(apiKey: apiKey, for: baseURL)
    }

    static func apiKey(for baseURL: String) throws -> String {
        try Sub2APIAdminKeychain.apiKey(for: baseURL)
    }

    static func normalizedBaseURL(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, let host = url.host else {
            throw Sub2APIAdminError.invalidBaseURL
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private func fetchAccounts(baseURL: String, apiKey: String) async throws -> [Sub2APIAccount] {
        guard var components = URLComponents(string: baseURL) else {
            throw Sub2APIAdminError.invalidBaseURL
        }
        components.path = "/api/v1/admin/accounts"
        components.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "page_size", value: "1000"),
        ]
        guard let url = components.url else {
            throw Sub2APIAdminError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Sub2APIAdminError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Sub2APIAdminError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        let envelope = try decoder.decode(Sub2APIAccountListEnvelope.self, from: data)
        guard envelope.code == 0 else {
            throw Sub2APIAdminError.apiError(envelope.message ?? "后台未返回账号列表")
        }
        return envelope.data?.items ?? []
    }
}

private struct Sub2APIAccountListEnvelope: Decodable {
    let code: Int
    let message: String?
    let data: Sub2APIAccountListData?
}

private struct Sub2APIAccountListData: Decodable {
    let items: [Sub2APIAccount]
}

private struct Sub2APIAccount: Decodable {
    let id: Int
    let name: String
    let platform: String
    let status: String
    let schedulable: Bool?
}

enum Sub2APIAdminError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case noMatchingAccounts
    case apiError(String)
    case httpError(statusCode: Int, body: String)
    case keychainError(OSStatus)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Sub2API 后台地址无效。"
        case .invalidResponse:
            "Sub2API 返回了无效响应。"
        case .noMatchingAccounts:
            "没有找到符合当前导入筛选条件的账号。"
        case .apiError(let message):
            message
        case .httpError(let statusCode, let body):
            "Sub2API 请求失败: HTTP \(statusCode) \(body)"
        case .keychainError:
            "无法读取或保存 Sub2API API Key。"
        case .missingAPIKey:
            "未找到该后台地址的 Sub2API API Key，请先从面板导入。"
        }
    }
}

private enum Sub2APIAdminKeychain {
    private static let service = "com.amazeyin.AmazeyinBar.sub2api-admin"

    static func save(apiKey: String, for baseURL: String) throws {
        let account = try Sub2APIAdminService.normalizedBaseURL(baseURL)
        let keyData = Data(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !keyData.isEmpty else { throw Sub2APIAdminError.missingAPIKey }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = keyData
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Sub2APIAdminError.keychainError(status) }
    }

    static func apiKey(for baseURL: String) throws -> String {
        let account = try Sub2APIAdminService.normalizedBaseURL(baseURL)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            if status == errSecItemNotFound { throw Sub2APIAdminError.missingAPIKey }
            throw Sub2APIAdminError.keychainError(status)
        }
        return key
    }
}
