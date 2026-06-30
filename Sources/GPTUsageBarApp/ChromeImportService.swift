import Foundation

struct ChromeImportSummary {
    let importedAccounts: [AccountConfig]

    var importedCount: Int { importedAccounts.count }
}

struct ChromeImportService {
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func importAccounts(using config: AppConfig) async throws -> ChromeImportSummary {
        let targetURL = config.importOptions?.chromeAccountsURL ?? "https://sub.amazeyin.com/admin/accounts"
        let cdp = try CDPClient()
        defer {
            Task {
                await cdp.close()
            }
        }

        try await cdp.connect()
        let targetId = try await cdp.findTargetID(matching: targetURL)
        let sessionId = try await cdp.attach(to: targetId)
        let captured = try await cdp.captureAccountsAndAuthorization(sessionId: sessionId)

        let baseURL = try normalizedBaseURL(from: targetURL)
        let importedAccounts = try await buildAccounts(from: captured, config: config, baseURL: baseURL)

        return ChromeImportSummary(importedAccounts: importedAccounts)
    }

    private func normalizedBaseURL(from urlString: String) throws -> String {
        guard let url = URL(string: urlString), let scheme = url.scheme, let host = url.host else {
            throw ChromeImportError.invalidTargetURL(urlString)
        }
        return "\(scheme)://\(host)"
    }

    private func buildAccounts(from captured: CapturedAccountsPayload, config: AppConfig, baseURL: String) async throws -> [AccountConfig] {
        let includePlatforms = Set((config.importOptions?.includePlatforms ?? ["openai"]).map { $0.lowercased() })
        let includeDisabled = config.importOptions?.includeDisabledAccounts ?? false
        let visibleAccounts = captured.accounts
            .filter { includePlatforms.contains($0.platform.lowercased()) }
            .filter { includeDisabled || $0.status == "active" }

        var imported: [AccountConfig] = []
        for account in visibleAccounts {
            guard let secrets = try await fetchSecrets(for: account.id, baseURL: baseURL, captured: captured) else {
                continue
            }
            imported.append(
                AccountConfig(
                    id: account.id,
                    name: account.name,
                    baseURL: baseURL,
                    timezone: "Asia/Shanghai",
                    source: "active",
                    authorization: nil,
                    cookie: nil,
                    accessToken: secrets.accessToken,
                    chatGPTAccountID: secrets.chatGPTAccountID,
                    fedRAMP: secrets.fedRAMP,
                    enabled: true
                )
            )
        }

        if imported.isEmpty, !visibleAccounts.isEmpty {
            throw ChromeImportError.openAICredentialsNotFound
        }

        return imported.sorted { $0.id < $1.id }
    }

