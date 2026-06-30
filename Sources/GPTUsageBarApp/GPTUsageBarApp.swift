import AppKit
import SwiftUI

@main
struct GPTUsageBarApp: App {
    @StateObject private var configStore = ConfigStore()
    @StateObject private var usageStore: UsageStore
    @StateObject private var webhookStore: WebhookStore

    init() {
        let configStore = ConfigStore()
        _configStore = StateObject(wrappedValue: configStore)
        _usageStore = StateObject(wrappedValue: UsageStore(configStore: configStore))
        _webhookStore = StateObject(wrappedValue: WebhookStore(configStore: configStore))
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(configStore)
                .environmentObject(usageStore)
                .environmentObject(webhookStore)
        } label: {
            StatusBarLabelView()
                .environmentObject(usageStore)
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
    @EnvironmentObject private var usageStore: UsageStore

    var body: some View {
        let items = usageStore.statusRingItems(limit: 2)
        let hiddenCount = usageStore.hiddenStatusRingCount(limit: 2)

        if items.isEmpty {
            Text("GPT")
                .font(.system(size: 12, weight: .semibold))
        } else {
            HStack(spacing: 4) {
                Image(nsImage: StatusBarRenderer.render(items: items))
                    .interpolation(.high)
                    .antialiased(true)

                if hiddenCount > 0 {
                    Text("+\(hiddenCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
        }
    }
}

private enum StatusBarRenderer {
    static func render(items: [StatusRingItem]) -> NSImage {
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

    private static func drawRing(item: StatusRingItem, in rect: NSRect) {
        let progress = min(max(CGFloat(item.utilization) / 100.0, 0), 1)
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

        let text = "\(item.utilization)" as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let textRect = NSRect(x: rect.minX, y: rect.midY - 4.8, width: rect.width, height: 10)
        text.draw(in: textRect, withAttributes: attributes)
    }

    private static func ringColor(for item: StatusRingItem) -> NSColor {
        if item.hasError {
            return NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.30, alpha: 1)
        }
        return NSColor(calibratedRed: 0.18, green: 0.84, blue: 0.33, alpha: 1)
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
