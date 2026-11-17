import AppKit
import SwiftUI

@main
struct GPTUsageBarApp: App {
    @StateObject private var configStore = ConfigStore()
    @StateObject private var usageStore: UsageStore
    @StateObject private var webhookStore: WebhookStore
    @StateObject private var audioReceiver: LANAudioReceiver
    @StateObject private var calendarStore: CalendarStore

    init() {
        let configStore = ConfigStore()
        _configStore = StateObject(wrappedValue: configStore)
        _usageStore = StateObject(wrappedValue: UsageStore(configStore: configStore))
        _webhookStore = StateObject(wrappedValue: WebhookStore(configStore: configStore))
        _audioReceiver = StateObject(wrappedValue: LANAudioReceiver(configStore: configStore))
        _calendarStore = StateObject(wrappedValue: CalendarStore(appSupportDirectory: configStore.appSupportDirectory))
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(configStore)
                .environmentObject(usageStore)
                .environmentObject(webhookStore)
                .environmentObject(audioReceiver)
                .environmentObject(calendarStore)
        } label: {
            StatusBarLabelView()
                .environmentObject(configStore)
                .environmentObject(usageStore)
                .environmentObject(calendarStore)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(configStore)
                .environmentObject(usageStore)
                .environmentObject(webhookStore)
        }
    }
}

private struct StatusBarLabelView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var usageStore: UsageStore
    @EnvironmentObject private var calendarStore: CalendarStore

    var body: some View {
        let limit = configStore.config.effectiveStatusBarAccountLimit
        let items = usageStore.statusUsageItems(limit: limit)
        let hiddenCount = usageStore.hiddenStatusRingCount(limit: limit)
        let dateSpacing = items.isEmpty ? "" : String(repeating: "\u{00A0}", count: 4)

        HStack(spacing: 6) {
            if !items.isEmpty {
                Image(nsImage: StatusBarRenderer.render(items: items))
                    .interpolation(.high)
                    .antialiased(true)

                if hiddenCount > 0 {
                    Text("+\(hiddenCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("GPT")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(verbatim: dateSpacing + CalendarDateInfo.statusDate(calendarStore.today))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize()
    }
}

private enum StatusBarRenderer {
    static func render(items: [StatusUsageItem]) -> NSImage {
        let ringSize: CGFloat = 18
        let spacing: CGFloat = 4
        let width = (ringSize * CGFloat(items.count)) + (spacing * CGFloat(max(items.count - 1, 0)))
        let size = NSSize(width: width, height: ringSize)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        for (index, item) in items.enumerated() {
            let originX = CGFloat(index) * (ringSize + spacing)
            drawRing(item: item, in: NSRect(x: originX, y: 0, width: ringSize, height: ringSize))
        }

        image.isTemplate = false
        return image
    }

    private static func drawRing(item: StatusUsageItem, in rect: NSRect) {
        let progress = min(max(CGFloat(item.utilization ?? 0) / 100.0, 0), 1)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2 - 1.8
        let lineWidth: CGFloat = 3.2
        let startAngle: CGFloat = 90
        let progressEndAngle = startAngle - (360 * progress)

        let trackPath = NSBezierPath()
        trackPath.lineWidth = lineWidth
        trackPath.lineCapStyle = .round
        trackPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        NSColor.white.withAlphaComponent(0.22).setStroke()
        trackPath.stroke()

        let progressPath = NSBezierPath()
        progressPath.lineWidth = lineWidth
        progressPath.lineCapStyle = .round
        progressPath.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: progressEndAngle, clockwise: true)
        ringColor(for: item).setStroke()
        progressPath.stroke()

        let text = item.utilization.map(String.init) ?? "--"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let textRect = NSRect(x: rect.minX, y: rect.midY - 4.8, width: rect.width, height: 10)
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private static func ringColor(for item: StatusUsageItem) -> NSColor {
        if item.hasError {
            return NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.30, alpha: 1)
        }
        if (item.utilization ?? 0) >= 90 {
            return NSColor(calibratedRed: 0.96, green: 0.70, blue: 0.12, alpha: 1)
        }
        switch item.window {
        case .fiveHour:
            return NSColor(calibratedRed: 0.15, green: 0.53, blue: 0.95, alpha: 1)
        case .sevenDay:
            return NSColor(calibratedRed: 0.18, green: 0.84, blue: 0.33, alpha: 1)
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @EnvironmentObject private var usageStore: UsageStore
    @EnvironmentObject private var webhookStore: WebhookStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("GPT Usage Bar")
                .font(.title2)
            Text("账号配置保存在：\(configStore.configFileURL.path)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("Webhook：\(webhookStore.endpointSummary)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Button("打开配置文件") {
                    configStore.openConfigInEditor()
                }
                Button("重新加载并刷新") {
                    Task { await usageStore.reloadConfiguration() }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 560, height: 220)
    }
}
