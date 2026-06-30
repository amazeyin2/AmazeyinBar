import Foundation

struct CurlImportSummary {
    let importedAccounts: [AccountConfig]

    var importedCount: Int { importedAccounts.count }
}

struct CurlImportService {
    func importAccounts(from curlText: String) throws -> CurlImportSummary {
        let parser = CurlCommandParser(rawText: curlText)
        let parsed = try parser.parse()
        let credentials = try ImportedCurlCredentials(parsed: parsed)

        let account = AccountConfig(
            id: stableAccountID(from: credentials.chatGPTAccountID),
            name: credentials.accountName,
            baseURL: credentials.baseURL,
            timezone: "Asia/Shanghai",
            source: "curl",
            authorization: credentials.authorizationHeader,
            cookie: credentials.cookie,
            accessToken: credentials.accessToken,
            chatGPTAccountID: credentials.chatGPTAccountID,
            fedRAMP: credentials.fedRAMP,
            enabled: true
        )

        return CurlImportSummary(importedAccounts: [account])
    }

    private func stableAccountID(from accountID: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in accountID.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash & 0x7fff_ffff)
    }
}

private struct ImportedCurlCredentials {
    let baseURL: String
    let authorizationHeader: String
    let accessToken: String
    let chatGPTAccountID: String
    let cookie: String?
    let fedRAMP: Bool
    let accountName: String

    init(parsed: ParsedCurlCommand) throws {
        guard let url = URL(string: parsed.url), let scheme = url.scheme, let host = url.host else {
            throw CurlImportError.invalidCurl("未识别到有效的请求 URL。")
        }

        let headers = Dictionary(uniqueKeysWithValues: parsed.headers.map { ($0.name.lowercased(), $0.value) })
        guard let authorizationHeader = headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines), !authorizationHeader.isEmpty else {
            throw CurlImportError.missingAuthorization
        }

        let accessToken: String
        if authorizationHeader.lowercased().hasPrefix("bearer ") {
            accessToken = String(authorizationHeader.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            throw CurlImportError.unsupportedAuthorization
        }

        let jwtClaims = JWTClaims(token: accessToken)
        let trimmedHeaderAccountID = headers["chatgpt-account-id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chatGPTAccountID =
            (trimmedHeaderAccountID?.isEmpty == false ? trimmedHeaderAccountID : nil)
            ?? jwtClaims.chatGPTAccountID
        guard let chatGPTAccountID else {
            throw CurlImportError.missingChatGPTAccountID
        }

        baseURL = "\(scheme)://\(host)"
        self.authorizationHeader = authorizationHeader
        self.accessToken = accessToken
        self.chatGPTAccountID = chatGPTAccountID
        if let trimmedCookie = parsed.cookie?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedCookie.isEmpty {
            cookie = trimmedCookie
        } else {
            cookie = nil
        }
        fedRAMP = jwtClaims.fedRAMP
        accountName = jwtClaims.preferredDisplayName(fallbackAccountID: chatGPTAccountID)
    }
}

private struct ParsedCurlCommand {
    let url: String
    let headers: [(name: String, value: String)]
    let cookie: String?
}

private struct CurlCommandParser {
    let rawText: String

    func parse() throws -> ParsedCurlCommand {
        let normalized = rawText
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\\\r", with: " ")

        guard let url = firstSingleQuotedValue(after: "curl", in: normalized) else {
            throw CurlImportError.invalidCurl("没有找到 `curl 'https://...'` 这一段。")
        }

        var headers: [(name: String, value: String)] = []
        let headerPatterns = [
            "-H '",
            "--header '",
            "-H \"",
            "--header \"",
        ]
        for pattern in headerPatterns {
            headers.append(contentsOf: headersMatching(pattern: pattern, in: normalized))
        }

        let cookie = firstArgumentValue(flags: ["-b", "--cookie"], in: normalized)
        return ParsedCurlCommand(url: url, headers: headers, cookie: cookie)
    }

    private func headersMatching(pattern: String, in text: String) -> [(name: String, value: String)] {
        var matches: [(name: String, value: String)] = []
        var searchStart = text.startIndex
        while let range = text.range(of: pattern, range: searchStart ..< text.endIndex) {
            let quote = pattern.last!
            let valueStart = range.upperBound
            guard let valueEnd = text[valueStart...].firstIndex(of: quote) else { break }
            let rawHeader = String(text[valueStart ..< valueEnd])
            if let separator = rawHeader.firstIndex(of: ":") {
                let name = String(rawHeader[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(rawHeader[rawHeader.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !value.isEmpty {
                    matches.append((name, value))
                }
            }
            searchStart = text.index(after: valueEnd)
        }
        return matches
    }

    private func firstSingleQuotedValue(after prefix: String, in text: String) -> String? {
        guard let prefixRange = text.range(of: prefix) else { return nil }
        let suffix = text[prefixRange.upperBound...]
        guard let firstQuote = suffix.firstIndex(of: "'") else { return nil }
        let contentStart = suffix.index(after: firstQuote)
        guard let endQuote = suffix[contentStart...].firstIndex(of: "'") else { return nil }
        return String(suffix[contentStart ..< endQuote])
    }

    private func firstArgumentValue(flags: [String], in text: String) -> String? {
        for flag in flags {
            for quote in ["'", "\""] {
                let pattern = "\(flag) \(quote)"
                guard let range = text.range(of: pattern) else { continue }
                let valueStart = range.upperBound
                guard let endQuote = text[valueStart...].firstIndex(of: Character(quote)) else { continue }
                return String(text[valueStart ..< endQuote])
            }
        }
        return nil
    }
}

private struct JWTClaims {
    let email: String?
    let chatGPTAccountID: String?
    let fedRAMP: Bool

    init(token: String) {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = Self.base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            email = nil
            chatGPTAccountID = nil
            fedRAMP = false
            return
        }

        let profile = json["https://api.openai.com/profile"] as? [String: Any]
        email = profile?["email"] as? String

        let auth = json["https://api.openai.com/auth"] as? [String: Any]
        chatGPTAccountID = auth?["chatgpt_account_id"] as? String
        fedRAMP = auth?["chatgpt_account_is_fedramp"] as? Bool ?? false
    }

    func preferredDisplayName(fallbackAccountID: String) -> String {
        if let email, !email.isEmpty {
            let user = email.split(separator: "@").first.map(String.init) ?? email
            return "ChatGPT \(user)"
        }
        return "ChatGPT \(String(fallbackAccountID.prefix(8)))"
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 {
            value += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: value)
    }
}

enum CurlImportError: LocalizedError {
    case clipboardEmpty
    case invalidCurl(String)
    case missingAuthorization
    case unsupportedAuthorization
    case missingChatGPTAccountID

    var errorDescription: String? {
        switch self {
        case .clipboardEmpty:
            "剪贴板里没有文本，请先复制一段 cURL。"
        case .invalidCurl(let message):
            "这段内容不是可识别的 cURL。\(message)"
        case .missingAuthorization:
            "这段 cURL 里没有 `authorization: Bearer ...`，还不能导入。"
        case .unsupportedAuthorization:
            "识别到了 authorization，但不是 Bearer Token 格式。"
        case .missingChatGPTAccountID:
            "这段 cURL 里没有 `chatgpt-account-id`，JWT 里也没解析出来。"
        }
    }
}
