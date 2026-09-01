import AppKit
import SwiftUI

private let menuBackgroundColor = Color(red: 0.93, green: 0.925, blue: 0.90)

struct MenuBarView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var usageStore: UsageStore
    @EnvironmentObject private var webhookStore: WebhookStore
    @State private var configurationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                if usageStore.accountStates.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("还没有启用账号，请先编辑配置文件。")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(menuBackgroundColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(usageStore.accountStates.enumerated()), id: \.element.id) { index, state in
                            AccountSection(state: state)
                            if index < usageStore.accountStates.count - 1 {
                                Divider()
                                    .overlay(Color.gray)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(menuBackgroundColor)
            )
            .compositingGroup()

            Divider()

            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(width: 320)
        .background(menuBackgroundColor)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if usageStore.isRefreshing || usageStore.isImporting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("同步数据中...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            StatusRow(
                icon: "network",
                title: "Webhook",
                value: webhookStore.endpointSummary,
                statusColor: webhookStore.statusColor
            )

            if let lastError = usageStore.lastError {
                StatusRow(
                    icon: "exclamationmark.octagon.fill",
                    title: "错误",
                    value: lastError,
                    statusColor: .red
                )
            }

            if let lastImportMessage = usageStore.lastImportMessage {
                StatusRow(
                    icon: "arrow.down.doc.fill",
                    title: "导入",
                    value: lastImportMessage,
                    statusColor: .blue
                )
            }

            if let lastNotification = webhookStore.lastNotificationSummary {
                StatusRow(
                    icon: "bell.fill",
                    title: "最近通知",
                    value: lastNotification,
                    statusColor: .orange,
                    maxContentHeight: 120
                )
            }

            if let configurationError {
                StatusRow(
                    icon: "exclamationmark.triangle.fill",
                    title: "配置",
                    value: configurationError,
                    statusColor: .red
                )
            }
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 2) {
            statusBarModePicker

            HoverActionButton("立即刷新", icon: "arrow.clockwise") {
                Task { await usageStore.refresh(forceReloadConfig: true) }
            }

            HoverActionButton("重新加载配置", icon: "gearshape") {
                Task { await usageStore.reloadConfiguration() }
            }

            HoverActionButton("从剪贴板 cURL 导入 ChatGPT 账号", icon: "doc.on.clipboard") {
                Task { await usageStore.importFromClipboardCurl() }
            }
            .disabled(usageStore.isImporting)

            HoverActionButton("从当前 Chrome 页面导入账号", icon: "globe") {
                Task { await usageStore.importFromChrome() }
            }
            .disabled(usageStore.isImporting)

            HoverActionButton("通过 Sub2API API Key 导入账号", icon: "key.fill") {
                Sub2APIImportWindowController.shared.show { baseURL, apiKey in
                    Task { await usageStore.importFromSub2API(baseURL: baseURL, apiKey: apiKey) }
                }
            }
            .disabled(usageStore.isImporting)

            HoverActionButton("打开配置文件", icon: "doc.text") {
                configStore.openConfigInEditor()
            }

            HoverActionButton("在 Finder 中显示配置", icon: "folder") {
                configStore.revealSupportFolder()
            }

            HoverActionButton("复制 webhook curl 示例", icon: "terminal") {
                webhookStore.copySampleCurl()
            }

            HoverActionButton("发送本机测试通知", icon: "paperplane") {
                Task { await webhookStore.sendTestNotification() }
            }

            lockRequestsToggle

            Divider()

            header

            Divider()

            HoverActionButton("退出", icon: "power", isDestructive: true) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var statusBarModePicker: some View {
        HStack(spacing: 8) {
            Label("状态栏显示模式", systemImage: "menubar.rectangle")
                .font(.body.weight(.medium))
                .foregroundStyle(.black)
                .lineLimit(1)

            Spacer(minLength: 0)

            Picker("状态栏显示模式", selection: Binding(
                get: { configStore.config.titleMode },
                set: { updateTitleMode($0) }
            )) {
                Text("5H").tag(TitleMode.fiveHour)
                Text("7D").tag(TitleMode.sevenDay)
                Text("ALL").tag(TitleMode.compact)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 120)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private var lockRequestsToggle: some View {
        Toggle(isOn: Binding(
            get: { configStore.config.webhook?.allowsLockRequests ?? false },
            set: { updateLockRequests(allowed: $0) }
        )) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(Color(red: 0.32, green: 0.33, blue: 0.30))
                Text("允许远程锁屏请求")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.black)
                Spacer(minLength: 0)
                Text(configStore.config.webhook?.allowsLockRequests == true ? "已启用" : "已关闭")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .toggleStyle(.switch)
        .disabled(configStore.config.webhook == nil)
    }

    private func updateLockRequests(allowed: Bool) {
        do {
            try configStore.setLockRequestsAllowed(allowed)
            configurationError = nil
        } catch {
            configurationError = "保存锁屏开关失败：\(error.localizedDescription)"
        }
    }

    private func updateTitleMode(_ titleMode: TitleMode) {
        do {
            try configStore.setTitleMode(titleMode)
            configurationError = nil
            Task { await usageStore.reloadConfiguration() }
        } catch {
            configurationError = "保存状态栏显示模式失败：\(error.localizedDescription)"
        }
    }
}

private struct Sub2APIImportView: View {
    @State private var baseURL = "https://sub.amazeyin.com"
    @State private var apiKey = ""

    let onImport: (String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入 Sub2API 账号")
                .font(.title3.weight(.semibold))

            Text("粘贴后台生成的 Admin API Key。密钥仅保存到 macOS 钥匙串，不会写入配置文件。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("后台地址")
                    .font(.caption.weight(.medium))
                TextField("https://your-sub2api.example", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Admin API Key")
                    .font(.caption.weight(.medium))
                SecureField("admin-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("导入账号") {
                    onImport(baseURL, apiKey)
                    onCancel()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

@MainActor
private final class Sub2APIImportWindowController {
    static let shared = Sub2APIImportWindowController()

    private var window: NSPanel?

    func show(onImport: @escaping (String, String) -> Void) {
        close()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "导入 Sub2API 账号"
        panel.isReleasedWhenClosed = false
        panel.center()

        let importView = Sub2APIImportView(
            onImport: onImport,
            onCancel: { [weak self] in self?.close() }
        )
        panel.contentViewController = NSHostingController(rootView: importView)
        window = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
        window = nil
    }
}

private struct HoverActionButton: View {
    let title: String
    let icon: String
    let isDestructive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    init(_ title: String, icon: String, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isDestructive = isDestructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(foregroundColor)
                Spacer(minLength: 0)
            }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var backgroundColor: Color {
        if isPressed {
            return Color(red: 0.27, green: 0.56, blue: 0.93)
        }
        if isHovered {
            return Color(red: 0.34, green: 0.61, blue: 0.95)
        }
        return .clear
    }

    private var foregroundColor: Color {
        if isDestructive {
            return isHovered || isPressed ? .white : .red
        }
        return (isHovered || isPressed) ? .white : .black
    }

    private var iconColor: Color {
        if isHovered || isPressed {
            return .white
        }
        return isDestructive ? .red : Color(red: 0.32, green: 0.33, blue: 0.30)
    }
}

private struct StatusBadge: View {
    let title: String
    let value: String
    let background: Color
    let foreground: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
            Text(value)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(background, in: Capsule())
        .foregroundStyle(foreground)
    }
}

private struct StatusRow: View {
    let icon: String
    let title: String
    let value: String
    let statusColor: Color
    var maxContentHeight: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 14)
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            content
                .padding(.leading, 20)
        }
    }

    @ViewBuilder
    private var content: some View {
        if maxContentHeight != nil {
            let summary = value.trimmingCharacters(in: .whitespacesAndNewlines)
            Text(summary.isEmpty ? "收到一条通知" : summary)
                .font(.caption.weight(.medium))
                .foregroundStyle(.black)
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(6)
                .background(Color(red: 0.88, green: 0.875, blue: 0.84), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.black)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AccountSection: View {
    let state: AccountUsageState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let payload = state.payload {
                compactAccount(payload: payload)
            } else if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("等待首次刷新…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.black)
            }
        }
    }

    private func compactAccount(payload: UsagePayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.32, green: 0.33, blue: 0.30))
                Text(state.account.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                metricCard(title: "5H", window: payload.fiveHour, palette: .fiveHour)
                metricCard(title: "7D", window: payload.sevenDay, palette: .sevenDay)
            }
        }
    }

    private func metricCard(title: String, window: UsageWindow, palette: MetricPalette) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: title == "5H" ? "clock" : "calendar")
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text("\(window.utilization)%")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 1) {
                Text("重置 \(AppFormatters.dateTime.string(from: window.resetsAt))")
                Text(AppFormatters.countdownString(seconds: window.remainingSeconds))
            }
            .font(.caption2)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(palette.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: palette.shadowColor, radius: 4, x: 0, y: 2)
    }
}

private enum MetricPalette {
    case fiveHour
    case sevenDay

    var gradient: LinearGradient {
        switch self {
        case .fiveHour:
            return LinearGradient(
                colors: [Color(red: 0.14, green: 0.29, blue: 0.55), Color(red: 0.25, green: 0.43, blue: 0.70)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .sevenDay:
            return LinearGradient(
                colors: [Color(red: 0.12, green: 0.67, blue: 0.53), Color(red: 0.18, green: 0.80, blue: 0.62)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    var shadowColor: Color {
        switch self {
        case .fiveHour:
            return Color(red: 0.34, green: 0.42, blue: 0.56)
        case .sevenDay:
            return Color(red: 0.35, green: 0.58, blue: 0.49)
        }
    }
}
