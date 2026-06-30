import AppKit
import Combine
import Foundation
import Network
import SwiftUI
import UserNotifications

@MainActor
final class WebhookStore: NSObject, ObservableObject {
    @Published private(set) var endpointSummary = "未启用"
    @Published private(set) var lastNotificationSummary: String?
    @Published private(set) var authorizationSummary = "未检查"

    private let configStore: ConfigStore
    private let notificationCenter = UNUserNotificationCenter.current()
    private var listener: NWListener?
    private var configCancellable: AnyCancellable?
    private var currentConfig: WebhookConfig?
    private let logFileURL: URL

    init(configStore: ConfigStore) {
        self.configStore = configStore
        self.logFileURL = configStore.appSupportDirectory.appendingPathComponent("webhook.log")
        super.init()
        notificationCenter.delegate = self
        log("WebhookStore init")
        notificationCenter.requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                if let error {
                    self?.authorizationSummary = "授权失败：\(error.localizedDescription)"
                    self?.log("Notification authorization error: \(error.localizedDescription)")
                } else {
                    self?.authorizationSummary = granted ? "已授权" : "未授权"
                    self?.log("Notification authorization granted: \(granted)")
                }
                await self?.refreshAuthorizationStatus()
            }
        }

        configCancellable = configStore.$config.sink { [weak self] config in
            Task { @MainActor in
                self?.apply(config: config.webhook)
            }
        }

        apply(config: configStore.config.webhook)
        Task { @MainActor in
            await refreshAuthorizationStatus()
        }
    }

    var statusColor: Color {
        guard let config = currentConfig, config.enabled else { return .secondary }
        return listener == nil ? .orange : .green
    }

    var authorizationColor: Color {
        if authorizationSummary.contains("已授权") {
            return .green
        }
        if authorizationSummary.contains("未决定") || authorizationSummary.contains("临时") {
            return .orange
        }
        return .red
    }

    func copySampleCurl() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sampleCurlCommand(), forType: .string)
    }

    func sendTestNotification() async {
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            log("Test notification blocked by authorization status: \(settings.authorizationStatus.rawValue)")
            await presentAuthorizationGuidance()
            return
        }

        let payload = WebhookNotificationPayload(
            title: "AmazeyinBar",
            subtitle: "Webhook 测试",
            message: "桌面通知链路可用",
            sound: true,
            url: nil
        )
        await presentNotification(payload)
    }

    private func apply(config: WebhookConfig?) {
        currentConfig = config
        listener?.cancel()
        listener = nil
        log("Apply config: \(String(describing: config))")

        guard let config, config.enabled else {
            endpointSummary = "未启用"
            log("Webhook disabled")
            return
        }

        guard let port = NWEndpoint.Port(rawValue: UInt16(config.port)) else {
            endpointSummary = "端口无效：\(config.port)"
            log("Invalid port: \(config.port)")
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state, config: config)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection, config: config)
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            endpointSummary = "启动中：\(config.bindAddress):\(config.port)\(config.normalizedPath)"
            log("Listener starting on \(config.bindAddress):\(config.port)\(config.normalizedPath)")
        } catch {
            endpointSummary = "启动失败：\(error.localizedDescription)"
            log("Listener start failed: \(error.localizedDescription)")
        }
    }

    private func handleListenerState(_ state: NWListener.State, config: WebhookConfig) {
        log("Listener state changed: \(String(describing: state))")
        switch state {
        case .ready:
            endpointSummary = "监听中：\(config.bindAddress):\(config.port)\(config.normalizedPath)"
        case .failed(let error):
            endpointSummary = "监听失败：\(error.localizedDescription)"
            listener?.cancel()
            listener = nil
        case .cancelled:
            if currentConfig?.enabled == true {
                endpointSummary = "已停止"
            }
        default:
            break
        }
    }

    nonisolated private func handle(connection: NWConnection, config: WebhookConfig) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, config: config, buffer: Data())
    }

    nonisolated private func receive(on connection: NWConnection, config: WebhookConfig, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.respond(on: connection, status: 500, body: ["ok": false, "error": error.localizedDescription])
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let request = HTTPRequestParser.parse(nextBuffer), request.isComplete {
                Task { @MainActor in
                    await self.process(request: request, on: connection, config: config)
                }
                return
            }

            if isComplete {
                self.respond(on: connection, status: 400, body: ["ok": false, "error": "Malformed HTTP request"])
                return
            }

            self.receive(on: connection, config: config, buffer: nextBuffer)
        }
    }

    private func process(request: HTTPRequest, on connection: NWConnection, config: WebhookConfig) async {
        guard request.path == config.normalizedPath else {
            respond(on: connection, status: 404, body: ["ok": false, "error": "Not found"])
            return
        }

        guard request.method == "POST" || request.method == "GET" else {
            respond(on: connection, status: 405, body: ["ok": false, "error": "Method not allowed"])
            return
        }

        if let token = config.trimmedToken, !request.isAuthorized(expectedToken: token) {
            log("Unauthorized request for \(request.path)")
            respond(on: connection, status: 401, body: ["ok": false, "error": "Unauthorized"])
            return
        }

        if request.method == "GET" {
            respond(on: connection, status: 200, body: ["ok": true, "message": "Webhook receiver is running"])
            return
        }

        do {
            let payload = try request.notificationPayload()
            log("Accepted webhook: \(payload.title) / \(payload.message)")
            await presentNotification(payload)
            respond(
                on: connection,
                status: 200,
                body: [
                    "ok": true,
                    "title": payload.title,
                    "message": payload.message
                ]
            )
        } catch {
            log("Invalid payload: \(error.localizedDescription)")
            respond(on: connection, status: 400, body: ["ok": false, "error": error.localizedDescription])
        }
    }

    private func presentNotification(_ payload: WebhookNotificationPayload) async {
        let settings = await notificationCenter.notificationSettings()
        if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
            log("Native notification unavailable, authorization status: \(settings.authorizationStatus.rawValue)")
            let summary = [payload.title, payload.message]
                .filter { !$0.isEmpty }
                .joined(separator: " - ")
            lastNotificationSummary = summary.isEmpty ? "收到一条通知" : summary
            return
        }

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.subtitle = payload.subtitle ?? ""
        content.body = payload.message
        if payload.sound ?? true {
            content.sound = .default
        }

        let identifier = UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await notificationCenter.add(request)
            log("Notification queued: \(payload.title)")
            scheduleDeliveredNotificationRemoval(identifier: identifier)
        } catch {
            log("Notification queue failed: \(error.localizedDescription)")
        }

        let summary = [payload.title, payload.message]
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
        lastNotificationSummary = summary.isEmpty ? "收到一条通知" : summary
    }

    private func presentAuthorizationGuidance() async {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "AmazeyinBar 还没有通知权限"
            alert.informativeText = "当前只走 App 原生通知。请在系统设置里允许 AmazeyinBar 的通知，然后再点一次“发送本机测试通知”。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "打开通知设置")
            alert.addButton(withTitle: "稍后")
            NSApplication.shared.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                openNotificationSettings()
            }
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func scheduleDeliveredNotificationRemoval(identifier: String) {
        Task { [notificationCenter] in
            try? await Task.sleep(for: .seconds(6))
            notificationCenter.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    private func refreshAuthorizationStatus() async {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized:
            authorizationSummary = "已授权"
        case .denied:
            authorizationSummary = "已拒绝"
        case .notDetermined:
            authorizationSummary = "未决定"
        case .provisional:
            authorizationSummary = "临时授权"
        case .ephemeral:
            authorizationSummary = "临时会话授权"
        @unknown default:
            authorizationSummary = "未知"
        }
        log("Authorization status: \(authorizationSummary)")
    }

    private func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }
    }

    nonisolated private func respond(on connection: NWConnection, status: Int, body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted])) ?? Data("{}".utf8)
        let statusText = HTTPResponse.statusText(for: status)
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: application/json; charset=utf-8\r\n"
        response += "Content-Length: \(data.count)\r\n"
        response += "Connection: close\r\n\r\n"

        var payload = Data(response.utf8)
        payload.append(data)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sampleCurlCommand() -> String {
        guard let config = currentConfig, config.enabled else {
            return "Webhook 未启用"
        }

        let tokenQuery = config.trimmedToken.map { "?token=\($0)" } ?? ""
        return """
        curl -X POST "http://你的Mac局域网IP:\(config.port)\(config.normalizedPath)\(tokenQuery)" \
          -H "Content-Type: application/json" \
          -d '{"title":"Jenkins","subtitle":"构建完成","message":"job 执行成功"}'
        """
    }
}

