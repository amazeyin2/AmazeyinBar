import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var usageStore: UsageStore
    @EnvironmentObject private var webhookStore: WebhookStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                header

                if usageStore.accountStates.isEmpty {
                    Text("还没有启用账号，请先编辑配置文件。")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.gray, lineWidth: 1)
            )
            .compositingGroup()

            actionButtons
        }
        .padding(12)
        .frame(width: 308)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Amazeyin Bar")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.black)
                if usageStore.isRefreshing || usageStore.isImporting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            StatusRow(
                title: "Webhook",
                value: webhookStore.endpointSummary,
                tint: webhookStore.statusColor
            )

            if let lastError = usageStore.lastError {
                StatusRow(
                    title: "错误",
                    value: lastError,
                    tint: .red
                )
            }

            if let lastImportMessage = usageStore.lastImportMessage {
                StatusRow(
                    title: "导入",
                    value: lastImportMessage,
                    tint: .blue
                )
            }

            if let lastNotification = webhookStore.lastNotificationSummary {
                StatusRow(
                    title: "最近通知",
                    value: lastNotification,
                    tint: .orange
                )
            }
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HoverActionButton("立即刷新") {
                Task { await usageStore.refresh(forceReloadConfig: true) }
            }

            HoverActionButton("重新加载配置") {
                Task { await usageStore.reloadConfiguration() }
            }

            HoverActionButton("从当前 Chrome 导入账号") {
                Task { await usageStore.importFromChrome() }
            }
            .disabled(usageStore.isImporting)

            HoverActionButton("打开配置文件") {
                configStore.openConfigInEditor()
            }

            HoverActionButton("在 Finder 中显示配置") {
                configStore.revealSupportFolder()
            }

            HoverActionButton("复制 webhook curl 示例") {
                webhookStore.copySampleCurl()
            }

            HoverActionButton("发送本机测试通知") {
                Task { await webhookStore.sendTestNotification() }
            }

            Divider()

            HoverActionButton("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

private struct HoverActionButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
                .padding(.vertical, 0)
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
        (isHovered || isPressed) ? .white : .black
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
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(tint, in: Capsule())

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
            Text(state.account.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .lineLimit(1)

            HStack(spacing: 10) {
                metricCard(title: "5H", window: payload.fiveHour, accent: Color.blue)
                metricCard(title: "7D", window: payload.sevenDay, accent: Color.green)
            }
        }
    }

    private func metricCard(title: String, window: UsageWindow, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.white, in: Capsule())

                Text("\(window.utilization)%")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.black)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("重置 \(AppFormatters.dateTime.string(from: window.resetsAt))")
                Text(AppFormatters.countdownString(seconds: window.remainingSeconds))
                    .foregroundStyle(Color(red: 0.35, green: 0.35, blue: 0.38))
            }
            .font(.caption2)
            .foregroundStyle(.black)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent, lineWidth: 1)
        )
    }
}