    private func fetchSecrets(for accountID: Int, baseURL: String, captured: CapturedAccountsPayload) async throws -> ImportedOpenAICredentials? {
        guard let url = exportAccountURL(baseURL: baseURL, accountID: accountID) else {
            throw ChromeImportError.invalidTargetURL(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "accept")
        request.setValue("zh", forHTTPHeaderField: "accept-language")
        request.setValue(captured.authorization, forHTTPHeaderField: "authorization")
        request.setValue("\(baseURL)/admin/accounts", forHTTPHeaderField: "referer")
        if !captured.cookie.isEmpty {
            request.setValue(captured.cookie, forHTTPHeaderField: "cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChromeImportError.accountExportFailed("账号 #\(accountID) 响应无效")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChromeImportError.accountExportFailed("账号 #\(accountID) 导出失败: HTTP \(httpResponse.statusCode) \(body)")
        }

        let envelope = try decoder.decode(AccountExportEnvelope.self, from: data)
        guard envelope.code == 0, let account = envelope.data?.accounts.first else {
            throw ChromeImportError.accountExportFailed("账号 #\(accountID) 导出结果为空")
        }

        let accessToken = account.credentials.stringValue(for: "access_token")
        let chatGPTAccountID =
            account.credentials.stringValue(for: "chatgpt_account_id")
            ?? account.credentials.stringValue(for: "organization_id")

        guard let accessToken, let chatGPTAccountID else {
            return nil
        }

        return ImportedOpenAICredentials(
            accessToken: accessToken,
            chatGPTAccountID: chatGPTAccountID,
            fedRAMP: account.credentials.boolValue(for: "chatgpt_account_is_fedramp")
        )
    }

    private func exportAccountURL(baseURL: String, accountID: Int) -> URL? {
        var components = URLComponents(string: baseURL)
        components?.path = "/api/v1/admin/accounts/data"
        components?.queryItems = [
            URLQueryItem(name: "ids", value: String(accountID)),
            URLQueryItem(name: "include_proxies", value: "false"),
        ]
        return components?.url
    }
}

private struct ImportedOpenAICredentials {
    let accessToken: String
    let chatGPTAccountID: String
    let fedRAMP: Bool
}

private struct CapturedAccountsPayload {
    let authorization: String
    let cookie: String
    let accounts: [ImportedRemoteAccount]
}

private struct ImportedRemoteAccount: Decodable {
    let id: Int
    let name: String
    let platform: String
    let status: String
}

private struct AccountListEnvelope: Decodable {
    let data: AccountListData?
}

private struct AccountListData: Decodable {
    let items: [ImportedRemoteAccount]
}

private struct AccountExportEnvelope: Decodable {
    let code: Int
    let data: AccountExportData?
}

private struct AccountExportData: Decodable {
    let accounts: [ExportedAccount]
}

private struct ExportedAccount: Decodable {
    let credentials: [String: JSONValue]
}

private enum JSONValue: Decodable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"))
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func stringValue(for key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func boolValue(for key: String) -> Bool {
        switch self[key] {
        case .bool(let value):
            value
        case .string(let value):
            ["1", "true", "yes", "on"].contains(value.lowercased())
        default:
            false
        }
    }
}

enum ChromeImportError: LocalizedError {
    case debuggerPortFileMissing
    case invalidDebuggerPort
    case invalidTargetURL(String)
    case targetPageNotFound(String)
    case authorizationNotFound
    case accountListNotFound
    case decodeFailed
    case accountExportFailed(String)
    case openAICredentialsNotFound

    var errorDescription: String? {
        switch self {
        case .debuggerPortFileMissing:
            "没找到 Chrome 调试端口。先确保 Chrome 已开启远程调试并打开账号管理页。"
        case .invalidDebuggerPort:
            "Chrome 调试端口信息无效。"
        case .invalidTargetURL(let value):
            "导入目标 URL 无效: \(value)"
        case .targetPageNotFound(let value):
            "没找到已打开的账号管理页面: \(value)"
        case .authorizationNotFound:
            "没有抓到后台 authorization，请确认当前账号管理页已登录并能正常加载。"
        case .accountListNotFound:
            "没有抓到账号列表请求。"
        case .decodeFailed:
            "抓到了账号列表，但解析失败了。"
        case .accountExportFailed(let message):
            message
        case .openAICredentialsNotFound:
            "没有导入到可直接查询 ChatGPT 的 OpenAI OAuth 凭证，请确认这些账号已完整授权。"
        }
    }
}

private actor CDPClient {
    private let webSocket: URLSessionWebSocketTask
    private let session: URLSession
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    private var receiveTask: Task<Void, Never>?

    init() throws {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/DevToolsActivePort")
        guard let content = try? String(contentsOf: fileURL) else {
            throw ChromeImportError.debuggerPortFileMissing
        }
        let lines = content.split(separator: "\n").map(String.init)
        guard let portString = lines.first, let port = Int(portString), lines.count >= 2 else {
            throw ChromeImportError.invalidDebuggerPort
        }

        let wsPath = lines[1]
        guard let wsURL = URL(string: "ws://127.0.0.1:\(port)\(wsPath)") else {
            throw ChromeImportError.invalidDebuggerPort
        }

        session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: wsURL)
    }

    func connect() async throws {
        webSocket.resume()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
    }

    func close() {
        receiveTask?.cancel()
        webSocket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    func findTargetID(matching urlPrefix: String) async throws -> String {
        let result = try await send(method: "Target.getTargets")
        let targets = result["targetInfos"] as? [[String: Any]] ?? []
        if let matched = targets.first(where: {
            ($0["type"] as? String) == "page" && (($0["url"] as? String)?.hasPrefix(urlPrefix) ?? false)
        }), let targetId = matched["targetId"] as? String {
            return targetId
        }
        throw ChromeImportError.targetPageNotFound(urlPrefix)
    }

    func attach(to targetId: String) async throws -> String {
        let result = try await send(method: "Target.attachToTarget", params: [
            "targetId": targetId,
            "flatten": true,
        ])
        guard let sessionId = result["sessionId"] as? String else {
            throw ChromeImportError.targetPageNotFound(targetId)
        }
        return sessionId
    }

    func captureAccountsAndAuthorization(sessionId: String) async throws -> CapturedAccountsPayload {
        let stream = eventStream()
        _ = try await send(method: "Page.enable", sessionId: sessionId)
        _ = try await send(method: "Network.enable", sessionId: sessionId)
        _ = try await send(method: "Runtime.enable", sessionId: sessionId)

        var requestMeta: [String: (url: String, method: String)] = [:]
        var authEvents: [(authorization: String, cookie: String)] = []
        var accountResponseBody: String?

        let collector = Task {
            for await eventData in stream {
                guard
                    let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
                    event["sessionId"] as? String == sessionId
                else { continue }
                let method = event["method"] as? String ?? ""
                let params = event["params"] as? [String: Any] ?? [:]

                if method == "Network.requestWillBeSent" {
                    guard
                        let requestId = params["requestId"] as? String,
                        let request = params["request"] as? [String: Any],
                        let url = request["url"] as? String,
                        let requestMethod = request["method"] as? String
                    else { continue }
                    requestMeta[requestId] = (url, requestMethod)
                }

                if method == "Network.requestWillBeSentExtraInfo" {
                    let headers = lowercasedHeaders(params["headers"] as? [String: Any] ?? [:])
                    if let authorization = headers["authorization"] {
                        authEvents.append((authorization, headers["cookie"] ?? ""))
                    }
                }

                if method == "Network.responseReceived" {
                    guard
                        let requestId = params["requestId"] as? String,
                        let meta = requestMeta[requestId],
                        meta.url.contains("/api/v1/admin/accounts?page=")
                    else { continue }

                    if let bodyResult = try? await send(
                        method: "Network.getResponseBody",
                        params: ["requestId": requestId],
                        sessionId: sessionId
                    ), let body = bodyResult["body"] as? String {
                        accountResponseBody = body
                    }
                }
            }
        }

        defer {
            collector.cancel()
        }

        _ = try await send(method: "Page.reload", params: ["ignoreCache": false], sessionId: sessionId)
        try await Task.sleep(for: .seconds(5))

        guard let authorization = authEvents.last?.authorization else {
            throw ChromeImportError.authorizationNotFound
        }
        guard let body = accountResponseBody else {
            throw ChromeImportError.accountListNotFound
        }
        guard
            let data = body.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(AccountListEnvelope.self, from: data),
            let accounts = decoded.data?.items
        else {
            throw ChromeImportError.decodeFailed
        }

        return CapturedAccountsPayload(
            authorization: authorization,
            cookie: authEvents.last?.cookie ?? "",
            accounts: accounts
        )
    }

    private func lowercasedHeaders(_ headers: [String: Any]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), "\($0.value)") })
    }

    private func send(method: String, params: [String: Any] = [:], sessionId: String? = nil) async throws -> [String: Any] {
        nextID += 1
        let id = nextID

        var payload: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
        ]
        if let sessionId {
            payload["sessionId"] = sessionId
        }

        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            webSocket.send(.string(text)) { [weak self] error in
                guard let self else { return }
                if let error {
                    Task { await self.failPending(id: id, error: error) }
                }
            }
        }
    }

    private func failPending(id: Int, error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                let message = try await webSocket.receive()
                switch message {
                case .string(let text):
                    try await handle(text: text)
                case .data(let data):
                    let text = String(decoding: data, as: UTF8.self)
                    try await handle(text: text)
                @unknown default:
                    break
                }
            } catch {
                finishAll(with: error)
                return
            }
        }
    }

    private func handle(text: String) async throws {
        guard
            let data = text.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let id = object["id"] as? Int {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Unknown error"
                continuation.resume(throwing: NSError(domain: "CDPClient", code: id, userInfo: [NSLocalizedDescriptionKey: message]))
            } else {
                continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
            }
            return
        }

        for continuation in eventContinuations.values {
            continuation.yield(data)
        }
    }

    private func finishAll(with error: Error) {
        let values = pending
        pending.removeAll()
        for (_, continuation) in values {
            continuation.resume(throwing: error)
        }
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    private func eventStream() -> AsyncStream<Data> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id: id) }
            }
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}