extension WebhookStore: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

private struct WebhookNotificationPayload: Decodable {
    let title: String
    let subtitle: String?
    let message: String
    let sound: Bool?
    let url: String?
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    let queryItems: [String: String]
    let isComplete: Bool

    func isAuthorized(expectedToken: String) -> Bool {
        if queryItems["token"] == expectedToken {
            return true
        }
        if headers["x-webhook-token"] == expectedToken || headers["token"] == expectedToken {
            return true
        }
        if let authorization = headers["authorization"] {
            let bearer = authorization.replacingOccurrences(of: "Bearer ", with: "")
            if bearer == expectedToken {
                return true
            }
        }
        return false
    }

    func notificationPayload() throws -> WebhookNotificationPayload {
        if body.isEmpty {
            return WebhookNotificationPayload(
                title: queryItems["title"] ?? "Webhook 通知",
                subtitle: queryItems["subtitle"],
                message: queryItems["message"] ?? queryItems["body"] ?? "收到一条通知",
                sound: true,
                url: queryItems["url"]
            )
        }

        if let jsonObject = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let title = (jsonObject["title"] as? String)?.nonEmpty ?? "Webhook 通知"
            let subtitle = (jsonObject["subtitle"] as? String)?.nonEmpty
            let message =
                (jsonObject["message"] as? String)?.nonEmpty
                ?? (jsonObject["body"] as? String)?.nonEmpty
                ?? (jsonObject["text"] as? String)?.nonEmpty
                ?? "收到一条通知"
            let sound = jsonObject["sound"] as? Bool
            let url = (jsonObject["url"] as? String)?.nonEmpty
            return WebhookNotificationPayload(title: title, subtitle: subtitle, message: message, sound: sound, url: url)
        }

        if let plainText = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return WebhookNotificationPayload(title: "Webhook 通知", subtitle: nil, message: plainText, sound: true, url: nil)
        }

        throw WebhookError.invalidPayload
    }
}

private enum WebhookError: LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Request body must be JSON or plain text"
        }
    }
}

private enum HTTPRequestParser {
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data.subdata(in: 0..<separatorRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }

        let method = parts[0]
        let target = parts[1]
        let url = URLComponents(string: target)
        let path = url?.path.nilIfEmpty ?? target

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = separatorRange.upperBound
        let bodyLength = data.count - bodyStart
        let isComplete = bodyLength >= contentLength
        let bodyEnd = min(bodyStart + contentLength, data.count)
        let body = bodyStart <= bodyEnd ? data.subdata(in: bodyStart..<bodyEnd) : Data()

        let queryItems = Dictionary(uniqueKeysWithValues: (url?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        return HTTPRequest(
            method: method,
            path: path,
            headers: headers,
            body: body,
            queryItems: queryItems,
            isComplete: isComplete
        )
    }
}

private enum HTTPResponse {
    static func statusText(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Internal Server Error"
        }
    }
}

private extension String {
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
